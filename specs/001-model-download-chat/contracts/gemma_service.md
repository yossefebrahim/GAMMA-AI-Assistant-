# Contract: GemmaService (the plugin seam)

**Feature**: `001-model-download-chat` | Principle VII (Testable Through a Plugin Seam)

`GemmaService` is the **single** abstraction over `flutter_gemma`. It is the only seam through
which the rest of the app touches model loading, inference, capabilities, and release. The
concrete `FlutterGemmaService` (in `lib/infrastructure/gemma/`) is the **only** file in the
codebase permitted to import `flutter_gemma`. Domain and presentation depend on this interface and
are unit-tested with `FakeGemmaService`.

## Interface (Dart, pure types — no plugin symbols leak)

```dart
/// Capabilities of the active model, surfaced as DATA (Principle III).
class ModelCapabilities {
  final bool text;            // always true
  final bool image;
  final bool audio;
  final bool functionCalling;
  final bool thinking;
}

abstract interface class GemmaService {
  /// Whether a model is currently loaded and active.
  bool get isLoaded;

  /// Capabilities of the active model; throws StateError if not loaded.
  ModelCapabilities get capabilities;

  /// Load the model at [filePath] (a verified, app-private .litertlm). Releases any
  /// previously-loaded model first so exactly ONE model is active (Principle VIII).
  /// Throws [ModelLoadException] on failure (e.g. backend init / OOM).
  Future<void> loadModel(String filePath);

  /// Generate a reply for [prompt] given prior [history], streaming text deltas.
  /// The returned stream emits incremental text; it completes when generation ends
  /// OR when [stop] is called (partial text already emitted is retained by the caller).
  /// Implementations MUST run inference off the UI isolate (Principle IV).
  Stream<String> generate({
    required List<ChatTurn> history,   // ordered prior turns (sliding-window-trimmed by caller)
    required String prompt,
  });

  /// Halt the in-flight generation immediately (FR-014). Idempotent / safe if idle.
  Future<void> stop();

  /// Release the model and session, freeing memory (FR-029). Idempotent.
  Future<void> close();
}

/// A prior turn passed back as context (FR-017).
class ChatTurn { final bool isUser; final String text; }
```

## Semantics & guarantees

| # | Behavior | Source |
|---|----------|--------|
| 1 | At most one model loaded at a time; `loadModel` releases the prior one. | Principle VIII, R1 |
| 2 | `generate` streams text deltas; a long reply arrives in multiple emissions, never a single block. | FR-013 |
| 3 | `stop()` ends the stream promptly; whatever deltas were emitted are final and kept by the caller. | FR-014, SC-005 |
| 4 | Inference never blocks the UI isolate. | FR-015, Principle IV |
| 5 | `capabilities` is read from the active model, not hardcoded; this slice ignores non-text modalities. | FR-016, Principle III |
| 6 | `close()` frees ~2.4 GB; calling `generate` after `close` throws `StateError`. | FR-029 |
| 7 | No method performs any network I/O. | Principle I/II |

## Concrete mapping (FlutterGemmaService → flutter_gemma 0.16.4)

- `loadModel` → `FlutterGemma.installModel(modelType: gemma4, fileType: litertlm).fromFile(path).install()` then `getActiveModel(...)`; close prior `InferenceModel` first.
- `generate` → `model.createChat()` (or reuse), `addQueryChunk(Message.text(...))`, `generateChatResponseAsync()` mapping `TextResponse.token` → stream; ignore `ThinkingResponse`/`FunctionCallResponse` this slice.
- `stop` → `chat.stopGeneration()` + cancel the Dart `StreamSubscription`.
- `close` → `chat.close()` then `model.close()`.
- `capabilities` → read `supportImage` / `supportAudio` / `supportsFunctionCalls` / `isThinking`.

## Test double — `FakeGemmaService`

- `loadModel`: records the path, sets `isLoaded = true`, configurable to throw `ModelLoadException`.
- `generate`: emits a scripted list of deltas with controllable timing; honors `stop()` by ending
  the stream early (to test partial-retention, FR-014).
- `capabilities`: returns a configurable `ModelCapabilities` (default text-only).
- `close`: sets `isLoaded = false`; asserts no `generate` after close.
- Injected via Riverpod `ProviderContainer` override (R5) — enables unit tests of the chat
  controller, context assembler, and resource-lifecycle logic with **no native plugin**.
