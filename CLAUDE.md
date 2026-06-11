<!-- SPECKIT START -->
## Active feature: 004-function-calling

Read the plan and its design artifacts before working on this feature:

- Plan: `specs/004-function-calling/plan.md`
- Spec: `specs/004-function-calling/spec.md`
- Spike (verified runtime behavior): `specs/004-function-calling/spike-findings.md`
- Research (pinned versions/APIs): `specs/004-function-calling/research.md`
- Data model: `specs/004-function-calling/data-model.md`
- Contracts (seams): `specs/004-function-calling/contracts/`
- Quickstart/validation: `specs/004-function-calling/quickstart.md`

This feature adds natural-language local tools (function calling): a four-tool static registry —
`get_device_info`, `summarize_clipboard` (read-only), `set_theme`, `set_timer` (state-changing) —
auto-executed (spec Q1), every call rendered as a monochrome inline tool chip (design-system §8),
persisted via `messages.toolName/toolArgs/toolStatus/toolResult` + `role='tool'` (drift
schemaVersion 3→4) and replayed into model context (the plugin's own history omits tool turns).
`GemmaService.generate` becomes `Stream<GenerationEvent>` (`TextDelta` | `ToolCallRequested`) +
`resumeWithToolResult` for the ONE allowed round trip per turn; seam-side StateError gates couple
`tools` to `capabilities.functionCalling` structurally (the FFI path injects ungated declarations
and spills raw JSON otherwise). **LeakFilter is mandatory**: raw SDK tool-call JSON leaks into the
text stream on 100% of calls (spike-verified) and must never render. New plugins `battery_plus`
^7.0.0 + `android_intent_plus` ^6.0.0 confined to `lib/infrastructure/tools/`; free storage via a
~10-line StatFs MethodChannel; clipboard via Flutter built-in (foreground-only, 4,000-char bound).
`ToolChoice.auto` + a short tool-use systemInstruction (the reliability lever over the spike's
83.3% no-instruction floor). **Phase 0 spike GATE PASSED** on the A34 (83.3% correct-call, 0
hallucinated tools, 0 spurious calls, GPU, no RAM regression). Device runs use `flutter run`/
`flutter drive` — NEVER `flutter test integration_test/...` (it uninstalls the app and wipes the
downloaded model + DB); raise the screen timeout for long drives (spike run-1 hang).

Prior features: `specs/001-model-download-chat/` (model download + streaming chat, foundation);
`specs/002-image-input-vision/` (single-image input; known issue: image grounding fails at the
native layer on 0.15.3 — vision-specific, tools/audio unaffected); `specs/003-audio-input/`
(voice clips — its capability-gating/seam/migration patterns are the template for 004).

Stack: Flutter/Dart, Android-first (arm64-v8a, 8 GB baseline). Riverpod 3 (manual Notifier),
drift over app-private SQLite, **flutter_gemma 0.15.3** (LiteRT-LM, Gemma 4 E2B — the
installed/verified version; 0.16.4 is a known model-load regression on the A34, see 003 research
R1; 004's function-calling findings are 0.15.3-specific) behind a single `GemmaService` seam,
background_downloader for the one-time model download, device_info_plus preflight, image_picker +
permission_handler for image input, record + audioplayers for audio input, gpt_markdown for
assistant-reply rendering, battery_plus + android_intent_plus for local tools. Dark-first
Material 3 per `.specify/memory/design-system.md`. Governed by `.specify/memory/constitution.md`
(v1.2.0): on-device only, offline-first, plugin-seam testability.
<!-- SPECKIT END -->
