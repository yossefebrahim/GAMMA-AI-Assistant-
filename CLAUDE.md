<!-- SPECKIT START -->
## Active feature: 002-image-input-vision

Read the plan and its design artifacts before working on this feature:

- Plan: `specs/002-image-input-vision/plan.md`
- Spec: `specs/002-image-input-vision/spec.md`
- Research (pinned versions/APIs): `specs/002-image-input-vision/research.md`
- Data model: `specs/002-image-input-vision/data-model.md`
- Contracts (seams): `specs/002-image-input-vision/contracts/`
- Quickstart/validation: `specs/002-image-input-vision/quickstart.md`

This feature adds single-image visual understanding (the first multimodal capability): attach one
image (camera or photo library) behind the capability-gated composer control, stream a reply about
it, keep referring to it on follow-ups, and persist it with the conversation. New seams:
`MediaPickerService` + `MediaPermissionService` (image_picker / permission_handler, confined to
`lib/infrastructure/media/`); the `GemmaService` seam gains an optional image; `messages` gains
`imagePath`/`imageMimeType` via a drift schemaVersion 1→2 migration.

Prior feature (foundation): `specs/001-model-download-chat/` (model download + streaming chat).

Stack: Flutter/Dart, Android-first (arm64-v8a, 8 GB baseline). Riverpod 3 (manual Notifier),
drift over app-private SQLite, **flutter_gemma 0.15.3** (LiteRT-LM, Gemma 4 E2B — the
installed/verified version; the 001 docs' "0.16.4" is superseded, see 002 research R1) behind a
single `GemmaService` seam, background_downloader for the one-time model download, device_info_plus
preflight, image_picker + permission_handler for image input. Dark-first Material 3 per
`.specify/memory/design-system.md`. Governed by `.specify/memory/constitution.md` (v1.2.0):
on-device only, offline-first, plugin-seam testability.
<!-- SPECKIT END -->
