# Contract — GemmaService function-calling extensions (004)

Extends the 001/002/003 contract. The seam stays the ONLY flutter_gemma importer
(`lib/infrastructure/gemma/flutter_gemma_service.dart`, enforced by `tool/check_plugin_seam.sh`).

## Interface deltas (`lib/domain/services/gemma_service.dart` — pure Dart, no plugin symbols)

```dart
// BREAKING (internal): generate now yields events, not bare tokens.
Stream<GenerationEvent> generate({
  required List<ChatTurn> history,
  required String prompt,
  ImageInput? image,
  AudioInput? audio,
});

// NEW — completes the one-allowed tool round trip of the current turn.
Stream<GenerationEvent> resumeWithToolResult({
  required String toolName,
  required Map<String, Object?> result,   // success payload OR {error: reason}
});

// CHANGED — tool declarations ride model load, coupled to the capability.
Future<void> loadModel(
  String filePath, {
  ModelCapabilities capabilities = ModelCapabilities.textOnly,
  List<ToolSpec> tools = const [],
});
```

`ChatTurn` gains a tool variant (or carries the tool row fields) so history replay can
reconstruct tool turns — see data-model §3.

## Guarantees (numbered — continues the 001/002/003 contract)

18. **Tool gate (the silent-trap closure, spike §1.3)**: `loadModel(tools: nonEmpty)` while
    `capabilities.functionCalling == false` throws `StateError` **synchronously**. There is no
    representable state where the plugin receives tool declarations without
    `supportsFunctionCalls: true` — both derive from one source inside the seam.
19. **Flag-off byte-parity**: with `functionCalling == false`, plugin inputs are byte-identical
    to 003 behavior (`tools: const []`, `supportsFunctionCalls: false`, no tool system
    instruction) and `generate` emits only `TextDelta`s. Pinned by a parity test (SC-007).
20. **Leak suppression (FR-004, structural)**: no raw tool-call JSON ever crosses the seam as
    `TextDelta`. The `LeakFilter` withholds `{`-prefixed accumulating text while tools are
    active; discards it when the turn ends in `ToolCallRequested`; flushes it verbatim when the
    turn ends without a call (prose fidelity). Unit-tested against the spike's captured shapes.
21. **Call event is final and typed**: `ToolCallRequested(name, args, extraCallCount)` is always
    the last event of its stream (plugin yields it at end-of-stream). Parallel calls map to ONE
    event: first call + `extraCallCount` (FR-006/FR-024 handled by the controller).
22. **Resume discipline**: `resumeWithToolResult` is valid exactly once, only after a
    `ToolCallRequested`-terminated stream of the same turn; otherwise `StateError`. It sends the
    plugin `Message.toolResponse(toolName:, response:)` and re-invokes generation on the same
    chat; its stream obeys guarantees 20–21 (a second call event is surfaced, not executed).
23. **Tool context replay**: tool-bearing `ChatTurn`s replay as the plugin pair
    `Message.toolCall(rawSdkJson)` + `Message.toolResponse(...)` (data-model §3) inside
    `clearHistory(replayHistory:)` — the app DB is the source of truth (the plugin's own
    history omits streamed tool calls). Kept-warm session fingerprints incorporate tool turns.
24. **StateError never remapped**: programmer-error gates rethrow unchanged (the 002/003 rule);
    plugin/native failures during a tool turn map to the existing typed failure surface and the
    turn finalizes per the controller's state machine — never a crash, never a vanished turn.
25. **Stop semantics extend to tool turns**: `stop()` during a tool turn ends the turn at the
    next safe point (before dispatch → before resume); the epoch bump forces full replay next
    send, so a stopped tool turn can never leave the native session inconsistent.

## Concrete mapping (`flutter_gemma_service.dart` — the only flutter_gemma importer)

| Seam | Plugin (0.15.3, spike-verified) |
|---|---|
| `loadModel(..., tools:)` with `functionCalling` | `createChat(modelType: gemma4, tools: <mapped Tool list>, supportsFunctionCalls: true, toolChoice: ToolChoice.auto, systemInstruction: <R6 instruction>, ...)` |
| `ToolSpec` | `Tool(name:, description:, parameters: spec.parameters)` |
| event stream | `generateChatResponseAsync()`: `TextResponse` → LeakFilter → `TextDelta`; `FunctionCallResponse` → `ToolCallRequested(name, args)`; `ParallelFunctionCallResponse` → first + `extraCallCount` |
| `resumeWithToolResult` | `chat.addQuery(Message.toolResponse(toolName:, response:))` → `generateChatResponseAsync()` (fresh manual call — no auto-resume in the plugin) |
| replay | tool `ChatTurn` → `Message.toolCall(text: <reconstructed raw SDK JSON>)` + `Message.toolResponse(...)` in `clearHistory(replayHistory:)` |

## FakeGemmaService extensions (test double)

- Scriptable event sequences per send: `[TextDelta…]`, `[ToolCallRequested]`,
  `[TextDelta…, ToolCallRequested]`, and post-resume sequences (including a scripted SECOND
  `ToolCallRequested` for the FR-024 test).
- Models guarantee 18 (`StateError` on ungated tools) and 22 (`StateError` on out-of-turn
  resume) so controller tests exercise the gates plugin-free.
- Records `resumeWithToolResult` payloads for round-trip assertions; exposes the parity mode
  (flag off → tokens only) for the SC-007 test.
