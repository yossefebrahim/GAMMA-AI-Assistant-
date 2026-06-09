# Contract: GemmaService — image extensions

**Feature**: `002-image-input-vision` | Principles VII (Plugin Seam), III (Capability-Driven), V
(Graceful Degradation)

Extends the 001 `GemmaService` seam ([001 contract](../../001-model-download-chat/contracts/gemma_service.md))
to carry a single image on the current prompt and on replayed history turns. `FlutterGemmaService`
(in `lib/infrastructure/gemma/`) remains the **only** file permitted to import `flutter_gemma`.
Only the deltas are shown.

## Interface deltas (Dart, pure types — no plugin symbols leak)

```dart
/// Transient image bytes handed across the seam (pure Dart — dart:typed_data).
class ImageInput {
  const ImageInput(this.bytes, {this.mimeType});
  final Uint8List bytes;
  final String? mimeType;
}

/// A prior turn passed back as context (FR-015/FR-016) — now optionally carrying an image.
class ChatTurn {
  const ChatTurn({required this.isUser, required this.text, this.image});
  final bool isUser;
  final String text;
  final ImageInput? image;   // NEW
}

/// Thrown when an image cannot be decoded/processed by the active model/device (FR-020).
class ImageProcessingException implements Exception {
  const ImageProcessingException(this.message, {this.cause});
  final String message;
  final Object? cause;
}

abstract interface class GemmaService {
  // ...unchanged: isLoaded, stop(), close()...

  /// Capabilities of the active model; `image` is sourced from catalog DATA via [loadModel]
  /// (Principle III), not hardcoded. Throws StateError if not loaded.
  ModelCapabilities get capabilities;

  /// Load the model, configuring modality from the active model's declared [capabilities]
  /// (e.g. enable vision when capabilities.image). Releases any prior model first (Principle VIII).
  Future<void> loadModel(String filePath, {ModelCapabilities capabilities});   // CHANGED (added param)

  /// Generate a reply, optionally grounded in [image] for THIS prompt, with prior [history]
  /// (which may itself contain image turns). Streams text deltas (FR-013); completes on end or
  /// [stop] (partial retained by caller, FR-014). Inference off the UI isolate (Principle IV),
  /// no network (Principle I). Throws [ImageProcessingException] if the image can't be processed
  /// (FR-020) and [StateError] if called with an image when capabilities.image is false.
  Stream<String> generate({
    required List<ChatTurn> history,
    required String prompt,
    ImageInput? image,            // NEW
  });
}
```

## Semantics & guarantees (additions)

| # | Behavior | Source |
|---|----------|--------|
| 8 | `loadModel` enables vision modality iff `capabilities.image`; the chat is created with `supportImage: capabilities.image, maxNumImages: 1`. | FR-005/FR-006, III, R1 |
| 9 | `generate(image: …)` includes the image with the current prompt (`Message.withImage`/`imageOnly`). | FR-012/FR-013 |
| 10 | History turns carrying an image are replayed with the image (so follow-ups keep referring to it). | FR-015/FR-016 |
| 11 | A failed image decode/process/OOM raises `ImageProcessingException` — never a hang or crash. | FR-020, Principle V |
| 12 | Passing an image while `capabilities.image == false` throws `StateError` (caller must gate first). | FR-005 |
| 13 | No method performs network I/O; image bytes never leave the device. | Principles I/II |

## Concrete mapping (FlutterGemmaService → flutter_gemma 0.15.3)

- `loadModel` → after activating the model, `model.createChat(modelType: gemma4, supportImage:
  capabilities.image, maxNumImages: 1, supportsFunctionCalls: false, isThinking: false)`
  (`enableVisionModality` follows `supportImage`). Close the prior model first.
- `capabilities` → return the `ModelCapabilities` passed to `loadModel` (catalog data), not a fixed
  `textOnly`.
- `generate` → rebuild history via `clearHistory(replayHistory: [...])` mapping each `ChatTurn` to
  `Message.text(...)` or `Message.withImage(text:, imageBytes:, isUser:)`; then
  `addQueryChunk(image == null ? Message.text(text: prompt, isUser: true)
  : Message.withImage(text: prompt, imageBytes: image.bytes, isUser: true))`; stream
  `TextResponse.token`. Wrap in try/catch → `ImageProcessingException` on image/decoder/OOM errors.
- `stop`/`close` → unchanged (`stopGeneration()`; `chat.close()` + `model.close()`).

> Verify on 0.15.3: that `replayHistory` accepts image-bearing `Message`s and re-ingests them per
> turn. If unreliable/slow, keep the chat session warm (skip `clearHistory` each turn) — a change
> confined to this seam (R1 risk).

## Test double — `FakeGemmaService` (extended)

- `loadModel`: records `capabilities`; `capabilities` getter returns them (default now configurable
  to `image: true`).
- `generate`: records the `image` passed and the images present on `history` turns (so tests assert
  FR-015/FR-016 context replay); emits scripted deltas; honors `stop` (partial retention, FR-014);
  configurable to throw `ImageProcessingException` (FR-020 path).
- Injected via Riverpod `ProviderContainer` override — unit-tests the chat controller, attachment
  controller, and context assembler with **no native plugin**.
