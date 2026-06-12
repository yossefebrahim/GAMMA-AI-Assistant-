<!-- SPECKIT START -->
## Active feature: 005-memory

Read the plan and its design artifacts before working on this feature:

- Plan: `specs/005-memory/plan.md`
- Spec: `specs/005-memory/spec.md`
- Spike (verified runtime behavior): `specs/005-memory/spike-findings.md`
- Research (pinned versions/APIs): `specs/005-memory/research.md`
- Data model: `specs/005-memory/data-model.md`
- Contracts (seams): `specs/005-memory/contracts/`
- Quickstart/validation: `specs/005-memory/quickstart.md`

This feature adds durable user facts (memory): two new tools `remember_fact` + `forget_fact` added
to the existing 004 `ToolRegistry` (now six tools total: four device tools + two memory tools),
auto-captured by the model at conversation time. Facts are persisted in a new `memories` drift table
(schemaVersion 4→5); each fact carries `id`, `fact` (≤ 80 chars), `MemoryCategory`
(`identity`|`work`|`preferences`|`other`), timestamps, `active` flag, and `sourceConversationId`.
A `FactsBlockComposer` assembles the active facts into a compact category-grouped block (ids inline,
≤ 20 facts / ≤ 900 chars, ~8.7 tok/fact) injected as the native `systemInstruction` at chat
creation — a **true native system message** on the FFI/LiteRT-LM path. Facts apply from the **next
session**; refreshing the block requires a chat recreation (close session first — FFI session-cache
caveat). `DriftMemoryRepository.upsert` performs repository-side dedupe/supersede: exact restatements
are no-ops, near-duplicates (Jaccard ≥ 0.5 on normalized content words) supersede the existing row.
`forget_fact(id)` validates the id against active rows and returns a `ToolFailure` for unknown ids
(spike-verified: the model guesses ids — never fuzzy-delete). Integer `id` arriving as `double` is
coerced (004 dispatcher). `memoryEnabled` (default true) gates capture + block injection;
`remember_fact`/`forget_fact` are declared only when `capabilities.functionCalling` is on (same
structural seam-side `StateError` as 004) — but facts injection and manual management are NOT gated
on function calling. **Phase 0 spike GATE PASSED** on the A34 (80.0% capture, 0 false positives,
0 wrong-tool calls, 16/16 valid args). Device runs use `flutter run`/`flutter drive` — NEVER
`flutter test integration_test/...` (it uninstalls the app and wipes the downloaded model + DB);
raise the screen timeout for long drives.

Prior features: `specs/001-model-download-chat/` (model download + streaming chat, foundation);
`specs/002-image-input-vision/` (single-image input; known issue: image grounding fails at the
native layer on 0.15.3 — vision-specific, tools/audio unaffected); `specs/003-audio-input/`
(voice clips — its capability-gating/seam/migration patterns are the template for 004);
`specs/004-function-calling/` (four-tool static registry, `GemmaService` stream seam, tool chips,
drift v3→v4 — the direct foundation for 005).

Stack: Flutter/Dart, Android-first (arm64-v8a, 8 GB baseline). Riverpod 3 (manual Notifier),
drift over app-private SQLite, **flutter_gemma 0.15.3** (LiteRT-LM, Gemma 4 E2B — the
installed/verified version; 0.16.4 is a known model-load regression on the A34, see 003 research
R1; 005's memory findings are 0.15.3-specific) behind a single `GemmaService` seam,
background_downloader for the one-time model download, device_info_plus preflight, image_picker +
permission_handler for image input, record + audioplayers for audio input, gpt_markdown for
assistant-reply rendering, battery_plus + android_intent_plus for local tools. Dark-first
Material 3 per `.specify/memory/design-system.md`. Governed by `.specify/memory/constitution.md`
(v1.2.0): on-device only, offline-first, plugin-seam testability.
<!-- SPECKIT END -->
