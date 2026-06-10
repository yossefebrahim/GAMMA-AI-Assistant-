<!-- SPECKIT START -->
## Active feature: 003-audio-input

Read the plan and its design artifacts before working on this feature:

- Plan: `specs/003-audio-input/plan.md`
- Spec: `specs/003-audio-input/spec.md`
- Spike (verified runtime behavior): `specs/003-audio-input/spike-findings.md`
- Research (pinned versions/APIs): `specs/003-audio-input/research.md`
- Data model: `specs/003-audio-input/data-model.md`
- Contracts (seams): `specs/003-audio-input/contracts/`
- Quickstart/validation: `specs/003-audio-input/quickstart.md`

This feature adds single-clip voice input (the second multimodal capability): a capability-gated
mic in the composer (tap to record — red pulsing state, 30 s cap — tap to stop), a removable
preview chip with playback, streamed audio-grounded replies with multi-turn context, and
persistence via `messages.audioPath`/`audioMimeType` (drift schemaVersion 2→3) + app-private
files. New seams: `AudioRecorderService` (record ^7.0.0 — emits the model's WAV 16 kHz mono PCM16
contract natively) + `AudioPreviewPlayer` (audioplayers ^6.7.0, composer preview only), confined
to `lib/infrastructure/media/`; `MediaPermissionService` gains mic methods; `GemmaService.generate`
gains `AudioInput? audio` with a seam-side StateError gate (the plugin FFI path silently drops
ungated audio). One attachment per message: audio XOR image. **Phase 0 spike verified** audio
grounding works end-to-end on the A34 (word-perfect transcription, GPU backend, ~3.0 GB peak).
Device runs use `flutter run`/`flutter drive` — NEVER `flutter test integration_test/...` (it
uninstalls the app and wipes the downloaded model + DB).

Prior features: `specs/001-model-download-chat/` (model download + streaming chat, foundation);
`specs/002-image-input-vision/` (single-image input — its patterns are the template for 003;
known issue: image grounding fails at the native layer on 0.15.3, audio is unaffected).

Stack: Flutter/Dart, Android-first (arm64-v8a, 8 GB baseline). Riverpod 3 (manual Notifier),
drift over app-private SQLite, **flutter_gemma 0.15.3** (LiteRT-LM, Gemma 4 E2B — the
installed/verified version; 0.16.4 is a known model-load regression on the A34 and adds no audio
capability, see 003 research R1) behind a single `GemmaService` seam, background_downloader for
the one-time model download, device_info_plus preflight, image_picker + permission_handler for
image input, record + audioplayers for audio input. Dark-first Material 3 per
`.specify/memory/design-system.md`. Governed by `.specify/memory/constitution.md` (v1.2.0):
on-device only, offline-first, plugin-seam testability.
<!-- SPECKIT END -->
