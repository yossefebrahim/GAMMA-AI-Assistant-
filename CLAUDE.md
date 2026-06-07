<!-- SPECKIT START -->
## Active feature: 001-model-download-chat

Read the plan and its design artifacts before working on this feature:

- Plan: `specs/001-model-download-chat/plan.md`
- Spec: `specs/001-model-download-chat/spec.md`
- Research (pinned versions/APIs): `specs/001-model-download-chat/research.md`
- Data model: `specs/001-model-download-chat/data-model.md`
- Contracts (seams): `specs/001-model-download-chat/contracts/`
- Quickstart/validation: `specs/001-model-download-chat/quickstart.md`

Stack: Flutter/Dart, Android-first (arm64-v8a, 8 GB baseline). Riverpod 3 (manual Notifier),
drift over app-private SQLite, flutter_gemma 0.16.4 (LiteRT-LM, Gemma 4 E2B) behind a single
`GemmaService` seam, background_downloader for the one-time model download, device_info_plus
preflight. Dark-first Material 3 per `.specify/memory/design-system.md`. Governed by
`.specify/memory/constitution.md` (v1.2.0): on-device only, offline-first, plugin-seam testability.
<!-- SPECKIT END -->
