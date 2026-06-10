# Tasks: Function Calling — Local Device Tools

**Input**: Design documents from `/specs/004-function-calling/` — [plan.md](plan.md),
[spec.md](spec.md) (clarified), [research.md](research.md) R1–R8, [data-model.md](data-model.md),
[contracts/](contracts/), [quickstart.md](quickstart.md), [spike-findings.md](spike-findings.md)
(GATE PASSED).

**Tests**: REQUESTED by the feature brief — dispatcher unit tests (valid/malformed/unknown),
capability-gating tests, migration test, manual device script (all four tools + hallucinated
tool). House rule: tests ride WITH their implementation tasks (contract-first where the contract
is load-bearing).

## Format: `[ID] [P?] [Story] Description`

- **[P]**: parallelizable (different files, no dependency on an incomplete task)
- **[USn]**: user story label (story phases only)
- Device tasks are sequential `flutter run`/`flutter drive` sessions — **NEVER
  `flutter test integration_test/...`** (wipes model + DB); raise screen timeout for long drives.

## Path Conventions

Single Flutter app at repo root: `lib/` (core/domain/data/infrastructure/features),
`test/` (unit/widget/data), `android/`, `tool/` — exactly the tree pinned in plan.md
§Project Structure.

---

## Phase 1: Setup (Shared Infrastructure)

- [ ] T001 Add `battery_plus: ^7.0.0` and `android_intent_plus: ^6.0.0` to `pubspec.yaml`
      (research R4 pins, comment each with its seam + confinement note, house style);
      `flutter pub get` resolves clean.
- [ ] T002 [P] Android manifest prep in `android/app/src/main/AndroidManifest.xml`: add
      `com.android.alarm.permission.SET_ALARM` and the `<queries>` entry for
      `android.intent.action.SET_TIMER` (Android 11+ package visibility — R4).
- [ ] T003 [P] Extend `tool/check_plugin_seam.sh`: `battery_plus` and `android_intent_plus`
      imports allowed ONLY under `lib/infrastructure/`; script passes now (nothing imports them
      yet) and would fail on a violation (verify with a scratch negative test).

**Checkpoint**: `flutter pub get` resolves; seam guard green; no behavior change anywhere.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Domain types & pure logic (all [P] — new files):**

- [ ] T004 [P] `lib/domain/entities/generation_event.dart`: sealed `GenerationEvent` —
      `TextDelta(String token)` | `ToolCallRequested(String name, Map<String, Object?> args,
      {int extraCallCount})` per contracts/gemma_service.md.
- [ ] T005 [P] `lib/domain/entities/tool_spec.dart`: `ToolSpec` (name/description/parameters/
      `ToolKind` readOnly|stateChanging) + `lib/domain/entities/tool_outcome.dart`: sealed
      `ToolOutcome` (Success{result, truncated} | Unknown | InvalidArgs | Failure) +
      `ToolCallStatus` enum (running|success|error|skipped) per data-model §1.
- [ ] T006 [P] `lib/core/tools/schema_validator.dart`: the R3 subset validator (object root,
      properties, required, enum, string/integer/number/boolean, integer min/max, STRICT
      unknown-key rejection) returning `valid | invalid(reason)`.
- [ ] T007 Unit tests `test/unit/core/schema_validator_test.dart` (after T006): valid args (empty,
      optional present, enum value), wrong type, unknown key rejected, enum violation, missing
      required, integer bounds — one failure reason asserted per case.
- [ ] T008 [P] `lib/core/tools/tool_registry.dart`: const four-`ToolSpec` registry with the
      exact v1 schemas (contracts/tool_registry_dispatcher.md table: get_device_info `section?`
      enum; summarize_clipboard `{}`; set_theme `theme` required enum; set_timer `seconds`
      1..86400 + `label?`) + `byName`. Descriptions carry the model-facing constraints
      (clipboard foregrounding, timer bounds).
- [ ] T009 Registry sanity tests `test/unit/core/tool_registry_test.dart` (after T006+T008): unique
      snake_case names, every schema self-validates against T006's subset, descriptions
      non-empty, kind set on all four (contract invariants 1–4).

**Dispatcher (the feature brief's named unit tests):**

- [ ] T010 `lib/domain/services/tool_dispatcher.dart`: `dispatch(name, args) → ToolOutcome` —
      registry lookup → schema validation → injected handler → outcome mapping; NEVER throws;
      per-tool `resultCharBound` truncation with `truncated: true` (default 2,000, clipboard
      4,400 — contract guarantees 1–4).
- [ ] T011 Dispatcher unit tests `test/unit/domain/tool_dispatcher_test.dart` with
      `FakeToolHandlers`: valid call → Success; malformed args → InvalidArgs (handler NOT
      invoked — assert via fake); unknown tool → Unknown (handler map untouched); handler throw
      → Failure; oversized result → truncated; handler-map/registry congruence sanity.

**Persistence (drift v3 → v4):**

- [ ] T012 `lib/data/db/tables.dart` + `lib/data/db/app_database.dart`: add nullable
      `toolName`/`toolArgs`/`toolStatus`/`toolResult` columns, `schemaVersion => 4`, additive
      `m.addColumn` v3→v4 block (data-model §2); regenerate drift code
      (`dart run build_runner build`).
- [ ] T013 Migration test `test/data/migration_v3_to_v4_test.dart` (house pattern): seed a real
      v3 file DB **with `idx_messages_conversation`**, open at v4 → old rows intact with NULL
      tool columns, index present, tool-row insert/readback round-trips.
- [ ] T014 `lib/domain/entities/message.dart`: `MessageRole.tool`, tool fields, the all-null /
      non-null invariant helpers (data-model §1).
- [ ] T015 Repository: `appendToolInvocation` / `finalizeToolInvocation` (terminal-states-only,
      `ArgumentError` invariants: tool fields XOR role, no attachments on tool rows, 4,400-char
      result ceiling) in `lib/data/repositories/drift_conversation_repository.dart` +
      `lib/domain/repositories/conversation_repository.dart`, per
      contracts/conversation_repository.md.
- [ ] T016 Repository tests `test/data/repository_tool_rows_test.dart` (in-memory drift):
      append→finalize round-trip, `running` rejected by finalize, invariant violations throw,
      sequence ordering preserved, conversation-delete cascade removes tool rows, stale
      `running` sweep finalizes to `error('interrupted')` (sweep implemented here too —
      data-model §4 terminal-state guarantee).

**Seam (contract guarantees 18–25):**

- [ ] T017 `lib/domain/services/gemma_service.dart`: `generate` returns
      `Stream<GenerationEvent>`; add `resumeWithToolResult`; `loadModel` gains
      `List<ToolSpec> tools`; document guarantees 18–25 in the interface doc comments.
- [ ] T018 [P] `lib/infrastructure/gemma/leak_filter.dart`: pure `LeakFilter` — withhold
      `{`-prefixed accumulating text while tools active; discard on call-terminated turn; flush
      verbatim on text-terminated turn (guarantee 20).
- [ ] T019 LeakFilter unit tests `test/unit/infrastructure/leak_filter_test.dart` (after T018)
      against the spike's captured shapes (chunk-granularity contract, guarantee 20): pure-JSON
      call turn (all withheld+discarded), prose-only turn (all flushed),
      **prose-then-leak-then-call** (prose emitted, trailing JSON chunk discarded), `{`-prefix
      false-positive prose (flushed at stream end), chunk-split JSON.
- [ ] T020 `lib/infrastructure/gemma/flutter_gemma_service.dart`: thread the structural coupling
      — `tools`/`supportsFunctionCalls`/`systemInstruction` derived from ONE source
      (`capabilities.functionCalling` + loadModel's tools, guarantee 18 StateError, R5);
      `ToolSpec`→`Tool` mapping; event mapping (`TextResponse`→LeakFilter→`TextDelta`,
      `FunctionCallResponse`→`ToolCallRequested`, parallel→first+extraCallCount);
      `resumeWithToolResult` via `Message.toolResponse` + fresh generate (guarantee 22 gate);
      StateError rethrow rule preserved (guarantee 24); flag-off parity (guarantee 19).
- [ ] T021 Extend `FakeGemmaService` in `test/helpers/fake_gemma_service.dart`: scriptable
      `GenerationEvent` sequences,
      post-resume sequences (incl. a second `ToolCallRequested`), guarantee-18/22 StateErrors,
      resume-payload recording, parity mode — per contracts/gemma_service.md §Fake.
- [ ] T022 Mechanical migration of existing tests/fakes broken by `Stream<String>` →
      `Stream<GenerationEvent>` (chat controller, composer, history, audio/image suites):
      adapt to `TextDelta` with ZERO behavioral assertion changes — this is the parity proof at
      the test layer.
- [ ] T023 `lib/features/chat/chat_controller.dart`: consume `GenerationEvent`s for the
      text-only path (TextDelta → existing buffer/flush/stop machinery) — behavior parity,
      no tool branch yet; full 001/002/003 suite green.
- [ ] T024 `lib/features/chat/context_assembler.dart` (after T014): tool turns in `ChatTurn` replay
      with token accounting (name+args+result at 4 chars/token) + reserve ~40 tokens for the
      tool system instruction when capability on (R6); unit tests
      `test/unit/features/context_assembler_tool_test.dart` (inclusion, accounting,
      oldest-drop with tool turns).

**Checkpoint**: `flutter analyze` clean; FULL existing suite + new foundational tests green;
flag still off everywhere — app behavior unchanged. Foundation ready for all stories.

---

## Phase 3: User Story 1 — Ask a device question, watch the assistant use a tool (US1, P1) 🎯 MVP

- [ ] T025 [P] [US1] `lib/infrastructure/tools/device_info_tool_service.dart`:
      `device_info_plus` (model/OS/RAM) + `battery_plus` (level) + StatFs channel client for
      free storage; superset result map (R4); per-field `unknown` degradation, never throws;
      fake included.
- [ ] T026 [P] [US1] StatFs `MethodChannel` (~10 lines Kotlin) in
      `android/app/src/main/kotlin/.../MainActivity.kt` returning free/total storage bytes
      (R4 — rejected disk_space_plus).
- [ ] T027 [P] [US1] `lib/core/model_catalog.dart`: `supportsFunctionCalling = true` composed
      into `capabilities` (R5, spike-verified); thread `ToolRegistry.specs` through
      `modelSessionProvider`'s `loadModel` call (`lib/features/chat/chat_providers.dart`) gated
      on the flag.
- [ ] T028 [P] [US1] `lib/features/chat/tool_handler_providers.dart`: registry + handler map +
      dispatcher Riverpod wiring. get_device_info handler bound; the three not-yet-landed tools
      stub to `ToolFailure('not available yet')` — NEVER `ToolUnknown` (the registry declares
      them to the model, so "unknown" would be semantically false; preserves dispatcher
      guarantees 1 and 5 — the congruence test holds at every checkpoint).
- [ ] T029 [US1] The R6 tool-use system instruction (lowercase, ~40 tokens) as a const in
      `lib/core/tools/tool_registry.dart`, threaded by the seam when `functionCalling` on
      (exact wording tuned in T049's device pass).
- [ ] T030 [US1] Controller tool branch in `lib/features/chat/chat_controller.dart` — the
      data-model §4 state machine: on `ToolCallRequested` apply the ordering rule (empty
      assistant row deleted / text row finalized), persist tool row (running), dispatch,
      finalize (success/error/skipped + lowercase summary line), `resumeWithToolResult`, stream
      the final reply into a NEW assistant row; stop checked before dispatch and before resume
      (FR-026); second-call-on-resume → its own `error('only one tool call per turn')` chip,
      turn ends as text (FR-006/FR-024); parallel extras noted on the executed call's chip.
- [ ] T031 [US1] Controller loop tests `test/unit/features/chat_controller_tool_test.dart`
      (scripted FakeGemmaService + fake dispatcher): happy path rows + ordering
      (user→chip→answer), resume payload correctness, stop-before-dispatch → skipped,
      stop-before-resume → no resume, second-call → error chip, empty-vs-text assistant-row
      variants, AND the attachment edge case (image/audio-bearing user message → tool turn →
      attachment renders/persists unchanged, ordering correct — spec Edge Cases).
- [ ] T032 [P] [US1] `lib/features/chat/widgets/tool_chip.dart`: design-system §8 — mono
      uppercase `TOOL · NAME` tag, args summary, quiet `content` result line
      (`surfaceContainerHigh`, hairline outline, radius 8, `textSecondary` floor); dot-pulse
      running state; error state's sanctioned red; `Semantics` label (data-model §5);
      non-interactive.
- [ ] T033 [US1] Render `role == tool` rows as `ToolChip` in the chat list (message_bubble or
      list builder switch) — chips render regardless of current capabilities (FR-010).
- [ ] T034 [US1] Widget tests `test/widget/tool_chip_test.dart` (after T032+T033): all four states render
      tokens-only (no hardcoded hex), semantics labels, no tap target; and
      `test/widget/chat_tool_flow_test.dart`: scripted tool turn renders chip between user
      message and final answer (UI+pump async pattern — never bare await over fake streams).
- [ ] T035 [US1] DEVICE (quickstart V1+V2): battery/device/storage prompts → chip → grounded
      reply < 20 s, no raw JSON visible (SC-003/005); haiku/arithmetic → zero chips (SC-002).

**Checkpoint**: US1 alone is a shippable MVP — ask a device question, see the tool run, get a
grounded answer on a real device.

---

## Phase 4: User Story 2 — Change the app theme by asking (US2, P2)

- [ ] T036 [P] [US2] set_theme handler in `lib/features/chat/tool_handler_providers.dart`
      binding the EXISTING persisted theme mechanism (settings controller); idempotent
      `alreadyActive: true` result (FR-014); handler unit test in
      `test/unit/features/set_theme_handler_test.dart` (flip, idempotent, persistence
      delegation). NOTE: `tool_handler_providers.dart` + the T011 congruence test are shared
      merge points across US2/US4/US5 — sequence those edits.
- [ ] T037 [US2] Widget test `test/widget/theme_tool_test.dart`: scripted set_theme turn flips
      the app theme live + chip records success; same-theme turn → success chip with
      already-active summary.
- [ ] T038 [US2] DEVICE (quickstart V3): switch to light → flips immediately + persists across
      relaunch (SC-009); idempotent ask; settings-screen switch stays consistent.

**Checkpoint**: first state-changing tool proves auto-execute (spec Q1) safely.

---

## Phase 5: User Story 3 — Tools appear only for capable models (US3, P2)

- [ ] T039 [P] [US3] Capability-gating tests `test/unit/features/tool_gating_test.dart`:
      flag-off → seam receives empty tools + `supportsFunctionCalls: false` + no system
      instruction (guarantee 19 parity, byte-level on plugin inputs via fake recording);
      flag-on → coupled inputs present; ungated `loadModel(tools:)` → StateError (guarantee 18).
- [ ] T040 [P] [US3] Widget regression `test/widget/tool_gating_regression_test.dart`:
      flag-off chat flow byte-parity (existing flows untouched, zero chips for new turns) +
      persisted tool chips from history still render under flag-off (FR-010, the 003
      history-outlives-capability pattern).
- [ ] T041 [US3] DEVICE (quickstart V11): scratch flag-off build — prose only, zero
      declarations, old chips render; restore flag.

**Checkpoint**: gating is provably data-driven; flag-off is regression-locked.

---

## Phase 6: User Story 4 — Set a timer by asking (US4, P2)

- [ ] T042 [P] [US4] `lib/infrastructure/tools/timer_intent_service.dart`: android_intent_plus
      ACTION_SET_TIMER + EXTRA_LENGTH/EXTRA_MESSAGE/EXTRA_SKIP_UI (R4);
      ActivityNotFoundException → `no clock app available` Failure; fake included; handler
      bound in providers (bounds 1..86400 already schema-enforced pre-handler).
- [ ] T043 [US4] Tests in `test/unit/infrastructure/timer_intent_service_test.dart`: handler
      unit (intent payload correctness via fake intent sink, missing clock app → Failure) +
      controller-level invalid-duration turn (schema rejects 0 s → InvalidArgs error chip +
      honest text, US4/AS3).
- [ ] T044 [US4] DEVICE (quickstart V4): "set a timer for 5 minutes" → no app switch, chip
      success, system clock shows the running timer; word-phrased duration "a quarter of an
      hour" → 15:00 timer (US4/AS2, the story's core claim; optionally "90 seconds" → 1:30);
      "zero seconds" → error chip, no timer.

**Checkpoint**: natural-language argument extraction works against a real system hand-off.

---

## Phase 7: User Story 5 — Summarize the clipboard (US5, P3)

- [ ] T045 [P] [US5] `lib/infrastructure/tools/clipboard_tool_service.dart`: Flutter
      `Clipboard.getData('text/plain')` at execution time; empty/non-text → Failure
      (`clipboard empty or not text`); 4,000-char bound with `truncated: true` (R3/R4); fake;
      handler bound (the summary itself happens in the resumed generation — the tool returns
      the bounded text).
- [ ] T046 [US5] Tests in `test/unit/infrastructure/clipboard_tool_service_test.dart`: handler
      unit (text, empty, non-text, truncation marker at 4,000 chars) + controller-level
      clipboard turn (result fed to resume; error path → error chip + honest reply, US5/AS2).
- [ ] T047 [US5] DEVICE (quickstart V5): copied paragraph → grounded summary (OS toast
      expected); cleared clipboard → error chip, no fabricated summary.

**Checkpoint**: the platform-constrained tool works honestly within its constraints.

---

## Phase 8: User Story 6 — Tool turns survive restarts and feed follow-ups (US6, P3)

- [ ] T048 [P] [US6] Replay mapping in the seam
      (`lib/infrastructure/gemma/flutter_gemma_service.dart`): tool `ChatTurn` →
      `Message.toolCall(<raw SDK JSON reconstruction>)` + `Message.toolResponse` inside
      `clearHistory(replayHistory:)` (data-model §3, guarantee 23); error/skipped rows replay
      `{error: …}`; kept-warm fingerprints incorporate tool turns; unit tests in
      `test/unit/infrastructure/tool_replay_mapping_test.dart` (exact JSON shape asserted
      against the spike's captured payload, spike §3).
- [ ] T049 [US6] DEVICE (quickstart V6): kill/relaunch → all chips render terminal states;
      "what was my battery level earlier?" answered FROM CONTEXT without a new chip — **replay
      fidelity is the one seam input unit tests can't verify; if the model is confused here,
      adjust the raw-JSON reconstruction and re-run** (also tune the T029 instruction wording
      in this session).

**Checkpoint**: tool turns are durable conversation history with verified model-context
fidelity.

---

## Phase 9: User Story 7 — Honest failure, never a crash (US7, P3)

- [ ] T050 [P] [US7] Forced-failure controller tests
      `test/unit/features/tool_failure_matrix_test.dart` (scripted fakes): hallucinated tool
      name → Unknown error chip + model informed + text completion; invalid args → InvalidArgs
      chip, handler untouched; handler Failure → error chip + honest resume; extraCallCount > 0
      → one chip noting skipped extras; raw-JSON leak never reaches rendered text (LeakFilter
      integration assertion at the controller level).
- [ ] T051 [P] [US7] Stale-row sweep wiring at conversation open/startup (T016's repo sweep
      invoked from `lib/features/chat/chat_providers.dart` /
      `lib/features/history/history_controller.dart`) + widget test
      `test/widget/stale_tool_row_test.dart`: reopened history never shows a `running` chip.
- [ ] T052 [US7] DEVICE (quickstart V7): "set an alarm for 7am" (no such tool) and "switch the
      backend to cpu" (excluded) → prose or unknown-tool chip, never a crash; stop mid-tool-turn
      → consistent terminal state on reopen.

**Checkpoint**: the graceful-degradation promise holds under induced failure (SC-004).

---

## Phase 10: Polish, device gates & spike cleanup

- [ ] T053 [P] Static gates: `flutter analyze` zero issues, full `flutter test` green,
      `tool/check_plugin_seam.sh` (battery_plus/android_intent_plus confinement),
      `tool/check_network_seam.sh` (tools add ZERO egress).
- [ ] T054 [P] Spike cleanup: remove `integration_test/spike_function_calling_test.dart` and
      the `integration_test` dev-dep from `pubspec.yaml` (keep `test_driver/` + its DO-NOT-
      `flutter test` comment for the reliability gate run).
- [ ] T055 DEVICE (quickstart V8+V9): airplane-mode pass over all four tools (SC-008,
      Principle II); responsiveness during tool turns (scroll/type/stop — Principle IV).
- [ ] T056 DEVICE (quickstart V10): Accessibility Scanner over all chip states — AA contrast,
      no sub-48dp targets, TalkBack semantics; visual identity check (monochrome, red only on
      error).
- [ ] T057 DEVICE (quickstart §Reliability gate): the 20-prompt suite against the SHIPPED
      pipeline — ≥80% correct-call, 0 hallucinated, 0 spurious, 0 crashes (SC-001/002);
      record results in the feature audit notes.
- [ ] T058 Moderated usability pass (SC-011): ≥8 participants on the reference device; ≥90%
      can correctly state what the assistant did after a tool turn (chip comprehension); 100%
      of device-fact askers received true values; record the protocol + results in the feature
      audit notes.

**Checkpoint**: analyze/test/seam/network gates green; spike artifacts removed; reliability
gate ≥80% correct-call with 0 hallucinated/spurious/crashes recorded; SC-011 usability pass
recorded. Feature ready for merge review.

---

## Dependencies & execution order

- **Phase 1 → 2 → 3**: strictly sequential gates (setup → foundation → MVP).
- **Phase 2 internal**: T004/T005/T006/T008 [P]; T007 after T006; T009 after T006+T008;
  T010–T011 after T005/T006/T008; T012→T013→T014→T015→T016 sequential (schema → migration test
  → entity → repo → repo tests); T017 before T018–T024; T018 [P] after T017; T019 after T018;
  T020 after T017/T018; T022/T023 after T020/T021 (the parity migration); T024 after T014.
- **Phase 3 internal**: T025/T026/T027/T028/T032 [P] after Phase 2; T029/T030 after T028;
  T031 after T030; T033 after T032; T034 after T032/T033; T035 (device) last.
- **Phases 4–7 (US2/US3/US4/US5) are mutually independent** after Phase 3 — any order; note
  two SHARED merge points across US2/US4/US5: `lib/features/chat/tool_handler_providers.dart`
  (handler bindings) and the T011 dispatcher congruence test — those specific edits are
  sequential even when the rest of each story parallelizes; each story ends in its own device
  task.
- **Phase 8 (US6)** depends on Phase 3 (needs real tool turns to replay); benefits from 4–7
  but doesn't require them.
- **Phase 9 (US7)** depends on Phase 3 (the failure matrix exercises the controller branch);
  T051 depends on T016.
- **Phase 10** last; T053/T054 [P]; T057 needs the final pipeline incl. T029 wording; T058
  independent of T053–T057.

## Parallel execution examples

- Phase 2 kickoff: T004 + T005 + T006 + T008 (four new pure files) while T012 (schema) starts.
- After Phase 3: one track takes US2 (T036–T038), another US4 (T042–T044), a third US5
  (T045–T047) — service/test files are disjoint, but `tool_handler_providers.dart` and the
  dispatcher congruence test are shared merge points (sequence those two edits across tracks);
  merge all before US6's replay device check.
- Device sessions never parallelize (one A34): order V1→V11 as the phases complete.

## Task counts

- Total: **58** | Setup: 3 | Foundational: 21 | US1: 11 | US2: 3 | US3: 3 | US4: 3 | US5: 3 |
  US6: 2 | US7: 3 | Polish: 6
- Device tasks: 10 (T035, T038, T041, T044, T047, T049, T052, T055, T056, T057 — 8 A34
  sessions if T055–T057 share one)
- **MVP scope**: Phases 1–3 (T001–T035) — the visible call→execute→answer loop with
  get_device_info on-device.
