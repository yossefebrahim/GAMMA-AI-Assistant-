---

description: "Task list for Audio Input — Voice Understanding"
---

# Tasks: Audio Input — Voice Understanding

**Input**: Design documents from `/specs/003-audio-input/`
**Prerequisites**: [plan.md](plan.md), [spec.md](spec.md), [research.md](research.md),
[data-model.md](data-model.md), [contracts/](contracts/), [quickstart.md](quickstart.md),
[spike-findings.md](spike-findings.md) (verified runtime behavior — the design's ground truth)

**Tests**: INCLUDED. The constitution (Principle VII + the Test Quality Gate) makes
domain/presentation unit-testability mandatory, and capability-gating (Principle III) must be
unit-tested against representative capability data. Every story carries test tasks built on the
seam fakes (`FakeGemmaService` extended for audio, `FakeAudioRecorderService`,
`FakeAudioPreviewPlayer`, `FakeMediaPermissionService` extended for mic) + an in-memory `drift`
DB + a temp-dir audio store — no native plugin, no device, no network. Widget tests drive sends
via UI + `pump` (never bare `await`/`runAsync` over fake streams) and override the permission
provider.

**Organization**: Tasks are grouped by user story (US1–US6 from the spec, in priority order).
This feature **extends** the shipped 001/002 codebase; most foundational tasks edit existing
files.

## Format: `[ID] [P?] [~?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependency on an incomplete task)
- **[~]**: Has a physical-device portion — the task is complete only after the on-device pass
  (run via `flutter run` / `flutter drive`; **NEVER `flutter test integration_test/...`**, which
  uninstalls the app and wipes the model + DB — spike incident log)
- **[Story]**: US1–US6 (user-story phases only)
- All paths are repository-relative. Stack & versions: see [research.md](research.md)
  (**flutter_gemma 0.15.3** installed; `record ^7.0.0`; `audioplayers ^6.7.0`).

## Path Conventions

Single Flutter module: app code under `lib/`, tests under `test/`, Android config under
`android/`. Seam rules are structural: **`flutter_gemma` only in `lib/infrastructure/gemma/`**;
`image_picker`/`permission_handler`/**`record`/`audioplayers`** only in
`lib/infrastructure/media/`.

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Add audio-input dependencies, the mic permission, and the widened seam guard.

- [X] T001 Add and pin dependencies in `pubspec.yaml` per [research.md](research.md) R2/R4: `record: ^7.0.0` and `audioplayers: ^6.7.0` (keep `flutter_gemma: ^0.15.0`, `permission_handler: ^12.0.0`). Run `flutter pub get` and record the resolved versions in research.md's pin table. If `record` 7.x fails resolution or misbehaves on-device later, the sanctioned fallback is `^6.0.0` (the version flutter_gemma's own example proves).
- [X] T002 [P] Add `<uses-permission android:name="android.permission.RECORD_AUDIO"/>` to `android/app/src/main/AndroidManifest.xml` (exactly this permission, nothing broader — contracts/media_permission.md #4); verify the merged manifest after T001.
- [X] T003 [P] Extend `tool/check_plugin_seam.sh`: add `record|audioplayers` to the existing media-confinement rule (imports forbidden outside `lib/infrastructure/media/`), mirroring the 002 extension (Principle VII).

**Checkpoint**: `flutter pub get` resolves; `tool/check_plugin_seam.sh` passes (no audio plugin imported anywhere yet).

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Audio constants + entities, seam-interface extensions, capability-as-data, the drift
v2→v3 migration + audio file store, and the extended test harness — everything every story
depends on.

**⚠️ CRITICAL**: No user story work can begin until this phase is complete.

### Constants, entities & seam interfaces (pure Dart)

- [X] T004 [P] Add `lib/core/audio_constants.dart` per [data-model.md](data-model.md) §1: `sampleRateHz=16000`, `channels=1`, WAV/PCM16 mime `audio/wav`, `maxClipDuration=30s`, `minClipDuration=500ms`, `maxPersistedBytes=2MiB`, plus the duration-from-bytes helper (`(bytes−44)/32000` s).
- [X] T005 [P] Add `lib/domain/entities/audio_input.dart` (`AudioInput { Uint8List bytes; String? mimeType }`), `lib/domain/entities/audio_attachment.dart` (`AudioAttachment { String path; String? mimeType }`), and `lib/domain/entities/pending_recording.dart` (`PendingRecording { String path; String? mimeType; int durationMs }`) per [data-model.md](data-model.md).
- [X] T006 Extend `lib/domain/entities/message.dart`: add `final AudioAttachment? audio;` (in `copyWith`/`==`/`hashCode`), with the audio-XOR-image invariant documented (user turns only).
- [X] T007 [P] Extend `lib/domain/entities/chat_turn.dart`: add `final AudioInput? audio;` (at most one of image/audio non-null) so follow-ups replay the clip (FR-016/FR-017).
- [X] T008 Extend the seam interface `lib/domain/services/gemma_service.dart` per [contracts/gemma_service.md](contracts/gemma_service.md): `generate(... AudioInput? audio)`, `class AudioProcessingException`, and the documented guarantees 13–17 (StateError when ungated — the FFI silent-drop guard; StateError on image+audio together).
- [X] T009 [P] Add seam interface `lib/domain/services/audio_recorder_service.dart` (`AudioRecorderService` + `RecordedAudio` + `RecorderUnavailableException`) per [contracts/audio_recorder.md](contracts/audio_recorder.md) — policy-free (no cap logic in the service).
- [X] T010 [P] Add seam interface `lib/domain/services/audio_preview_player.dart` (`AudioPreviewPlayer` + `AudioPreviewState`) per [contracts/audio_preview_player.md](contracts/audio_preview_player.md).
- [X] T011 [P] Extend `lib/domain/services/media_permission_service.dart` with `micStatus()` / `requestMic()` per [contracts/media_permission.md](contracts/media_permission.md) (same enum, shared `openSettings()`).
- [X] T012 Extend the repository interface `lib/domain/repositories/conversation_repository.dart` per [contracts/conversation_repository.md](contracts/conversation_repository.md): `appendUserMessage(id, text, {ImageAttachment? image, AudioAttachment? audio})` with the XOR validation and delete-cleans-audio-files behavior documented.

### Capability as data (Principle III)

- [X] T013 Update `lib/core/model_catalog.dart`: add `static const bool supportsAudio = true;` (spike-verified for Gemma 4 E2B) and build `capabilities = ModelCapabilities(image: supportsImage, audio: supportsAudio)` — value flows catalog → `loadModel` → `capabilities` → provider, no per-model `if` (FR-006/FR-007).

### Persistence (drift v2 → v3) & audio file store

- [X] T014 Add the new columns in `lib/data/db/tables.dart`: `Messages.audioPath` (`text().nullable()`) and `Messages.audioMimeType` (`text().nullable()`) per [data-model.md](data-model.md) §2.
- [X] T015 Bump `lib/data/db/app_database.dart` to `schemaVersion => 3`; append `if (from < 3) { addColumn(messages, messages.audioPath); addColumn(messages, messages.audioMimeType); }` after the preserved `if (from < 2)` image block (keep `beforeOpen` `PRAGMA foreign_keys = ON`, `onCreate = createAll`); run `dart run build_runner build --delete-conflicting-outputs` (depends on T014).
- [X] T016 [P] Add `lib/data/audio/audio_file_store.dart` (`persist(tempPath, {mimeType})→storedPath` into app-private `audio/` with the 2 MiB/empty guard from T004, `readBytes(path)`, idempotent `deleteAll(paths)`; documents dir injectable; extension derived from mimeType via one shared helper also adopted by the image path — 002 audit L5) and a Riverpod provider.
- [X] T017 Extend `lib/data/repositories/drift_conversation_repository.dart`: map `audioPath`/`audioMimeType` ↔ `Message.audio` on every read path, accept `AudioAttachment?` in `appendUserMessage` (XOR validation; audio-only first-message fallback title), and in `deleteConversation` collect audio paths and `AudioFileStore.deleteAll` them **before** the cascade, alongside the image cleanup (depends on T012, T015, T016, T006).

### Test harness

- [X] T018 [P] Extend `test/helpers/fake_gemma_service.dart` per [contracts/gemma_service.md](contracts/gemma_service.md): record `lastAudio` + `lastHistoryAudio`; configurable capabilities (default image+audio true); scriptable `AudioProcessingException`; **actually throw** the guarantee-13 ungated StateError and guarantee-14 both-media StateError (closes 002 audit L6); keep `trailingDeltaAfterStop`.
- [X] T019 [P] Add `test/helpers/fake_audio_recorder_service.dart` and `test/helpers/fake_audio_preview_player.dart` (scriptable start/stop/cancel results, drivable amplitude + state streams, call recorders) per the contracts' test-double sections; extend `test/helpers/fake_media_permission_service.dart` with independent mic status scripting + `requestMic()` recorder.

**Checkpoint**: `flutter analyze` clean; existing 001/002 test suite still green; foundation ready for all stories.

---

## Phase 3: User Story 1 — Record a voice clip and get a reply about it (US1, P1) 🎯 MVP

**Goal**: mic tap → recording state (red pulse + elapsed) → stop → preview chip (play/remove/
re-record) → send (alone or with text) → streamed audio-grounded reply.

**Independent Test**: with audio capability on and permission granted (faked in widget tests;
real on device), record → chip → send → reply streams; on the A34, the reply reflects the clip's
actual spoken content.

### Tests for US1 (write first, against fakes — red before green)

- [X] T020 [P] [US1] Unit-test the recording state machine in `test/unit/recording_controller_test.dart`: idle→recording→previewing happy path; cap auto-stop keeps the clip + "limit reached" note; <500 ms stop discards + "too short" note; discard deletes temp; re-record replaces; preview play/stop delegates to the player and stops on remove/replace/send ([data-model.md](data-model.md) §4 transitions).
- [X] T021 [P] [US1] Unit-test audio send in `test/unit/chat_controller_audio_test.dart`: persists via `AudioFileStore` at send only; `appendUserMessage` receives the `AudioAttachment`; `generate` receives `AudioInput` bytes just-in-time; audio-only and audio+text sends; persist `ArgumentError`/`FileSystemException` → composer-inline "record again" error and no message row (002 DF-2 applied).
- [X] T022 [P] [US1] Unit-test the seam mapping in `test/unit/gemma_service_audio_test.dart` via `FakeGemmaService` + a contract-shaped test for `FlutterGemmaService`'s pure logic: ungated audio throws StateError; image+audio throws StateError; `AudioProcessingException` only when the current prompt carries audio (L4 rule).
- [X] T023 [P] [US1] Widget-test the composer flow in `test/widget/composer_record_send_test.dart` (permission provider overridden to granted, recorder/player faked): mic tap shows the recording state (elapsed text + pulse + red accent token + stop semantics), stop shows the chip with duration, chip play toggles via `FakeAudioPreviewPlayer`, remove clears, send drives the full UI+pump path and renders the streamed reply.

### Implementation for US1

- [X] T024 [P] [US1] Implement `lib/infrastructure/media/record_audio_recorder_service.dart` over `record ^7.0.0`: `RecordConfig(encoder: AudioEncoder.wav, sampleRate: 16000, numChannels: 1)` from T004 constants into an app-cache temp file; `onAmplitudeChanged` → normalized 0..1 stream; `RecorderUnavailableException` on start failure; **no permission prompting** ([contracts/audio_recorder.md](contracts/audio_recorder.md)).
- [X] T025 [P] [US1] Implement `lib/infrastructure/media/audioplayers_preview_player.dart` over `audioplayers ^6.7.0`: `DeviceFileSource` playback, single-player interrupt-on-play, state stream, full release on `stop` ([contracts/audio_preview_player.md](contracts/audio_preview_player.md)).
- [X] T026 [US1] Implement `lib/features/chat/recording_controller.dart` (manual Riverpod 3 Notifier): the [data-model.md](data-model.md) §4 state machine — permission routing via `MediaPermissionService`, cap timer + auto-stop (T004 constants), min-length discard, temp-file cleanup on discard/replace/switch, preview-player ownership, promotion to the attachment state at stop (depends on T020).
- [X] T027 [US1] Extend `lib/features/chat/attachment_controller.dart`: pending state becomes audio-XOR-image (attaching one kind replaces the other with the one-attachment note, spec Q3); pending-clip cleared on send/remove/conversation-switch; expose providers in `lib/features/chat/chat_providers.dart` for recorder/player/permission services (depends on T026).
- [X] T028 [US1] Implement the seam: extend `lib/infrastructure/gemma/flutter_gemma_service.dart` — thread `capabilities.audio` into `_activate(... supportAudio:)` (BOTH GPU and CPU attempts) and `createChat(supportAudio:)`; map prompt/history to `Message.withAudio`/`Message.audioOnly`; add the ungated-audio + both-media StateErrors; remap to `AudioProcessingException` only for current-prompt audio; extend `_TurnFingerprint` with `audioByteLength` ([contracts/gemma_service.md](contracts/gemma_service.md); depends on T008).
- [X] T029 [US1] Extend `lib/features/chat/chat_controller.dart` send path per [data-model.md](data-model.md) §4: persist via `AudioFileStore` (catching `ArgumentError` + `FileSystemException`), append with `AudioAttachment`, build `AudioInput` just-in-time, keep the M1 delta-before-stop invariant; extend `lib/features/chat/context_assembler.dart` to inject audio via the id-keyed media map (pure, no I/O) (depends on T021, T028).
- [X] T030 [P] [US1] Build the recording UI: `lib/features/chat/widgets/recording_indicator.dart` (red `accent` pulsing dot-matrix motif driven by the amplitude stream, mono/`labelSmall`-spec elapsed readout updating ≥1/s, ≥48dp stop target, recording start/stop screen-reader announcements) per design-system §2/§7 and spec FR-028/FR-029.
- [X] T031 [P] [US1] Build `lib/features/chat/widgets/audio_chip.dart`: monochrome chip (surfaceContainerHigh, hairline `outline` border, radius 8) with duration label (derived via T004 helper), play/stop toggle (composer mode only), ≥48dp monochrome remove `×` (red is RESERVED — not for remove), `Semantics` labels, broken-file placeholder.
- [X] T032 [US1] Wire `lib/features/chat/widgets/composer.dart`: replace the dead mic stub (002 audit L9) with the real flow — mic `IconButton` (outline icon idle, gated `if (capabilities.audio)`, with a `Key`), recording state swap-in, pending chip row, send-enable includes pending audio; render the sent clip's static chip in `lib/features/chat/widgets/message_bubble.dart` user turns (depends on T026, T027, T030, T031).
- [ ] T033 [~] [US1] Device pass (quickstart V2): `flutter run --release` on the A34 — record a distinctive sentence, send with "transcribe this exactly", verify the streamed reply reflects the actual spoken content (the grounding bar), recording state shows red pulse + elapsed, chip playback works.

**Checkpoint**: US1 alone is a shippable MVP — record → grounded streamed reply on a real device.

---

## Phase 4: User Story 2 — Mic affordance reflects capabilities (US2, P2)

**Goal**: mic shown iff `capabilities.audio` (data-driven), flips live on model change, pending
clip cleared with a note only for a genuinely loaded audio-incapable model; history audio chips
survive capability changes.

**Independent Test**: capability-driven widget tests (no device needed) + history rendering with
audio off.

- [X] T034 [P] [US2] Widget-test gating in `test/widget/composer_audio_gating_test.dart`: mic present with `ModelCapabilities(audio: true)`, absent with `audio: false` while text/image input still works; flips when the capabilities provider changes; **no mic and no "model does not accept audio" note while the session is AsyncLoading/AsyncError** (the 002 conflation lesson, FR-009).
- [X] T035 [P] [US2] Unit-test pending-clip clearing in `test/unit/attachment_controller_capability_test.dart`: clip cleared + note fired only when `modelSessionReadyProvider` is true and the loaded model lacks audio; nothing cleared during loading/failed states; end-to-end widget coverage of the note display (closes the 002 L2-style gap for audio).
- [X] T036 [US2] Implement the capability-flip listener for audio in `lib/features/chat/attachment_controller.dart` (mirroring the image listener, same ready-guard) and confirm `modelCapabilitiesProvider` needs no change (it already derives from the live session); history bubbles render audio chips regardless of current capabilities (via T017's read-path mapping + T032's bubble) (depends on T034, T035).

**Checkpoint**: gating is provably data-driven; the 002 masquerade bug class is regression-locked
for audio.

---

## Phase 5: User Story 3 — Follow-ups keep referring to the audio (US3, P2)

**Goal**: text-only follow-ups answer from the previously sent clip; the assembled context
verifiably contains it.

**Independent Test**: assembler/seam tests inspecting assembled context; device follow-up check.

- [X] T037 [P] [US3] Unit-test context assembly in `test/unit/context_assembler_audio_test.dart`: audio-bearing history turns carry `AudioInput` into `ChatTurn.audio` via the id-keyed map; sliding-window trim behaves; assembler stays pure (no file I/O — bytes injected by the controller); `FakeGemmaService.lastHistoryAudio` proves replay (FR-017).
- [X] T038 [US3] Verify/extend the kept-warm path in `lib/infrastructure/gemma/flutter_gemma_service.dart`: warm-match includes `audioByteLength`; a stopped/errored audio turn forces full resync; replayed audio turns map to `Message.withAudio`/`audioOnly` in `clearHistory(replayHistory:)` (depends on T028; test via T022 extensions).
- [ ] T039 [~] [US3] Device pass (quickstart V3): follow-up "which words came first in that audio?" answers from context; stop mid-stream retains the partial and the next send resyncs correctly.

**Checkpoint**: multimodal memory verified at both the contract and device levels.

---

## Phase 6: User Story 4 — Mic permission guidance (US4, P2)

**Goal**: request on first tap; denied → explainer + re-request; permanently denied → explainer +
open settings; declining never breaks text chat.

**Independent Test**: widget tests with scripted permission sequences; device pass for the real
system dialogs.

- [X] T040 [P] [US4] Widget-test the permission decision tree in `test/widget/mic_permission_flow_test.dart` (FakeMediaPermissionService scripts): granted→recording; denied→request→granted records; denied→request→denied shows the explainer; permanentlyDenied shows explainer **without** the grant button but with open-settings (recorded call); restricted explains; dismissing always returns to a usable composer; no request fires at screen build (first-use only, FR-010).
- [X] T041 [US4] Implement `Permission.microphone` mapping in `lib/infrastructure/media/permission_handler_service.dart` (`micStatus`/`requestMic` per [contracts/media_permission.md](contracts/media_permission.md)) and route the recording controller's permission states through the existing monochrome explainer dialog pattern (depends on T011, T026).
- [ ] T042 [~] [US4] Device pass (quickstart V5): real system prompt on first tap; deny / don't-ask-again / settings round-trip; text chat usable throughout.

**Checkpoint**: permission UX matches 002's camera flow exactly, mic edition.

---

## Phase 7: User Story 5 — Persistence across restarts (US5, P3)

**Goal**: clips survive restarts in place; v2 data survives the upgrade; deletion leaves no
orphans.

**Independent Test**: migration + repository tests (no device); restart/upgrade checks on device.

- [X] T043 [P] [US5] Add the migration test `test/data/migration_v2_to_v3_test.dart`: seed a REAL v2 file DB with raw SQL at `user_version=2` **including the `idx_messages_conversation` index** (002 audit I7); open at v3; assert old rows (incl. image columns) survive, new audio columns exist defaulting to NULL, FKs enforced; fresh-install `onCreate` round-trip.
- [X] T044 [P] [US5] Add repository tests in `test/data/repository_audio_test.dart` (in-memory drift + temp-dir stores): audio round-trip through `appendUserMessage`/`watchMessages`/`loadTurns`; XOR validation; audio-only fallback title; `deleteConversation` deletes audio files before cascade (no orphans from this path); `AudioFileStore` unit tests (persist/2 MiB guard/readBytes/deleteAll idempotence).
- [ ] T045 [~] [US5] Device pass (quickstart V7): force-quit/relaunch with chips in place; **upgrade-over-install from the 002 build** with a real conversation (v2→v3 on real data); deleted conversation leaves `app_flutter/audio/` clean.

**Checkpoint**: schema and files provably durable and upgrade-safe.

---

## Phase 8: User Story 6 — Honest failure handling (US6, P3)

**Goal**: every failure path (recorder busy, interruption, storage, unprocessable clip, OOM-ish)
ends in a clear message and a usable app.

**Independent Test**: scripted-failure unit/widget tests; induced interruptions on device.

- [X] T046 [P] [US6] Unit/widget-test the failure matrix in `test/unit/recording_failures_test.dart` + `test/widget/audio_error_banner_test.dart`: `RecorderUnavailableException` → composer message; backgrounding/focus-loss mid-recording → stop-and-keep (≥min) or discard+note (<min) via the lifecycle hook; scripted `AudioProcessingException` from `FakeGemmaService` → turn finalized `stoppedPartial`, dismissible banner "couldn't process this audio — try a shorter clip, or send without it", `isGenerating` reset; generic error on an audio-free follow-up is NOT remapped (L4 regression lock).
- [X] T047 [US6] Implement the failure wiring: lifecycle-listener stop-recording-on-background in `lib/features/chat/recording_controller.dart`; `AudioProcessingException` catch + banner in `lib/features/chat/chat_controller.dart`; recorder-unavailable + store-failure inline errors in the composer path; player release on backgrounding (depends on T026, T029).
- [ ] T048 [~] [US6] Device pass (quickstart V4): cap auto-stop, too-short discard, background-during-recording, call-interruption — each with the specified outcome and no crash/hang.

**Checkpoint**: the graceful-degradation promise holds under induced failure.

---

## Phase 9: Polish, device gates & spike cleanup

- [X] T049 [P] Remove the spike artifacts: delete `integration_test/spike_audio_grounding_test.dart`, drop the `integration_test` dev-dependency block from `pubspec.yaml` (run `flutter pub get`), **keep** `test_driver/integration_test.dart` (the sanctioned device-run vehicle) and keep [spike-findings.md](spike-findings.md) (the durable evidence).
- [X] T050 [P] Run the static gates and fix any findings: `flutter analyze`, full `flutter test`, `tool/check_plugin_seam.sh` (now covering record/audioplayers), `tool/check_network_seam.sh` (audio adds zero egress).
- [ ] T051 [~] Offline/privacy gate (quickstart V8): airplane-mode record→send→reply→3 follow-ups with a network monitor — zero requests carrying audio content.
- [ ] T052 [~] Performance & memory gate (quickstart V9, `--release`, median of 5): recording state ≤500 ms after tap (SC-004); 30 s-clip first reply words ≤15 s (SC-003); 100 ms gestures while recording and streaming (SC-010); `dumpsys meminfo` envelope vs the spike numbers (R7.4 — investigate >+500 MB over text baseline).
- [ ] T053 [~] Accessibility gate (quickstart V10): Accessibility Scanner over composer/recording/chip/explainer (48dp, AA); TalkBack announces recording start/stop; chip exposes duration + play/remove labels (SC-011).
- [ ] T054 Re-run the post-design constitution check in [plan.md](plan.md) against the as-built code (the three ⚠ items must be ✅ with device evidence); update `specs/003-audio-input/checklists/requirements.md` notes if any Q1–Q3 provisional decision changed during review.

---

## Dependencies & execution order

```
Phase 1 (Setup) ─► Phase 2 (Foundational) ─► US1 (P1, MVP) ─► US2 ─► US3 ─► US4 ─► US5 ─► US6 ─► Phase 9
                                              │
                                              └─ US2/US4/US5 are independently startable after
                                                 Phase 2 + the specific US1 tasks they touch:
                                                 US2 needs T027/T032; US4 needs T026; US5 only
                                                 needs Phase 2. US3 needs T028/T029.
```

- Within every story: test tasks ([P] among themselves) strictly before implementation tasks.
- `[~]` device passes are a **pre-release gate** (002 convention): the automatable portion may
  merge behind them, but the story is not done until the device pass is recorded.
- Suggested MVP: **Phase 1 + Phase 2 + US1** (T001–T033).

## Parallel execution examples

- Phase 2: T004/T005/T007/T009/T010/T011 in parallel (distinct new/independent files); T014→T015
  serialize (codegen); T016 parallel to both; T018/T019 parallel.
- US1 tests: T020–T023 all in parallel (four distinct test files) before any implementation.
- US1 impl: T024/T025/T030/T031 in parallel (distinct files); T026→T027→T032 serialize on the
  controller chain; T028 parallel to the UI chain; T029 after T028.
- Phase 9: T049/T050 in parallel; T051–T053 are sequential device sessions.

## Task counts

| Phase | Tasks | Of which [~] device |
|---|---|---|
| 1 Setup | 3 | 0 |
| 2 Foundational | 16 | 0 |
| US1 (P1) | 14 | 1 |
| US2 (P2) | 3 | 0 |
| US3 (P2) | 3 | 1 |
| US4 (P2) | 3 | 1 |
| US5 (P3) | 3 | 1 |
| US6 (P3) | 3 | 1 |
| 9 Polish/gates | 6 | 3 |
| **Total** | **54** | **8** |
