# Implementation Plan: Audio Input — Voice Understanding

**Branch**: `003-audio-input` | **Date**: 2026-06-10 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `/specs/003-audio-input/spec.md` — preceded by the
**verified Phase 0 spike** ([spike-findings.md](spike-findings.md)): Gemma 4 E2B grounds audio
word-perfectly through flutter_gemma 0.15.3 on the A34 (GPU backend, ~3.0 GB peak RSS, ~4 s first
token for a 7 s clip). The riskiest claim was retired empirically before this plan was written.

## Summary

Add the assistant's second multimodal capability: a capability-gated mic in the composer records
**one** voice clip (tap to record — red-accent pulsing state with elapsed time — tap to stop,
30 s cap), previews it as a removable chip with playback, and sends it alone or with text; the
assistant streams a reply about the audio and follow-ups keep referring to it. Clips persist with
the conversation (files + path columns, drift v2→v3), mic permission flows mirror 002's camera
explainers, and everything works fully offline with audio never leaving the device.

Technical approach — extend the existing 001/002 architecture rather than reshape it:

- **Seam (Principle VII).** `GemmaService.generate` gains `AudioInput? audio`; `ChatTurn` gains
  optional audio for context replay. `FlutterGemmaService` threads `capabilities.audio` into
  `getActiveModel(supportAudio:)` (both GPU and CPU attempts) and `createChat(supportAudio:)`,
  maps the prompt/history to `Message.withAudio`/`audioOnly`, and adds a **seam-side StateError
  gate** because the plugin's FFI path silently drops ungated audio (research R1). Failures on
  audio-bearing prompts map to a typed `AudioProcessingException` — narrowly scoped per 002 audit
  L4. Kept-warm fingerprints gain `audioByteLength`.
- **Capabilities as data (Principle III).** `ModelCatalog` declares `supportsAudio: true`
  (spike-confirmed for E2B) feeding the existing `ModelCapabilities.audio` flag; the composer's
  capability-gated mic stub (already rendered on `capabilities.audio`) is wired to the real flow.
  The 002 loading-vs-text-only conflation rule is honored: pending-clip clearing fires only for a
  genuinely loaded audio-incapable model (modelSessionReady guard).
- **Capture behind new seams.** `AudioRecorderService` (over `record ^7.0.0` — emits the model's
  exact WAV 16 kHz mono PCM16 contract natively, zero transcoding; amplitude stream drives the
  pulsing indicator) and `AudioPreviewPlayer` (over `audioplayers ^6.7.0`, composer-preview
  playback only per spec Q2), both confined to `lib/infrastructure/media/` with fakes.
  `MediaPermissionService` gains `micStatus()`/`requestMic()` on the existing enum/explainer flow;
  manifest adds exactly `RECORD_AUDIO`.
- **Persistence.** Audio bytes as app-private files under `audio/` via `AudioFileStore` (persist
  at send, 2 MiB guard, just-in-time reads, idempotent deleteAll); `messages` gains nullable
  `audioPath`/`audioMimeType` via **drift schemaVersion 2 → 3**; conversation delete removes audio
  files before the cascade. 002 audit fixes folded in (I7 index-faithful migration seed, DF-2
  FileSystemException, L5 shared extension helper).
- **UI.** Recording state uses the design system's sanctioned red (live recording + stop) with the
  dot-matrix pulse and a mono elapsed readout; the chip, notes, and errors stay monochrome with
  hairline borders. One attachment per message (audio XOR image, spec Q3) is enforced in the
  attachment/recording controller. Streaming, stop/cancel (M1 delta-before-stop invariant),
  sliding-window memory, throttled writes, and lifecycle release all reuse the existing plumbing.

Decisions and pinned versions in [research.md](research.md) (R1–R8); entities, migration, and the
recording state machine in [data-model.md](data-model.md); seam contracts and fakes in
[contracts/](contracts/); the on-device validation script in [quickstart.md](quickstart.md).

## Technical Context

**Language/Version**: Dart 3.12.x on Flutter stable — matches 001/002 (record 7 requires Dart
^3.12 / Flutter ≥3.44: satisfied).

**Primary Dependencies** (added by this feature, on top of the 001/002 stack):
- `record ^7.0.0` — WAV/16 kHz/mono/PCM16 capture + amplitude stream, behind `AudioRecorderService`
  (research R2; flutter_gemma's own example proves the pairing).
- `audioplayers ^6.7.0` — composer-preview playback only (spec Q2), behind `AudioPreviewPlayer`
  (research R4).
- `permission_handler ^12.0.0` (already pinned) — gains `Permission.microphone` usage (R5).
- `flutter_gemma ^0.15.0` (already pinned, 0.15.3 installed) — audio API now exercised:
  `getActiveModel(supportAudio:)`, `createChat(supportAudio:)`, `Message.withAudio`/`audioOnly`.
  Confinement unchanged. **No version bump** (R1: 0.16.4 adds zero audio capability and regresses
  model load on the A34).

**Storage**: unchanged backbone — drift over app-private SQLite. Schema bumps to **v3**:
`messages.audioPath TEXT?`, `messages.audioMimeType TEXT?`. Audio **bytes** live as app-private
files under `…/audio/` (never BLOBs); recorder temp files are copied in at send only.

**Testing**: `flutter_test` unit + widget against fakes (`FakeAudioRecorderService`,
`FakeAudioPreviewPlayer`, extended `FakeMediaPermissionService`/`FakeGemmaService` — the latter now
models the ungated-audio StateError, closing 002 L6); in-memory drift for repositories; a real
seeded v2 file DB (with `idx_messages_conversation` — 002 I7) for the v2→v3 migration test. No
device, plugin, or network in tests (Principle VII). Device verification via
[quickstart.md](quickstart.md) — **`flutter run`/`flutter drive` only; `flutter test
integration_test/...` is forbidden on this project** (it uninstalls the app and wiped the model +
DB during the spike — incident log).

**Target Platform**: Android, arm64-v8a, API 29+ baseline (unchanged). New manifest entry:
`RECORD_AUDIO` only. Foreground-only recording (no background capture — out of scope by spec).

**Performance Goals**: recording state visible ≤500 ms after mic tap, elapsed updates ≥1/s
(SC-004); first reply words ≤15 s for a max-length (30 s) clip on the A34 in `--release` (SC-003;
spike measured 3.9 s first token at 7 s — budget holds ~2× margin at 30 s); 100 ms gesture
response while recording and streaming (SC-010); streaming token-by-token unchanged (FR-014).

**Constraints**: on-device only — audio bytes, derived data, and analysis never leave the device;
no new network call (Principle I; `check_network_seam.sh` stays green); fully offline after
install (II); audio modality flags threaded at load — the FFI silent-drop hazard is closed at the
seam (R1); audio encoder runs CPU-side at generation start by plugin design (R1) — the first-token
budget absorbs it; exactly one model active with explicit release, recorder/player resources
released on stop/navigation/backgrounding, bytes never retained between turns (VIII); 30 s clip
cap / 500 ms minimum / 2 MiB persist guard as data constants (R3); single attachment per message —
audio XOR image (spec Q3); dark-first M3 monochrome identity with red reserved for the live
recording/stop states (VI, X).

**Scale/Scope**: single local user; one clip per audio-bearing message; two new infrastructure
seams + one seam extension, one schema column-add migration, one file store, the recording
controller/state machine, composer recording UI + chip, and bubble chip rendering. No new layers.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

Constitution version **1.2.0**. Status legend: ✅ satisfied by design · ⚠ implementation caution
(carried into research/tasks, not a deviation).

| # | Principle | Gate — how this plan satisfies it | Status |
|---|-----------|-----------------------------------|--------|
| I | Privacy Is the Product | No new network call; capture, preview playback, inference, and storage are all on-device. Constitution names audio content explicitly — it never leaves the device. The only egress remains the model download (untouched); `check_network_seam.sh` still covers the codebase. | ✅ |
| II | Offline-First | Record, preview, send, audio-grounded generation, history, and persistence all work with zero connectivity (quickstart V8 verifies under airplane mode + monitor). | ✅ |
| III | Capability-Driven UX | Mic affordance rendered from `ModelCapabilities.audio` (catalog→seam→provider data), never a per-model `if`; flips live on model switch; pending clip cleared only for a genuinely loaded audio-incapable model (the 002 conflation lesson is a contract rule this time). | ✅ (realizes III for audio) |
| IV | Responsive & Cancellable | Streaming + stop/cancel reuse the existing path (M1 invariant retained); recording runs natively off-isolate with a lightweight amplitude stream; audio encode cost lands in first-token wait (budgeted, SC-003) — not a UI block; no per-token work added. | ⚠ verify SC-010 (100 ms gestures) on device during an audio turn — quickstart V9 |
| V | Graceful Degradation | Recorder-unavailable, interruption (call/backgrounding), too-short/too-long, store-full, unprocessable-clip, and OOM-ish paths all have typed failures and clear messages (FR-021/FR-022, R7); load failures stay diagnosable (`_lastActivationError`) instead of masquerading as capability flips. | ⚠ map the full failure matrix in implementation; R7 guardrails are the checklist |
| VI | Dark-First & Accessible | New controls ≥48dp + AA; recording start/stop announced to screen readers (spec FR-028); notes use `textSecondary`, never `textMuted`. | ⚠ device Accessibility Scanner + TalkBack pass — quickstart V10 |
| VII | Testable Through a Plugin Seam | flutter_gemma stays in `infrastructure/gemma/`; `record`/`audioplayers`/`permission_handler` confined to `infrastructure/media/` behind `AudioRecorderService`/`AudioPreviewPlayer`/`MediaPermissionService` with fakes; seam-guard script extended; controllers/widgets test plugin-free. | ✅ |
| VIII | Resource Hygiene | Recorder/player released on stop/remove/switch/backgrounding; pending state holds a path, never bytes; bytes read just-in-time and not retained; audio files deleted with their conversation; single active model unchanged. | ✅ (release paths are contract guarantees) |
| IX | Lean Scope | Exactly the spec slice: one clip, capture-only, composer-preview playback only, no TTS/transcription/wake-word/import/editing/history-playback — all explicit non-goals (spec Q2/Q3 keep it minimal). | ✅ |
| X | Design Identity | The red accent is used precisely where the design system **reserves** it — the live recording indicator and stop control; everything else (chip, remove, notes) monochrome with hairline borders; dot-matrix pulse, mono elapsed readout, lowercase microcopy; tokens centralized. | ✅ |
| — | Technology & Platform Constraints | Stack unchanged (Flutter/Dart, Riverpod, drift/SQLite, flutter_gemma 0.15.3 .litertlm, arm64-v8a/8 GB). The constitution's own model table already declares Gemma 4 E2B audio-capable — the spike converted that claim from assumption to verified fact. New plugins are additive UI-layer capture tools, not a stack deviation. | ✅ |

**Gate result**: PASS. No principle is violated; three ⚠ items are device-verification cautions
carried into quickstart/tasks. **Complexity Tracking is therefore empty.**

## Project Structure

### Documentation (this feature)

```text
specs/003-audio-input/
├── spike-findings.md    # Phase 0 verification spike (pre-plan, decision gate: PASS)
├── plan.md              # This file (/speckit-plan output)
├── research.md          # Phase 0 output — R1..R8 decisions (plugin API, record vs flutter_sound, caps, guardrails)
├── data-model.md        # Phase 1 output — entities, v2→v3 migration, recording state machine
├── quickstart.md        # Phase 1 output — V0..V10 validation script (flutter drive/run ONLY)
├── contracts/           # Phase 1 output — new/extended seam contracts
│   ├── gemma_service.md          # audio extensions + silent-drop gate + FakeGemmaService deltas
│   ├── audio_recorder.md         # AudioRecorderService (record ^7.0.0)
│   ├── audio_preview_player.md   # AudioPreviewPlayer (audioplayers ^6.7.0, Q2 scope)
│   ├── media_permission.md       # mic methods on the 002 permission seam
│   └── conversation_repository.md# audio persistence + delete-cleans-files
├── checklists/
│   └── requirements.md  # spec quality checklist (from /speckit-specify)
└── tasks.md             # Phase 2 output (/speckit-tasks — NOT created here)
```

### Source Code (repository root) — changes layered on the existing tree

```text
lib/
├── core/
│   ├── model_catalog.dart             # + supportsAudio = true (data) → ModelCapabilities(audio:)
│   └── audio_constants.dart           # NEW — 16kHz/mono/PCM16, 30s cap, 500ms min, 2MiB guard
├── domain/
│   ├── entities/
│   │   ├── audio_input.dart           # NEW — transient bytes for the seam (mirrors ImageInput)
│   │   ├── audio_attachment.dart      # NEW — persisted path+mime (mirrors ImageAttachment)
│   │   ├── pending_recording.dart     # NEW — composer-transient (path, mime, durationMs)
│   │   ├── chat_turn.dart             # + AudioInput? audio (XOR image)
│   │   └── message.dart               # + AudioAttachment? audio (XOR image)
│   └── services/
│       ├── gemma_service.dart         # generate(... AudioInput? audio); AudioProcessingException
│       ├── audio_recorder_service.dart# NEW — start/stop/cancel/amplitude (policy-free)
│       ├── audio_preview_player.dart  # NEW — play/stop/state (composer preview only)
│       └── media_permission_service.dart # + micStatus()/requestMic()
├── data/
│   ├── db/
│   │   ├── tables.dart                # Messages + audioPath, audioMimeType (nullable)
│   │   └── app_database.dart          # schemaVersion 3 + onUpgrade(from<3 → addColumn ×2)
│   ├── audio/
│   │   └── audio_file_store.dart      # NEW — persist@send / readBytes / deleteAll (2MiB guard)
│   └── repositories/
│       └── drift_conversation_repository.dart # audio columns round-trip; delete cleans audio files
├── infrastructure/
│   ├── gemma/flutter_gemma_service.dart    # supportAudio threading; withAudio mapping; StateError gate;
│   │                                       #   AudioProcessingException (current-prompt-only); fingerprint+audio
│   └── media/
│       ├── record_audio_recorder_service.dart  # NEW — record ^7.0.0 impl (WAV/16k/mono config)
│       ├── audioplayers_preview_player.dart    # NEW — audioplayers ^6.7.0 impl
│       └── permission_handler_service.dart     # + Permission.microphone mapping
└── features/chat/
    ├── recording_controller.dart      # NEW — state machine: idle/recording/previewing, cap timer,
    │                                  #   min-length, interruption handling, permission routing
    ├── attachment_controller.dart     # one-attachment rule (audio XOR image), capability-flip clear
    ├── chat_controller.dart           # send(text, image?|audio?): persist via AudioFileStore, AudioInput to generate
    ├── context_assembler.dart         # audio injection map (id-keyed, pure)
    ├── chat_providers.dart            # recorder/player/permission providers
    └── widgets/
        ├── composer.dart              # wire the existing capability-gated mic stub → record flow
        ├── recording_indicator.dart   # NEW — red dot-matrix pulse + mono elapsed readout
        ├── audio_chip.dart            # NEW — preview chip (play/duration/remove) + static history chip
        └── message_bubble.dart        # render the audio chip in place in user turns

android/app/src/main/AndroidManifest.xml  # + RECORD_AUDIO
tool/check_plugin_seam.sh                 # + record/audioplayers → lib/infrastructure/media/ rule

test/
├── unit/        # recording_controller (cap/min/interrupt/permission), attachment XOR rule,
│                #   chat_controller audio send + error paths, context_assembler audio turns,
│                #   audio_file_store, catalog capability data, seam audio mapping via fakes
├── widget/      # composer mic gating flip (loaded-vs-loading), record→chip→send via UI+pump,
│                #   permission explainers (provider overridden), bubble renders audio chip
├── data/        # drift v2→v3 migration (real v2 seed WITH index), repository audio round-trip + cleanup
└── helpers/     # FakeAudioRecorderService, FakeAudioPreviewPlayer, extended FakeMediaPermissionService,
                 #   extended FakeGemmaService (lastAudio, StateError modeled, scripted AudioProcessingException)
```

**Structure Decision**: keep the 001/002 layered architecture (`domain` → `data`/`infrastructure`
→ `features`) and extend it. Two new infrastructure seams + one extension keep all platform
plugins out of domain/presentation; the plugin-seam guard grows two package rules but its shape is
unchanged. The recording state machine gets its own controller (it has genuinely new states —
recording/preview/interruption) while attachment exclusivity stays in the existing
`AttachmentController` — no new layer or pattern is introduced.

## Complexity Tracking

No constitution violations — this section is intentionally empty. The design adds the minimum the
spec requires (audio-bearing seam, capture + preview-playback seams, one column-add migration, a
file store, one new controller, and the composer/chip UI) and reuses the existing streaming,
memory, persistence, capability, permission-explainer, and resource-management machinery.

## Post-Design Constitution Re-Check

After Phase 1 (research + data model + contracts), the gate is re-evaluated. **Result: PASS.** The
three ⚠ items now have concrete designs and device-verification steps; no new violation appeared.

- **IV — Responsive & Cancellable (⚠ → ✅ pending device check)**: capture and playback are
  native/off-isolate; the audio encode cost is bounded by the 30 s cap and lands in the budgeted
  first-token wait (SC-003, 2× margin over the spike measurement); stop/cancel and the M1
  delta-before-stop rule are contract guarantees. SC-010's 100 ms gesture check is quickstart V9.
- **V — Graceful Degradation (⚠ → ✅)**: the full failure matrix has owners — recorder failures
  (`RecorderUnavailableException` → composer message), interruptions (stop-and-keep ≥min rule),
  store failures (ArgumentError + FileSystemException → "record again"), inference failures
  (`AudioProcessingException`, current-prompt-only → stoppedPartial + banner), load failures
  (diagnosable `ModelLoadException`, never a capability masquerade) — research R7, contracts.
- **VI — Dark-First & Accessible (⚠ → ✅ pending device check)**: all new controls specced ≥48dp
  AA with screen-reader announcements (FR-028); quickstart V10 is the release gate.

**New-artifact compliance:**

| Principle | Honored by design artifacts |
|-----------|-----------------------------|
| I Privacy | no service performs network I/O; local-file-only player ([contracts/](contracts/)) |
| III Capability-Driven | `ModelCapabilities.audio` flows catalog→seam→provider; loaded-vs-loading guard is contractual — [gemma_service.md](contracts/gemma_service.md) |
| V Graceful Degradation | typed exceptions + permission states + R7 guardrails — [audio_recorder.md](contracts/audio_recorder.md), [media_permission.md](contracts/media_permission.md) |
| VII Plugin Seam | two new confined impls + extended guard script; every seam has a fake — [contracts/](contracts/) |
| VIII Resource Hygiene | path-not-bytes pending state, just-in-time reads, release paths as guarantees, delete-cleans-files — [data-model.md](data-model.md), [conversation_repository.md](contracts/conversation_repository.md) |
| X Design Identity | red precisely on the live recording/stop states; dot-matrix pulse; monochrome chip — spec FR-029, composer/chip design |

Gate clear → ready for `/speckit-tasks`. Complexity Tracking remains empty.
