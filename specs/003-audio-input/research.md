# Research — 003 Audio Input (Phase 0 of /speckit-plan)

**Date**: 2026-06-10 | **Branch**: `003-audio-input`

All decisions below are grounded in the verified Phase 0 spike ([spike-findings.md](spike-findings.md)) —
the empirical source of truth for the runtime's audio behavior on the reference device — plus the
002 lessons (audit + diagnosis docs) and pub.dev as of this date.

## R1 — flutter_gemma 0.15.3 audio API (the seam's plugin mapping)

**Decision**: stay on `flutter_gemma ^0.15.0` (installed 0.15.3) and use its native audio API:

- model activation: `FlutterGemma.getActiveModel(..., supportAudio: true)` — threaded through the
  existing GPU-first/CPU-fallback `_activate` path, on **both** attempts;
- chat creation: `_model.createChat(..., supportAudio: true)` (maps to `enableAudioModality`);
- send: `Message.withAudio(text:, audioBytes:, isUser:)` / `Message.audioOnly(audioBytes:, ...)`,
  exactly parallel to `Message.withImage`/`imageOnly`;
- streaming/stop/close: unchanged (`generateChatResponseAsync()`, `stopGeneration()`).

**Verified facts the design depends on** (spike sections 1 and 3):

- There is **no ModelType audio gate** — `ModelType.gemma4` passes; the FFI session has an explicit
  gemma4 branch forwarding `audioBytes`. The "Gemma 3n only" texts are stale doc comments.
- On Android, `.litertlm` audio rides the **Dart FFI path** (no Kotlin/Pigeon involvement); the
  audio encoder executor is **hardcoded to CPU** by the plugin (`'cpu'` at engine create); the LM
  backend (GPU) is unaffected — GPU activation succeeded first-try with `supportAudio: true`.
- **Silent-drop hazard**: if `supportAudio` was false at load, the FFI path silently drops the
  audio from the message instead of throwing. The seam MUST therefore gate with its own
  `StateError` when audio is passed while `capabilities.audio` is false (contract guarantee,
  mirrored from 002's image rule #12 — and this time modeled in `FakeGemmaService`, closing 002
  audit L6).
- Audio encode happens at **generation start**, not at `addQueryChunk` (spike: addQueryChunk 1 ms,
  first token 3.9 s for a 7.3 s clip) — the first-token wait is where the cost lives.
- Grounding verified: word-perfect transcription + correct text-only follow-up from session
  context. The 002 image-grounding gap is vision-path-specific and does not apply to audio.
- 0.16.4 adds **no** audio capability over 0.15.3 (CHANGELOG-verified) and reintroduces the known
  A34 model-load regression — a bump remains the wrong lever.

**Alternatives considered**: upgrade to 0.16.4 (rejected: zero audio delta, known load regression);
fork the plugin to move encode off the main thread (out of scope; the FFI path is not the 002
Pigeon main-thread path, and SC-010 is verified on device in quickstart instead).

## R2 — Recording package: `record` over `flutter_sound`

**Decision**: `record: ^7.0.0` (pub latest 7.0.0; Dart `^3.12.0` / Flutter `>=3.44.0` — satisfied),
confined to `lib/infrastructure/media/` behind a new `AudioRecorderService` domain seam.

**Rationale** (the deciding criterion is the model's input contract — WAV, 16 kHz, mono, 16-bit
PCM — with zero transcoding):

- `record` emits that format **natively at capture time**:
  `RecordConfig(encoder: AudioEncoder.wav, sampleRate: 16000, numChannels: 1)` → a WAV/PCM16 file
  that is byte-for-byte what `Message.withAudio` expects. No post-processing step exists to fail
  (spec FR-023). This is not theoretical: **flutter_gemma's own bundled example records with
  `record` (`^6.0.0`) using exactly this config and sends the WAV unconverted** — a proven
  pairing against this exact consumer.
- `record` exposes `onAmplitudeChanged(interval)` — feeds the design-system pulsing level
  indicator without a second plugin.
- Small, capture-only API surface (start/stop/cancel/pause, amplitude, `hasPermission`); we
  deliberately do **not** use its permission prompt (permission flows through
  `MediaPermissionService` so the explainer states stay testable and consistent with 002).
- `flutter_sound` (9.30.0) also supports `Codec.pcm16WAV`, but brings a much larger surface
  (player + recorder + session management), a heavier initialization model, and an LGPL license
  consideration — more to confine behind the seam for no format advantage. Rejected.
- Version note: the flutter_gemma example proves 6.x; we pin **^7.0.0** (current stable) — same
  `AudioEncoder.wav` config API. The on-device quickstart run is the verification gate; if 7.x
  misbehaves on the A34, dropping to `^6.0.0` is a one-line, seam-confined change.

## R3 — Clip cap and format constants (the app owns them; the plugin enforces nothing)

**Decision**: capture constants live as **data** next to the catalog/capability layer (not in
widgets): WAV/PCM16, 16,000 Hz, 1 channel; **max clip 30 s** (spec Q1); **min clip 500 ms**;
persisted-file guard **2 MB** (a 30 s clip is 16,000 × 2 × 30 ≈ 938 KB + 44-byte header; 2 MB is
double-margin like 002's 10 MB image guard vs the plugin cap).

**Rationale**: token cost ≈ 6.25 tokens/s ⇒ 30 s ≈ 190 tokens — fits the 1536-token sliding-window
context budget alongside history; RAM measured +147 MB for 7.3 s extrapolates safely (audio
encoder activations scale with clip length; 30 s stays far inside the ~1.8 GB headroom measured at
peak); first-token extrapolation ≈ ≤15 s (SC-003 budget). Auto-stop at the cap keeps the clip
(FR-002). Duration is **derived** from PCM byte length (`bytes − 44) / 32 000` s) — no extra DB
column needed.

## R4 — Composer-preview playback: `audioplayers` (Q2 scope only)

**Decision**: `audioplayers: ^6.7.0` (pub latest 6.7.1) behind a minimal `AudioPreviewPlayer`
domain seam (play file / stop / completion+state stream), confined to `lib/infrastructure/media/`.
Used **only** by the composer preview chip; history bubbles render a static chip (duration label,
no playback) per spec Q2.

**Rationale**: one small local WAV, fire-and-forget — `audioplayers`' `DeviceFileSource` covers it
in a few lines. `just_audio` (0.10.5) is excellent but playlist/streaming-oriented — heavier than
the need. Building playback on `flutter_sound` would drag in the rejected R2 alternative.
Resource rule: the player is stopped + released when the chip is removed/replaced/sent, on
conversation switch, and on backgrounding (Principle VIII).

## R5 — Mic permission: extend `MediaPermissionService`, reuse the 002 explainer flow

**Decision**: add `micStatus()` / `requestMic()` to the existing `MediaPermissionService` seam
(same `MediaPermissionStatus` enum and `openSettings()`); concrete impl stays
`PermissionHandlerService` over the already-pinned `permission_handler ^12.0.0`
(`Permission.microphone`). Add `<uses-permission android:name="android.permission.RECORD_AUDIO"/>`
to the app manifest explicitly (002's minimal-explicit-permission posture; `record` declares it in
its own manifest, but the app manifest is the audited surface). Decision tree mirrors the camera
one exactly: granted → record; denied-askable → request → proceed-or-explainer; permanently
denied/restricted → explainer + open-settings; declining never blocks text chat (enforced in the
controller). Request fires on **first mic tap**, never at launch (FR-010).

**Alternatives considered**: `record.hasPermission()` (rejected — it both checks and prompts,
collapsing the states the explainer flow needs and bypassing the testable seam); a separate new
permission seam (rejected — the enum/flow is identical to camera; one seam, two permissions).

## R6 — Persistence: `audioPath`/`audioMimeType` + drift v2→v3, files in `audio/`

**Decision**: mirror 002's R5 exactly — `messages` gains nullable `audioPath` + `audioMimeType`
(TEXT); `schemaVersion` 2 → 3 with an additive `onUpgrade` block (`if (from < 3) addColumn × 2`)
appended after the preserved `if (from < 2)` image block; bytes live as app-private files under
`<documents>/audio/` written by a new `AudioFileStore` (same write-once naming, persist-at-send,
`readBytes` just-in-time, idempotent `deleteAll`); `deleteConversation` deletes audio files
**before** the cascading row delete (paths vanish with the rows).

**Fix-forward items folded in (002 audit)**: the v2→v3 migration test seeds a real v2 DB
**including the `idx_messages_conversation` index** (I7); send-time persistence failures catch
`FileSystemException` as well as `ArgumentError` (DF-2); the file extension derives from the
mimeType via one shared helper used by both store and controller (L5). One attachment per message
(audio XOR image, spec Q3) is enforced at the controller and validated in `appendUserMessage`.

## R7 — Memory guardrails on the 7.3 GiB A34 (directive 6)

**Decision — layered, mostly already-existing levers, now audio-aware**:

1. **Prevention (sizing)**: the 30 s cap (R3) bounds the dominant variable; measured peak with
   audio was ~3.0 GB RSS against ~1.8 GB still available — the cap keeps worst case well inside
   that envelope. One attachment per message (Q3) prevents image+audio peak stacking.
2. **Load-time fallback**: `supportAudio: true` joins the existing GPU→CPU `_activate` fallback —
   if GPU init fails with audio enabled, CPU is attempted with audio still on. `_lastActivationError`
   keeps the real cause so a failure surfaces as a diagnosable `ModelLoadException` — **never** a
   silent capability flip (the 002 "image removed" masquerade; FR-009's loaded-vs-loading guard is
   the UI half of the same rule).
3. **Generation-time failure**: any plugin/native error on a turn whose **current prompt carries
   audio** maps to the typed `AudioProcessingException` → chat controller finalizes the turn as
   `stoppedPartial`, shows the dismissible banner ("couldn't process this audio — try a shorter
   clip, or send without it"). Errors on audio-free turns are NOT remapped (002 audit L4 applied
   from day one). No retry loops; the user decides.
4. **Degradation telemetry-free check**: quickstart includes a `--release` memory profile of an
   audio turn (adb `dumpsys meminfo` checkpoints) so regression against the spike numbers is
   caught before release.

## R8 — Test & verification strategy (directive 7)

**Decision**:

- **Unit/widget (no plugin, no device — Principle VII)**: capability gating (mic visible iff
  `capabilities.audio`, flip live, pending-clip clear only when genuinely loaded — the
  modelSessionReady guard), recording controller state machine (idle→recording→preview→cleared,
  cap auto-stop, min-length discard, interruption keep), `AudioFileStore` (persist/cap/read/
  deleteAll, temp-dir injected), migration v2→v3 (real v2 seed **with index**, old rows survive,
  new columns null), repository audio round-trip + delete-cleans-files, seam mapping
  (FakeGemmaService records `lastAudio`/`lastHistoryAudio`, scripts `AudioProcessingException`,
  **models the ungated StateError** — L6), ContextAssembler audio injection. Widget tests drive
  sends via UI + `pump` (never bare `await`/`runAsync` over fake streams — the 10-minute-hang
  failure mode) and override the permission provider for mic flows.
- **On-device manual script (quickstart.md)**: run with **`flutter drive
  --driver=test_driver/integration_test.dart`** or plain `flutter run` — **NEVER `flutter test
  integration_test/...`, which uninstalls the app and wipes the 2.4 GB model + DB** (spike
  incident log). Covers: real mic capture → send → grounded streamed reply; follow-up; permission
  deny/permanently-deny; airplane mode with network monitor; `--release` first-token timing
  (SC-003/SC-004) and 100 ms gesture check (SC-010); memory profile (R7.4); Accessibility Scanner
  pass (48dp/AA/announcements, SC-011); upgrade-over-install from the 002 build (FR-019).
- The spike's throwaway artifacts (`integration_test/spike_audio_grounding_test.dart`, the
  `integration_test` dev-dependency) are **removed** when 003 implementation lands; the
  `test_driver/integration_test.dart` driver file stays (it is the sanctioned device-run vehicle).

## Pinned versions (this feature's additions)

| Package | Version | Role | Confinement |
|---|---|---|---|
| `record` | `^7.0.0` | WAV/16k/mono/PCM16 capture + amplitude stream | `lib/infrastructure/media/` behind `AudioRecorderService` |
| `audioplayers` | `^6.7.0` | composer-preview playback only (Q2) | `lib/infrastructure/media/` behind `AudioPreviewPlayer` |
| `permission_handler` | `^12.0.0` (already pinned) | `Permission.microphone` | existing `lib/infrastructure/media/` |
| `flutter_gemma` | `^0.15.0` (already pinned, 0.15.3 installed) | audio inference | existing `lib/infrastructure/gemma/` |

`tool/check_plugin_seam.sh` gains a rule confining `record`/`audioplayers` to
`lib/infrastructure/media/` (mirrors the 002 extension).
