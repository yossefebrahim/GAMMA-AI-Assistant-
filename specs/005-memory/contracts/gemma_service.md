# Contract — GemmaService memory extensions (005)

Extends the 001/002/003/004 contract. The seam stays the ONLY flutter_gemma importer
(`lib/infrastructure/gemma/flutter_gemma_service.dart`, enforced by `tool/check_plugin_seam.sh`).
This feature adds a facts-block injection path and a cheap chat-recreation method; it introduces **no
new plugin dependency**.

## Interface deltas (`lib/domain/services/gemma_service.dart` — pure Dart)

```dart
// CHANGED — load now takes the composed system instruction (facts block + capture + tool-use),
// replacing the seam's internal ToolRegistry.systemInstruction hardcode.
Future<void> loadModel(
  String filePath, {
  ModelCapabilities capabilities = ModelCapabilities.textOnly,
  List<ToolSpec> tools = const [],
  String? systemInstruction,        // NEW — composed by SystemInstructionComposer (R3); null ⇒ none
});

// NEW — recreate the chat with a (possibly new) systemInstruction WITHOUT reloading the model.
// Called at each session boundary: conversation open (FR-008) and memory toggle (FR-014).
Future<void> startSession({String? systemInstruction});
```

`generate` / `resumeWithToolResult` are UNCHANGED — they take no per-call instruction, so the facts
block is fixed for a conversation's lifetime (FR-008: facts can't change mid-chat).

## Guarantees (numbered — continues the 001–004 contract)

26. **Facts injection is a native system message**: `systemInstruction` reaches Gemma 4 via
    `createConversation(systemMessage:)` on the FFI path (spike §1) — never a user-turn prepend. It is
    re-applied on every `clearHistory(replayHistory:)` session recreation (stable across per-send
    replays).
27. **`startSession` recreates the chat cheaply**: closes the current chat's session FIRST (the FFI
    cached-session caveat, spike §1.2), then `createChat` on the SAME loaded model with the SAME
    tools/capabilities and the given `systemInstruction`. No model reload, no re-mmap. Resets warm
    fingerprints (next send replays). `StateError` if no model is loaded.
28. **Injection is capability-independent; capture is gated**: a non-empty `systemInstruction`
    (facts block) is honored even when `functionCalling == false` (FR-009). The `remember_fact`/
    `forget_fact` tool declarations remain coupled to `functionCalling` via the existing guarantee-18
    `StateError` gate (memory tools are just more entries in the `tools:` list).
29. **Byte-parity preserved (extends guarantee 19)**: when `systemInstruction == null` (memory
    empty/off) AND `functionCalling == false` AND `tools` empty, plugin inputs are byte-identical to
    003 (no system instruction, no tools, `supportsFunctionCalls: false`) and `generate` emits only
    `TextDelta`s. Pinned by the existing parity test, extended for the null-instruction case.
30. **No new state machine**: `remember_fact`/`forget_fact` calls surface as the existing
    `ToolCallRequested` events and run through the 004 controller tool-turn loop + LeakFilter
    unchanged (raw JSON never rendered, guarantee 20).

## Concrete mapping (`flutter_gemma_service.dart`)

| Seam | Plugin (0.15.3, spike-verified) |
|---|---|
| `loadModel(systemInstruction:)` | `createChat(systemInstruction: <composed>, tools: <device+memory mapped>, supportsFunctionCalls: functionCalling, …)` |
| `startSession(systemInstruction:)` | `await _chat.session.close()` → `createChat(... systemInstruction: <new> ...)` on the loaded `_model`; reset `_sessionTurns`, bump epoch |
| facts block | composed by `SystemInstructionComposer` (R3) OUTSIDE the seam; the seam only forwards the string |

The seam no longer references `ToolRegistry.systemInstruction` directly — that literal is one input to
the composer (R3). Composition is pure and unit-tested without the plugin.

## FakeGemmaService extensions (test double)

- Records the `systemInstruction` passed to `loadModel`/`startSession` (so composer→seam wiring and
  the "facts apply next session, not mid-send" rule are assertable plugin-free).
- Models guarantee 27 (`startSession` before load → `StateError`) and the unchanged guarantee-18 gate
  for the memory tools.
- Exposes the parity mode (null instruction + no tools → `TextDelta`-only) for the extended SC-010
  regression test.
