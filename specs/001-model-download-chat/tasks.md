---

description: "Task list for First Working Slice — Model Download & Chat"
---

# Tasks: First Working Slice — Model Download & Chat

**Input**: Design documents from `/specs/001-model-download-chat/`
**Prerequisites**: [plan.md](plan.md), [spec.md](spec.md), [research.md](research.md),
[data-model.md](data-model.md), [contracts/](contracts/), [quickstart.md](quickstart.md)

**Tests**: INCLUDED. The constitution (Principle VII + the Test Quality Gate) makes
domain/presentation unit-testability mandatory, so every story carries test tasks built on the
seam fakes (`FakeGemmaService`, `FakeModelDownloader`, `FakeConversationRepository`,
`FakeDevicePreflightService`) and an in-memory `drift` DB — no native plugin, no device, no
network.

**Organization**: Tasks are grouped by user story (US1–US5 from the spec, in priority order).

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependency on an incomplete task)
- **[Story]**: US1–US5 (user-story phases only)
- All paths are repository-relative. Stack & versions: see [research.md](research.md).

## Path Conventions

Single Flutter module (per [plan.md](plan.md)): app code under `lib/`, tests under `test/`,
Android config under `android/`. The plugin seam rule is structural: **`flutter_gemma` may be
imported only in `lib/infrastructure/gemma/`**.

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Project initialization, dependencies, Android config, fonts.

- [X] T001 Initialize the Flutter module and create the layered directory skeleton from [plan.md](plan.md) (`lib/app`, `lib/core`, `lib/domain`, `lib/data`, `lib/infrastructure`, `lib/features`, `test/unit`, `test/widget`, `test/helpers`)
- [X] T002 Add and pin dependencies in `pubspec.yaml` per [research.md](research.md): `flutter_gemma: 0.16.4`, `background_downloader: ^9.5.5`, `drift`, `drift_flutter`, `flutter_riverpod: 3.3.1`, `device_info_plus` (>=11.4.0), `path_provider`, `google_fonts`; dev: `drift_dev`, `build_runner`, `flutter_lints` — _SDK-driven deviation: prerelease Dart 3.10.0-213.0.dev caps `flutter_gemma` at 0.12.6 (target 0.16.4) and drift at 2.31.0 (target 2.33.0); documented in `pubspec.yaml`._
- [X] T003 [P] Configure Android in `android/app/build.gradle(.kts)`: `minSdk 29`, `ndk { abiFilters 'arm64-v8a' }`, Kotlin `2.1.0+`; declare foreground-service + `POST_NOTIFICATIONS` per `background_downloader` in `android/app/src/main/AndroidManifest.xml`
- [X] T004 [P] Bundle offline fonts as assets and declare them in `pubspec.yaml`: Space Grotesk, Space Mono, MatrixSans (+ each `OFL.txt`) under `assets/fonts/`; set `GoogleFonts.config.allowRuntimeFetching = false` and register licenses via `LicenseRegistry` in `lib/main.dart` — _dot-matrix face: Pixelify Sans (OFL) bundled in place of "MatrixSans" (design-system §3 leaves the specific dot font open)._
- [X] T005 [P] Configure `analysis_options.yaml` (flutter_lints) and add a lint rule/CI note forbidding `flutter_gemma` imports outside `lib/infrastructure/gemma/` (Principle VII) — _enforced via `tool/check_plugin_seam.sh` (CI/pre-commit guard)._

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Shared infrastructure every user story depends on — theme, entities, seam
interfaces, persistence, and the test harness.

**⚠️ CRITICAL**: No user story work can begin until this phase is complete.

### Design system & app shell

- [X] T006 [P] Implement design tokens in `lib/app/theme/app_colors.dart` (dark + light token sets per `.specify/memory/design-system.md`) — centralized, no hardcoded hex elsewhere (Principle X) — _as a `ThemeExtension<AppColors>`._
- [X] T007 [P] Implement `lib/app/theme/app_text.dart` (Space Grotesk UI, Space Mono spec labels uppercase, `AppText.dotMatrix()` helper) and `lib/app/theme/app_spacing.dart` (4dp grid)
- [X] T008 Build `lib/app/theme/app_theme.dart`: M3 `ColorScheme.dark`, `scaffoldBackgroundColor #000000`, `elevation: 0`, `surfaceTintColor`/`shadowColor` transparent, hairline dividers, default padded 48dp tap targets (depends on T006, T007)
- [X] T009 Create `lib/main.dart` (+ `ProviderScope`) and `lib/app/app.dart` + `lib/app/router.dart` with route skeletons for onboarding, download, chat, history, settings (depends on T008)

### Domain entities & seam interfaces (pure Dart)

- [X] T010 [P] Define entities in `lib/domain/entities/`: `conversation.dart`, `message.dart` (+ `MessageRole`, `MessageStatus` enums), `model_install.dart` (+ state enum), `app_settings.dart` (+ `ThemeMode`), `device_capability.dart` (+ `IneligibleReason`), `model_capabilities.dart`, `chat_turn.dart` — per [data-model.md](data-model.md) — _`ThemeMode` named `AppThemeMode` to avoid the Material clash; pure Dart via `package:meta`._
- [X] T011 [P] Define seam interface `lib/domain/services/gemma_service.dart` per [contracts/gemma_service.md](contracts/gemma_service.md)
- [X] T012 [P] Define seam interface `lib/domain/services/model_downloader.dart` per [contracts/model_download.md](contracts/model_download.md)
- [X] T013 [P] Define seam interface `lib/domain/services/device_preflight_service.dart` per [contracts/device_preflight.md](contracts/device_preflight.md)
- [X] T014 [P] Define repository interface `lib/domain/repositories/conversation_repository.dart` per [contracts/conversation_repository.md](contracts/conversation_repository.md)

### Persistence (drift) & settings

- [X] T015 Define drift tables in `lib/data/db/tables.dart` (`conversations`, `messages`, `model_install`, `app_settings`) with FK + indexes per [data-model.md](data-model.md) (depends on T010) — _`@DataClassName('*Row')` so generated rows don't clash with domain entities._
- [X] T016 Build `lib/data/db/app_database.dart` (drift_flutter app-private DB, `PRAGMA foreign_keys=ON`, `schemaVersion 1`, `MigrationStrategy.onCreate`) and run `dart run build_runner build` (depends on T015) — _`storeDateTimeAsText: true` for sub-second history ordering (FR-020)._
- [X] T017 Implement `lib/data/db/daos/conversation_dao.dart` (reactive `watch` queries ordered by `updatedAt DESC`, message CRUD, cascade delete) (depends on T016)
- [X] T018 Implement `lib/data/repositories/drift_conversation_repository.dart` (implements `ConversationRepository`: title derivation, append/begin/update/finalize message, `loadTurns`, delete) + Riverpod provider (depends on T017, T014)
- [X] T019 Implement `lib/data/repositories/settings_repository.dart` (read/write `app_settings`: `themeMode` FR-023/FR-024, `licenseAcknowledgedAt` Q1) + a theme-mode Notifier provider applied at app root (depends on T016, T009)

### Test harness

- [X] T020 [P] Implement seam fakes in `test/helpers/`: `fake_gemma_service.dart`, `fake_model_downloader.dart`, `fake_conversation_repository.dart`, `fake_device_preflight_service.dart` per the contracts' "test double" sections
- [X] T021 [P] Implement `test/helpers/test_db.dart` (in-memory `NativeDatabase.memory()` drift) and `test/helpers/container_harness.dart` (`ProviderContainer` with overrides) — _`Override` imported from `package:flutter_riverpod/misc.dart` (Riverpod 3 split entrypoints)._
- [X] T022 [P] Repository tests in `test/unit/data/drift_conversation_repository_test.dart` using in-memory drift: create/append, ordering, title derivation, `watch` emissions, cascade delete (FR-018/FR-020/FR-021/FR-022, SC-006) — _8 tests, all passing._

**Checkpoint**: Theme, entities, seams, persistence, and fakes ready — user stories can begin.

---

## Phase 3: User Story 1 — Onboard & install the default model (Priority: P1) 🎯 MVP

**Goal**: First-run dark onboarding → license ack → preflight → cancellable, progress-reporting
download → installed, routing into chat.

**Independent Test**: Fresh install on a supported device reaches an "installed/ready" state via
on-screen guidance; cancel mid-download returns cleanly with no partial model.

### Tests for US1

- [ ] T023 [P] [US1] Unit test `test/unit/features/download_controller_test.dart` with `FakeModelDownloader`: progress mapping (percent+bytes), cancel ends within 2s (SC-003), failure→retry, partial never exposed as installed (FR-007/FR-008/FR-011)
- [ ] T024 [P] [US1] Widget tests `test/widget/onboarding_test.dart`: welcome explainer is dark + shown first (FR-001/FR-023, SC-010), license-ack gates the download (Q1), download screen shows live progress + cancel (FR-007/FR-008)

### Implementation for US1

- [ ] T025 [P] [US1] Implement `lib/core/platform/device_info_preflight_service.dart` (implements `DevicePreflightService` via `device_info_plus`: RAM≥7000MB, arm64-v8a) + provider (FR-003/FR-005, R4)
- [ ] T026 [US1] Implement `lib/data/model/background_model_downloader.dart` (implements `ModelDownloader` via `background_downloader`: enqueue, foreground config, `updates`→`DownloadProgress`, cancel, `.part`→atomic rename + free-space check, `installedModelPath`/`installedSizeBytes`/`deleteModel`) + provider; record `ModelInstall` on success (FR-007–FR-011, FR-030, R2)
- [ ] T027 [P] [US1] Build onboarding feature in `lib/features/onboarding/`: `welcome_screen.dart` (dot-matrix wordmark, lowercase tagline, privacy explainer), `license_screen.dart` (checkbox ack persisted), `onboarding_controller.dart` (calls preflight; eligible→proceed) (FR-001/FR-002/FR-005)
- [ ] T028 [US1] Build download feature in `lib/features/download/`: `download_controller.dart` (Notifier consuming `ModelDownloader.download` stream, cancel, retry) and `download_screen.dart` (dot-matrix `%`, thin progress bar, mono bytes readout, monochrome cancel) routing to chat on complete (FR-007–FR-010, depends on T026)
- [ ] T029 [US1] Wire first-run routing in `lib/app/router.dart`: no model installed → onboarding/download; model installed → chat (depends on T028, T019)

**Checkpoint**: US1 independently demoable — onboard → download → installed/ready.

---

## Phase 4: User Story 2 — Streaming, stoppable reply (Priority: P1)

**Goal**: Send a text message; reply streams incrementally; an always-visible stop control halts
generation within 1s and retains partial text; input is single-in-flight.

**Independent Test**: With a model installed, sending a message renders an incremental reply;
stop mid-reply halts at once and keeps the partial text in the thread.

### Tests for US2

- [ ] T030 [P] [US2] Unit test `test/unit/features/chat_controller_test.dart` with `FakeGemmaService` + in-memory repo: send persists user msg, deltas append to a `streaming` assistant msg, stop finalizes `stoppedPartial` retaining 100% text (FR-013/FR-014, SC-005), send disabled while generating (Q4)
- [ ] T031 [P] [US2] Widget test `test/widget/chat_screen_test.dart`: reply renders in multiple updates not one block (FR-013), stop control replaces send during generation and is the only red affordance (Q4, design system), list stays scrollable while streaming (SC-011)

### Implementation for US2

- [ ] T032 [US2] Implement `lib/infrastructure/gemma/flutter_gemma_service.dart` (implements `GemmaService` via `flutter_gemma` 0.16.4: `loadModel`/`generate` stream/`stop`/`close`/`capabilities`; close prior model before load) + kept-alive model provider — **the only flutter_gemma import** (FR-013/FR-014/FR-016/FR-029, R1, Principle VII)
- [ ] T033 [US2] Implement model lifecycle in `lib/features/chat/chat_providers.dart`: load model from `ModelInstall.filePath` on entering chat; release on leaving chat and on app-background via `AppLifecycleListener` (FR-029, Principle VIII, R5)
- [ ] T034 [US2] Implement `lib/features/chat/chat_controller.dart` (Notifier holding messages + `isGenerating` + `StreamSubscription`; send→persist user msg→begin assistant msg→consume `generate` stream→`updateAssistantContent`→finalize; `stop()` calls `GemmaService.stop` + cancels subscription + finalizes `stoppedPartial`) (FR-012–FR-014, depends on T032, T018)
- [ ] T035 [P] [US2] Build chat UI in `lib/features/chat/`: `chat_screen.dart`, `widgets/message_bubble.dart` (user filled `surfaceContainerHigh` right / assistant borderless left, no color), `widgets/composer.dart` (text input; send↔stop swap; stop = red), streaming cursor / dot-matrix pulse loader (FR-013/FR-015, design system)
- [ ] T036 [US2] Gate input affordances in `lib/features/chat/widgets/composer.dart` from `GemmaService.capabilities` data (text-only this slice; no image/audio/thinking shown) — data-driven, not hardcoded per-model (FR-016, Principle III, depends on T035)

**Checkpoint**: US1 + US2 deliver the core MVP — install then chat with streaming + stop.

---

## Phase 5: User Story 3 — Conversational memory (Priority: P2)

**Goal**: Replies account for prior turns of the same conversation, including stopped-partial
turns; on context overflow a sliding window keeps the most recent turns.

**Independent Test**: Establish a fact, ask a dependent follow-up; the assembled context includes
the earlier turns (verified by inspecting the assembled context).

### Tests for US3

- [ ] T037 [P] [US3] Unit test `test/unit/features/context_assembler_test.dart`: assembled context includes prior turns + stopped-partial turn (FR-017); overflow drops oldest turns only (sliding window, Q2) while stored history is untouched

### Implementation for US3

- [ ] T038 [US3] Implement `lib/features/chat/context_assembler.dart` (build ordered `List<ChatTurn>` from `ConversationRepository.loadTurns`, include stopped-partial, trim oldest to fit a token budget) (FR-017, Q2, depends on T018)
- [ ] T039 [US3] Wire the assembler into `chat_controller.dart` so `GemmaService.generate(history:, prompt:)` receives the sliding-window context (depends on T038, T034)

**Checkpoint**: Follow-ups are context-aware across turns.

---

## Phase 6: User Story 4 — Persistent conversations & history (Priority: P2)

**Goal**: Conversations persist across restarts; a history list shows labeled, timestamped past
conversations; start new, open, and delete.

**Independent Test**: Hold a conversation, force-quit, relaunch → intact and ordered; new + open +
delete all work from the list.

### Tests for US4

- [ ] T040 [P] [US4] Widget test `test/widget/history_screen_test.dart` with in-memory repo: list updates reactively on new/delete, shows first-message label + timestamp, opens a conversation, deletes one (FR-019–FR-022)
- [ ] T041 [P] [US4] Unit test `test/unit/features/history_controller_test.dart`: new conversation, switch/open loads its messages, delete removes it (FR-019/FR-020/FR-022)

### Implementation for US4

- [ ] T042 [US4] Implement `lib/features/history/history_controller.dart` (consumes `watchConversations`; new/open/delete actions) (depends on T018)
- [ ] T043 [US4] Build `lib/features/history/history_screen.dart`: reactive list rows (label + timestamp rendered in `textSecondary` per the AA rule in [research.md](research.md) R6, **not** `textMuted`), new-conversation action, delete with destructive-red confirm (FR-020/FR-021/FR-022, FR-031)
- [ ] T044 [US4] Wire navigation in `lib/app/router.dart` and `lib/features/chat/chat_controller.dart`: history ↔ chat, conversation switching loads the selected conversation's messages; "new conversation" starts an empty thread preserving prior ones (FR-019/FR-020, depends on T043, T034)

**Checkpoint**: History persists, is browsable, and manageable.

---

## Phase 7: User Story 5 — Honest device preflight (Priority: P3)

**Goal**: Unsupported devices are told clearly, before any download, why the model can't install —
no crash/OOM.

**Independent Test**: Simulate insufficient RAM or non-arm64 device → clear blocked message, no
download starts; supported device passes silently.

### Tests for US5

- [ ] T045 [P] [US5] Unit/widget tests `test/widget/preflight_gate_test.dart` with `FakeDevicePreflightService`: insufficient memory (6GB), unsupported ABI, and boundary (7000MB → eligible); ineligible blocks the download and shows the specific reason (FR-003/FR-004/FR-006, SC-008)

### Implementation for US5

- [ ] T046 [US5] Add the ineligible path in `lib/features/onboarding/`: a `preflight_blocked_screen.dart` with an honest, reason-specific message (`insufficientMemory` / `unsupportedAbi`) that does not start the download; soft-warn band (6500–7000MB) messaging (FR-004/FR-006, R4)
- [ ] T047 [US5] Harden `device_info_preflight_service.dart` (Platform.isAndroid guard, `reason` mapping, soft-warn) and route `onboarding_controller` to the blocked screen when `!isEligible` (depends on T025, T046)

**Checkpoint**: Graceful degradation path complete and independently testable.

---

## Phase 8: Polish & Cross-Cutting Concerns

**Purpose**: Settings, edge cases, and the constitution's release gates.

- [ ] T048 [P] Build `lib/features/settings/settings_screen.dart` + `settings_controller.dart`: model storage row (on-disk size + delete → reclaim → return to onboarding, FR-030) and theme toggle (dark/light/system, persisted, FR-024)
- [ ] T049 [P] Implement edge/empty/error states across `lib/features/chat/` and `lib/features/download/`: empty chat in `chat_screen.dart`, empty-message send guard in `widgets/composer.dart`, download error+retry and storage-full message in `download_screen.dart`, stop-before-first-token in `chat_controller.dart` (Edge Cases in [spec.md](spec.md))
- [ ] T050 [P] Accessibility pass (Android Accessibility Scanner): all interactive controls ≥48dp + WCAG AA; confirm timestamps use `textSecondary`, red only as large/icon/fill (FR-031, SC-012, quickstart V7)
- [ ] T051 [P] Offline & privacy validation: airplane-mode run (SC-007) and a network audit proving the only network call is the model download — no content leaves the device (SC-009, Principle I/II, quickstart V6)
- [ ] T052 [P] Performance validation in `--release`: first reply text within 5s on the reference device (SC-004) and gesture response within 100ms while streaming (SC-011, quickstart V2)
- [ ] T053 Resource-hygiene verification: exactly one active model, release on chat-exit and app-background, no ~2.4GB leak (FR-029, Principle VIII, quickstart V8)
- [ ] T054 Execute the full [quickstart.md](quickstart.md) V1–V8 validation on a baseline device and record results

---

## Dependencies & Execution Order

### Phase dependencies

- **Setup (Phase 1)**: no dependencies — start immediately.
- **Foundational (Phase 2)**: depends on Setup — **blocks all user stories**.
- **User Stories (Phases 3–7)**: each depends on Foundational. Then:
  - US1 (P1) and US2 (P1) are the MVP; US2's chat model-load (T032/T033) assumes US1 produced an
    installed model, but US2 is independently testable via `FakeGemmaService`.
  - US3 (P2) builds on US2's chat controller. US4 (P2) is independent (history/persistence).
  - US5 (P3) extends US1's preflight; independently testable via `FakeDevicePreflightService`.
- **Polish (Phase 8)**: depends on the targeted stories being complete.

### Story dependency notes

- US1 → none (foundational only). US2 → foundational; shares the chat surface US3 extends.
- US3 → US2 (extends `chat_controller`). US4 → foundational only (independent of US2/US3).
- US5 → reuses US1's `DevicePreflightService` (foundational interface + US1 concrete).

### Within each story

- Tests (where listed) are written against fakes and should fail before implementation.
- Interfaces (Foundational) before concretes; models before services before UI; controller before
  screen wiring.

---

## Parallel Opportunities

- **Setup**: T003, T004, T005 in parallel after T002.
- **Foundational**: T006/T007 (theme) ∥ T010–T014 (entities + interfaces) ∥ T020/T021 (harness);
  DB chain T015→T016→T017→T018 is sequential; T022 after T018.
- **US1**: T023 ∥ T024 (tests); T025 ∥ T027 ∥ (T026 then T028).
- **US2**: T030 ∥ T031 (tests); T035 ∥ T032 (then T034, T036).
- **US4**: T040 ∥ T041 (tests); then T042→T043→T044.
- **Polish**: T048–T052 are all [P] (different files / independent checks).

```bash
# Example — Foundational fan-out (after Setup):
Task: "T010 entities in lib/domain/entities/"
Task: "T011 GemmaService interface in lib/domain/services/gemma_service.dart"
Task: "T012 ModelDownloader interface in lib/domain/services/model_downloader.dart"
Task: "T013 DevicePreflightService interface in lib/domain/services/device_preflight_service.dart"
Task: "T014 ConversationRepository interface in lib/domain/repositories/conversation_repository.dart"
```

---

## Implementation Strategy

### MVP first (US1 + US2)

1. Phase 1 Setup → Phase 2 Foundational (CRITICAL — blocks everything).
2. Phase 3 US1 → **STOP & VALIDATE**: onboard → download → installed (quickstart V1).
3. Phase 4 US2 → **STOP & VALIDATE**: streaming chat with stop (quickstart V2). This is the
   demoable MVP.

### Incremental delivery

US3 (memory) → US4 (history) → US5 (preflight path) → Polish. Each story is a checkpoint that
adds value without breaking earlier ones.

---

## Notes

- [P] = different files, no incomplete dependency. [USn] maps a task to its story for traceability.
- Tests use the seam fakes + in-memory drift — they run with no device, no native plugin, no
  network (Principle VII).
- The plugin-seam invariant (T005 lint) must hold: `flutter_gemma` only in
  `lib/infrastructure/gemma/`.
- Commit after each task or logical group; validate at each checkpoint.
- Total: **54 tasks** (T001–T054).
