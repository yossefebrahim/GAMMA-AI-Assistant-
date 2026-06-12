# Tasks — 005 Memory

**Input**: [plan.md](plan.md), [spec.md](spec.md), [research.md](research.md),
[data-model.md](data-model.md), [contracts/](contracts/), [quickstart.md](quickstart.md),
[spike-findings.md](spike-findings.md).

Conventions: `[P]` = parallelizable (different files, no dependency on an unfinished task in the same
phase). Each task names its file(s). Device tasks use `flutter run`/`flutter drive` ONLY — NEVER
`flutter test integration_test/...` (wipes the model + DB). Tests are written before/with their
implementation (house TDD pattern). Story phases (US1–US7) are independently testable slices; the
Foundational phase blocks all of them.

---

## Phase 1 — Setup

- [X] **T001** Confirm no new dependency is needed (research R1/R9) and that `flutter_gemma` stays
  `^0.15.0` (0.15.3). Sanity-run `flutter pub get` + `tool/check_network_seam.sh` (must stay green) —
  baseline before changes. *(pubspec.yaml — expected: no edit)*
- [X] **T002** [P] Remove the Phase 0 throwaway harness `integration_test/spike_memory_test.dart` (DO NOT
  SHIP; spike findings captured). The shipped reliability harness is created later (T050).

## Phase 2 — Foundational (BLOCKS every user story)

- [X] **T003** Add the `Memories` drift table + `memoryEnabled` column to `AppSettingsTable`
  (data-model §2). *(lib/data/db/tables.dart)*
- [X] **T004** Bump `schemaVersion` 4 → 5 and add the additive `from < 5` migration:
  `m.createTable(memories)` + `m.addColumn(appSettings.memoryEnabled)`; keep `PRAGMA foreign_keys=ON`.
  Run `dart run build_runner build`. *(lib/data/db/app_database.dart, app_database.g.dart)*
- [X] **T005** [P] **Migration test** — seed a real **v4 file DB** (messages + tool columns + index), open
  at v5: old rows intact, `memory_enabled` defaulted true, a `memories` insert/readback round-trips,
  and `ON DELETE SET NULL` nulls `sourceConversationId` on conversation delete. *(test/data/)*
- [X] **T006** [P] `Memory` entity + `MemoryCategory` enum + `UpsertResult` sealed type (data-model §1).
  *(lib/domain/entities/memory.dart)*
- [X] **T007** [P] Extend `AppSettings` with `memoryEnabled` (default true) + `copyWith`/eq/hash.
  *(lib/domain/entities/app_settings.dart)*
- [X] **T008** `MemoryRepository` interface (contracts/memory_repository.md). *(lib/domain/repositories/memory_repository.dart)*

## Phase 3 — US4: Dedupe / supersede repository (Priority: P2 — but the store underpins US1/US2/US5)

> Built early because every capture path depends on a coherent store.

- [X] **T009** [P] **Repository tests** (in-memory drift): exact-restate → `unchanged` (no dup); name→name
  & dark→light supersede (Jaccard ≥ threshold) → `superseded`; distinct same-category facts NOT merged
  (false-merge guard); cap > 20 deactivates oldest; `softDeleteById` true/false; `clearAll`; `editFact`;
  `ON DELETE SET NULL` provenance. *(test/unit/ + test/data/)*
- [X] **T010** `DriftMemoryRepository`: `watchActive`/`listActive` (ordered category→updatedAt desc),
  `upsert` (normalize → exact → Jaccard supersede → insert → cap), `softDeleteById` (validate active),
  `editFact`, `clearAll`, `activeCount`. *(lib/data/repositories/drift_memory_repository.dart)*
- [X] **T011** [P] `memoryRepositoryProvider` + `activeMemoriesProvider` (stream) + `FakeMemoryRepository`
  test double. *(lib/features/.../providers + test/helpers/)*

## Phase 4 — US1: Capture a fact (Priority: P1) 🎯 MVP write loop

- [X] **T012** [P] `SchemaValidator` `maxLength` keyword + tests (over-length string → `Invalid` with
  reason; registry self-validation still passes). *(lib/core/tools/schema_validator.dart, test/unit/)*
- [X] **T013** Add `memoryTools` (`remember_fact`, `forget_fact`) to `ToolRegistry`; split
  `deviceTools`/`memoryTools`/`specs`; descriptions per spike §3/§4. Update the registry-sanity test
  (six tools, unique names, self-validating schemas, `kind` set). *(lib/core/tools/tool_registry.dart, test/unit/)*
- [X] **T014** [P] Dispatcher handler tests: `remember_fact` created vs superseded vs unchanged mapping;
  invalid args (bad category, >80-char fact) → `ToolInvalidArgs`; handler-throws → `ToolFailure`;
  congruence over ≤6 declared tools; `forget_fact` int-double coercion. *(test/unit/)*
- [X] **T015** Bind `remember_fact`/`forget_fact` handlers to `MemoryRepository` in `toolHandlersProvider`
  (inject the active `sourceConversationId`); `remember_fact` guards `memoryEnabled` (toggle-window →
  `ToolFailure('memory is off')`). *(lib/features/chat/tool_handler_providers.dart)*
- [X] **T016** Compose `declaredTools` in the session provider = `deviceTools` (if `functionCalling`) `+
  memoryTools` (if `functionCalling && memoryEnabled`); thread into `loadModel`. *(lib/features/chat/chat_providers.dart)*
- [X] **T017** [P] Chip summary text for `remember_fact` (`remembered:`/`updated:`) + `forget_fact`
  (`forgot #id`) in the controller's summary mapping; reuse 004 `_runToolTurn` unchanged. *(lib/features/chat/chat_controller.dart)*
- [X] **T018** [P] Widget test: a `remember_fact` chip renders on capture; a no-fact prompt produces no
  chip; an invalid capture renders an error chip + reply (US1 AS1–AS3). *(test/widget/)*

## Phase 5 — US2: Injection grounds future conversations (Priority: P1) 🎯 MVP read loop

- [X] **T019** [P] `FactsBlockComposer` + tests: id-prefixed, category-ordered, updatedAt-desc; cap ≤20
  facts / ≤900 chars with oldest-first drop; empty store → empty string. *(lib/core/memory/facts_block_composer.dart, test/unit/)*
- [X] **T020** [P] `SystemInstructionComposer` + tests: joins [facts block?] + [capture instruction?] +
  [device tool-use instruction?] by (`memoryEnabled`,`functionCalling`); returns `null` when all empty
  (byte-parity); capture instruction wording per R5. *(lib/core/memory/system_instruction_composer.dart, test/unit/)*
- [X] **T021** Seam: add `systemInstruction:` to `loadModel` (forward to `createChat`; drop the internal
  `ToolRegistry.systemInstruction` hardcode) + extend `FakeGemmaService` to record it. *(lib/domain/services/gemma_service.dart, lib/infrastructure/gemma/flutter_gemma_service.dart, test/helpers/)*
- [X] **T022** Seam: add `startSession({systemInstruction})` — `await _chat.session.close()` → `createChat`
  on the loaded model with the new instruction (same tools/caps); reset warm fingerprints + bump epoch;
  `StateError` if not loaded (contracts/gemma_service.md guarantee 27). Model it in `FakeGemmaService`. *(lib/infrastructure/gemma/flutter_gemma_service.dart, lib/domain/services/gemma_service.dart, test/helpers/)*
- [X] **T023** Session provider composes the system instruction (via the composer, reading
  `activeMemories` + flags) and passes it to `loadModel`. *(lib/features/chat/chat_providers.dart)*
- [X] **T024** Controller calls `startSession` (recomposed instruction) on `openConversation` so a NEW
  conversation is grounded in facts saved earlier; `generate` stays per-call-instruction-free
  (facts can't change mid-chat, FR-008). *(lib/features/chat/chat_controller.dart)*
- [X] **T025** [P] `ContextAssembler`: reserve `memoryReserveTokens` (~225 block + ~86 capture when both
  active) off the budget, alongside the existing 40-token tool reserve; tests for the reserve math. *(lib/features/chat/context_assembler.dart, test/unit/)*
- [X] **T026** [P] Controller test (FakeGemmaService): a fact captured mid-conversation does NOT alter the
  current chat's recorded instruction, but the NEXT `openConversation` composes a block containing it
  (US2 AS1/AS3). *(test/widget/ or test/unit/)*

## Phase 6 — US3: Memory management screen (Priority: P2)

- [X] **T027** [P] `memoryEnabledProvider` (Notifier over `app_settings.memoryEnabled`, mirrors
  `themeModeProvider`) + `SettingsRepository.read/setMemoryEnabled`. *(lib/data/repositories/settings_repository.dart)*
- [X] **T028** [P] `MemoryController` — add (manual), edit, delete, clearAll, setEnabled; `setEnabled`
  triggers a session refresh (`startSession`) so the toggle applies promptly (FR-014). *(lib/features/settings/memory_controller.dart)*
- [X] **T029** `MemoryScreen` — facts grouped by category (matching the injected set, FR-015), per-row edit
  + delete, clear-all behind a destructive confirm (red), a global on/off toggle; design-system §8
  tokens, lowercase microcopy, monochrome with red only on destructive. *(lib/features/settings/memory_screen.dart)*
- [X] **T030** Settings entry row → memory screen + route. *(lib/features/settings/settings_screen.dart, lib/app/router.dart)*
- [X] **T031** [P] Widget + a11y tests: list grouping matches active facts; edit persists; delete removes;
  clear-all empties (after confirm); toggle off → provider reflects off; 48dp/AA; works under a
  text-only model (management not gated, US3 AS5). *(test/widget/)*

## Phase 7 — US5: Forget by asking (Priority: P3)

- [X] **T032** [P] Dispatcher/handler tests: `forget_fact(valid id)` → success + soft-delete; unknown/stale
  id → `ToolFailure('no such fact')` (no deletion); guessed-id hazard (spike §4) covered. *(test/unit/)*
- [X] **T033** Verify `forget_fact` end-to-end through the existing `_runToolTurn` (chip + reply); ensure
  the injected block carries ids so the model can reference a real fact (depends on T019/T024). *(lib/features/chat/ — wiring/verification)*
- [X] **T034** [P] Widget test: forget chip on success; honest error chip + no deletion on unknown id (US5
  AS1–AS3). *(test/widget/)*

## Phase 8 — US6 + US7: Capability gating, transparency, honest failure (Priority: P3)

- [X] **T035** [P] Byte-parity test (extends SC-010/guarantee 29): `functionCalling` off + memory empty/off
  → composed instruction `null`, no tools declared, `generate` emits only `TextDelta`s; existing
  chat (text/image/audio) unchanged. *(test/unit/ + test/widget/)*
- [X] **T036** [P] Test: injection works with `functionCalling` off (a text-only model still receives the
  facts block) while capture tools are NOT declared (FR-009/FR-018). *(test/unit/)*
- [X] **T037** [P] Test: memory chips render in reopened history regardless of active capability (FR-019);
  cap-exceeded capture + capture-while-disabled degrade to visible chips, never crash (FR-020). *(test/widget/)*
- [X] **T038** [P] Confirm the 004 LeakFilter suppresses raw `remember_fact`/`forget_fact` call JSON (no new
  code expected; add a regression assertion). *(test/unit/)*

## Phase 9 — Polish & device validation

- [X] **T039** [P] `tool/check_plugin_seam.sh` review — no new plugin to confine; confirm `MemoryRepository`
  stays behind its interface and the seam stays the only flutter_gemma importer. *(tool/check_plugin_seam.sh)*
- [X] **T040** [P] Run `tool/check_network_seam.sh` + a code audit confirming no embeddings/vector/network
  path was added (SC-014, Principle I/IX). *(CI)*
- [X] **T041** [P] `flutter analyze` + full unit/widget suite green; `dart format`. *(repo)*
- [X] **T042** Update `AGENTS.md`/`CLAUDE.md` managed Spec-Kit section to 005
  (`/speckit-agent-context-update`). *(AGENTS.md)*
- [X] **T043** [P] `checklists/requirements.md` — spec-quality checklist for 005. *(specs/005-memory/checklists/)*
- [X] **T050** Shipped **reliability harness** (`integration_test/`) — the 30-prompt capture/false-positive
  suite + a token-budget assertion, runnable via `flutter drive` (quickstart V9); tune the R5 capture
  instruction here to clear SC-001 (≥75%) with 0 false positives. *(integration_test/, test_driver/ exists)*
- **T051** Device walkthrough V1–V8 (capture, injection, next-session, dedupe/supersede, forget,
  settings, toggle, restart) on the A34 via `flutter run`. *(quickstart.md)*
- **T052** Cross-cutting device gates V10–V13 (capability-off regression, airplane mode, token budget,
  Accessibility Scanner). *(quickstart.md)*

---

## Dependencies & parallelization

- **Foundational (T003–T008) blocks everything.** Within it: T003→T004→T005; T006/T007/T008 are [P].
- **US4 store (T009–T011)** depends on Foundational; underpins US1/US2/US5.
- **US1 (T012–T018)** depends on the store (T010) + registry (T013); T012/T014/T017/T018 are [P].
- **US2 (T019–T026)** depends on the store (T010) + seam changes (T021/T022); composers T019/T020 are
  [P] and can start right after Foundational.
- **US5 (T032–T034)** depends on US2's id-bearing injection (T019/T024) + the registry (T013).
- **US3 (T027–T031)** depends on the store (T010); largely independent of the model path → highly
  parallel.
- **US6/US7 (T035–T038)** depend on US1+US2 wiring; all [P] tests.
- **Polish/device (T039–T052)** last; T050–T052 require the device.

**MVP = Foundational + US4 store + US1 + US2** (capture a fact → it grounds the next conversation,
deduped, visible as chips). US3/US5/US6/US7 layer on independently.

## Suggested execution order

1. T001–T002 (setup) → T003–T008 (foundational) → T005 test.
2. T009–T011 (store) → T012–T018 (US1 capture) → T019–T026 (US2 injection). **← MVP**
3. T027–T031 (US3 settings) ‖ T032–T034 (US5 forget).
4. T035–T038 (US6/US7 gating + failure).
5. T039–T043 (polish/audit) → T050 (reliability harness) → T051–T052 (device walkthrough + gates).
