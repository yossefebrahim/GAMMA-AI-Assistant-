# 005 Memory — Audit Fix Plan

**Input**: post-implementation audit of [tasks.md](tasks.md) (2026-06-12). The suite is green
(460/460, analyze + format clean) but two tasks are **implemented-but-not-wired**: their new code
is unit-tested in isolation yet dead in production. This plan fixes both wiring gaps plus the
lower-severity code findings. Test-blind-spot remediation beyond what proves these fixes is out of
scope (tracked separately).

Conventions follow tasks.md: `[P]` = parallelizable, each fix names its files, tests are written
with their fix. No device run is required to land this plan; T051/T052 remain the final device
gate and should be run AFTER these fixes merge.

---

## P0 — Integration gaps (new code dead in production)

### F1 — T025: memory token reserve never applied

**Problem.** `ContextAssembler.assemble` gained `reserveMemoryBlock` / `reserveMemoryCaptureInstruction`
(correct math, fully unit-tested), but the only production call site —
`ChatController._assembleHistory` (`lib/features/chat/chat_controller.dart:580–587`) — passes only
`reserveToolInstruction`. Both memory flags default to `false`, so the ~311-token reserve for the
facts block + capture instruction never happens. A long history can crowd the injected facts out of
the model's effective window — the exact failure T025 exists to prevent.

**Fix.** Thread the flags from live state in `_assembleHistory`, mirroring how the tool reserve is
already derived (`chat_controller.dart:577–579`):

```dart
final memoryEnabled = ref.read(memoryEnabledProvider);
final hasFacts =
    (await ref.read(memoryRepositoryProvider).activeCount()) > 0;
return ref.read(contextAssemblerProvider).assemble(
      priorMessages,
      images: images,
      audio: audio,
      reserveToolInstruction: reserveToolInstruction,
      reserveMemoryBlock: memoryEnabled && hasFacts,
      reserveMemoryCaptureInstruction:
          reserveToolInstruction && memoryEnabled,
    );
```

This matches the assembler's documented semantics (`context_assembler.dart:49–52`): block reserve
when memory is enabled AND ≥1 fact exists; capture reserve when function calling AND memory are
both active.

*Session-boundary approximation (document in a comment at the call site):* the reserve reflects
**current** store state, while the injected block is fixed at session start. A fact added
mid-session reserves before the block exists (conservative — harmless); facts cleared mid-session
under-reserve for an already-injected block (rare window, next `openConversation` corrects it).
The alternative — recording composed-instruction flags at each `startSession`/`loadModel` site in a
dedicated provider — was rejected: three writer sites and a new state surface for a ≤311-token
edge case.

- [x] **F1a** Wire the two flags in `_assembleHistory` with the approximation comment.
  *(lib/features/chat/chat_controller.dart)*
- [x] **F1b** **Wiring regression test** — the class of bug here was "unit-green, never called", so
  the test must capture what the CONTROLLER passes: override `contextAssemblerProvider` with a spy
  `ContextAssembler` subclass that records the named flags, drive one `send` through the existing
  FakeGemmaService controller-test scaffold (house UI+pump pattern), and assert:
  (a) memory on + ≥1 fact + functionCalling → both flags true;
  (b) memory off → both false;
  (c) memory on + 0 facts → block false, capture still true;
  (d) text-only caps → capture false even with memory on.
  *(test/unit/features/ — new context_assembler_wiring_test.dart)*

### F2 — T015: `sourceConversationId` is always null

**Problem.** The `remember_fact` handler reads `activeConversationIdProvider`
(`lib/features/chat/tool_handler_providers.dart:86`), but the provider is a plain
`Provider<int?>((ref) => null)` (line 146) that nothing ever overrides — and a plain `Provider`
**cannot** be set at runtime (overrides happen only at container creation), so the doc comment's
"chat_controller can override this at runtime" plan is structurally impossible. Every captured
fact persists with null provenance; the `ON DELETE SET NULL` behavior is untriggerable in
production.

**Fix.** Replace the `Provider` with the house manual-Notifier pattern (writable, same import
direction — controller → handlers file, no cycle):

```dart
class ActiveConversationId extends Notifier<int?> {
  @override
  int? build() => null;

  void set(int? id) => state = id;
}

final activeConversationIdProvider =
    NotifierProvider<ActiveConversationId, int?>(ActiveConversationId.new);
```

The handler's `ref.read(activeConversationIdProvider)` at line 86 stays unchanged. Two writer
sites in `ChatController`:

1. `openConversation` (`chat_controller.dart:103`) — set alongside the synchronous state write.
2. The lazy-create path in `send` (`chat_controller.dart:206–207`,
   `conversationId ??= (await repo.createConversation()).id;`) — a brand-new chat has no id until
   the first send creates the row, so the notifier must be updated here too or first-message
   captures still get null.

Rewrite the stale provider doc comment (lines 138–145) to describe the Notifier contract.

- [x] **F2a** Convert the provider to `NotifierProvider` + fix its doc comment.
  *(lib/features/chat/tool_handler_providers.dart)*
- [x] **F2b** Set it in `openConversation` and after lazy conversation creation in `send`.
  *(lib/features/chat/chat_controller.dart)*
- [x] **F2c** **Wiring regression test** — through a real `ProviderContainer` (not direct handler
  construction, which is how the existing tests missed this): open a conversation, dispatch
  `remember_fact` via `toolDispatcherProvider`, and assert the persisted fact's
  `sourceConversationId` equals the open conversation's id; cover the lazy-create path (send on a
  null-id chat → fact carries the newly created id) and the manual-add path (stays null).
  *(test/unit/features/ — extend memory dispatcher/controller tests)*

---

## P1 — Lower-severity code findings

### F3 — Deduplicate `_refreshSession` (and the third composition site)

The compose-and-startSession logic is duplicated verbatim in `ChatController._refreshSession`
(`chat_controller.dart:111–129`) and `MemoryController._refreshSession`
(`memory_controller.dart:33–53`), and the same composition (minus `startSession`) appears a third
time in the session provider (`chat_providers.dart:72–87`). If the composition flags ever change,
three sites must move in lockstep — a real drift hazard.

- [x] **F3a** Extract a shared helper, e.g. `lib/features/chat/session_instruction.dart`:
  - `String? composeSessionInstruction({required ModelCapabilities caps, required bool memoryEnabled, required List<Memory> activeFacts})` — the pure composition used by all three sites;
  - `Future<void> refreshSessionInstruction(Ref ref)` — the read-state → compose → `startSession`
    sequence (with the `isLoaded` no-op guard) used by both controllers.
- [x] **F3b** Point both `_refreshSession` methods and the `chat_providers.dart` loadModel path at
  the helper; delete the duplicates. Existing tests (`injection_controller_test.dart`,
  `memory_controller_test.dart`, `byte_parity_memory_test.dart`) must stay green unmodified —
  they pin the behavior through the public surface.

### F4 — `startSession` failure leaves the seam in limbo

`FlutterGemmaService.startSession` closes the old session, then calls `createChat` with no error
handling: if recreation throws (e.g. OOM), `_loaded` stays `true` with `_chat == null`. Safe today
(`generate` guards on null chat) but inconsistent with `loadModel`, which catches and calls
`close()`.

- [x] **F4** Wrap the recreation in try/catch; on failure call `close()` (full unload — honest
  state, matches `loadModel`'s contract) and rethrow. Add a `FakeGemmaService` knob
  (`throwOnStartSession`) + a unit test asserting `isLoaded == false` after a failed refresh, and
  a test pinning guarantee 27 (`startSession` on an unloaded service → `StateError`) which is
  currently only implicit. *(lib/infrastructure/gemma/flutter_gemma_service.dart,
  test/helpers/fake_gemma_service.dart, test/unit/)*

### F5 — [P] Deduplicate the 9-argument `createChat` call

The `_model!.createChat(...)` block is copy-pasted between `loadModel`
(`flutter_gemma_service.dart:174–183`) and `startSession` (lines 226–235). A future plugin-arg
change must currently be made twice.

- [x] **F5** Extract a private `Future<void> _createChat(ModelCapabilities caps, List<ToolSpec> tools, String? systemInstruction)`
  helper; both call sites use it. Pure refactor — no test changes expected (covered by existing
  seam tests). *(lib/infrastructure/gemma/flutter_gemma_service.dart)*

### F6 — [P] `memory_screen.dart` 48dp row: no-op `SizedBox` + false comment

`_FactRow` (`memory_screen.dart:222–225`) wraps its `ListTile` in `SizedBox(child: ...)` with **no
`height:`** — the "48dp minimum touch target" comment is false — while `minVerticalPadding: 0`
removes `ListTile`'s own height floor. The edit/delete icon buttons are correctly 48dp; the row
itself has no guarantee.

- [x] **F6** Either set `ConstrainedBox(constraints: BoxConstraints(minHeight: AppSpacing.minTouchTarget))`
  (min-height, not fixed height — facts wrap to two lines) or delete the dead `SizedBox` and the
  false comment, relying on the icon-button targets. Recommended: the `ConstrainedBox`, plus a
  widget-test assertion that a one-line fact row is ≥ 48dp tall. Fix the stale `FR-031` reference
  on line 223 → `FR-024`. *(lib/features/settings/memory_screen.dart, test/widget/memory_screen_test.dart)*

### F7 — [P] Documentation drift

- [x] **F7a** `data-model.md` §5 chip table: add the implemented `noted:` row (`UpsertUnchanged` —
  exact restatement, no new row, `updatedAt` refreshed). The code is correct; the table is
  incomplete. *(specs/005-memory/data-model.md)*
- [x] **F7b** `integration_test/memory_reliability_test.dart` header claims "drives the FULLY WIRED
  app (no direct plugin import — Principle VII holds)" but line 86 imports
  `package:flutter_gemma` directly. Fix the comment to state honestly that the harness drives the
  plugin directly (spike-style) and why that's acceptable for a device-reliability gate — or, if
  Principle VII must hold in `integration_test/` too, rewrite the harness against the seam
  (bigger task; decide before T051/T052). *(integration_test/memory_reliability_test.dart)*

### F8 — [P] Token nits (optional, batch with F6)

- [x] **F8** `memory_screen.dart:253,267` icon `size: 20` literal → name it (local
  `const _kRowIconSize = 20.0` or an `AppSpacing` token if one is added);
  `settings_screen.dart:70,86` `Divider(height: 1)` → `AppSpacing.hairline`.
  *(lib/features/settings/)*

---

## Dependencies & execution order

1. **F1 + F2 first** (independent of each other, `[P]`) — they are the audit's blocking findings.
2. **F3** next — touches the same `_refreshSession` code F1's test scaffold exercises; landing it
   after F1/F2 keeps the P0 diffs minimal and reviewable.
3. **F4 + F5** together (same file); **F6/F7/F8** are `[P]` any time.
4. Final gate: `flutter analyze` + `dart format` + full `flutter test` (expect 460 + new tests
   green), then re-run `tool/check_plugin_seam.sh` + `tool/check_network_seam.sh`.
5. After merge: run the still-pending **T051/T052** device walkthrough + gates on the A34
   (`flutter run` / `flutter drive` only — NEVER `flutter test integration_test/...`).

**Definition of done**: every box above checked, suite green, and — the audit's core lesson — each
P0 fix proven by a test that exercises the **production wiring path** (controller/container level),
not just the unit in isolation.
