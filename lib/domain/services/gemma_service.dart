import 'package:ai_assistant/domain/entities/chat_turn.dart';
import 'package:ai_assistant/domain/entities/image_input.dart';
import 'package:ai_assistant/domain/entities/model_capabilities.dart';

/// Thrown when a model fails to load (e.g. backend init / OOM).
class ModelLoadException implements Exception {
  const ModelLoadException(this.message, {this.cause});
  final String message;
  final Object? cause;

  @override
  String toString() => 'ModelLoadException: $message';
}

/// Thrown when an image cannot be decoded/processed by the active model/device (FR-020). The
/// concrete seam maps the plugin's decode/validation/OOM failures to this type so the chat
/// controller can finalize the turn cleanly and surface a clear message — never a hang or crash
/// (Principle V). A pure-Dart type so the failure path is testable with `FakeGemmaService`.
class ImageProcessingException implements Exception {
  const ImageProcessingException(this.message, {this.cause});
  final String message;
  final Object? cause;

  @override
  String toString() => 'ImageProcessingException: $message';
}

/// The **single** abstraction over `flutter_gemma` (Constitution Principle VII).
///
/// It is the only seam through which the rest of the app touches model loading, inference,
/// capabilities, and release. The concrete `FlutterGemmaService` (in `lib/infrastructure/gemma/`)
/// is the ONLY file permitted to import `flutter_gemma`; domain and presentation depend on this
/// interface and are unit-tested with `FakeGemmaService`. See
/// `specs/001-model-download-chat/contracts/gemma_service.md`.
abstract interface class GemmaService {
  /// Whether a model is currently loaded and active.
  bool get isLoaded;

  /// Capabilities of the active model; throws [StateError] if not loaded.
  ModelCapabilities get capabilities;

  /// Load the model at [filePath] (a verified, app-private `.litertlm`), configuring modality from
  /// the active model's declared [capabilities] (e.g. enable vision when `capabilities.image`,
  /// Principle III). Releases any previously-loaded model first so exactly ONE model is active
  /// (Principle VIII). Throws [ModelLoadException] on failure.
  Future<void> loadModel(
    String filePath, {
    ModelCapabilities capabilities = ModelCapabilities.textOnly,
  });

  /// Generate a reply for [prompt] given prior [history], optionally grounded in [image] for THIS
  /// prompt; [history] may itself contain image turns that are replayed as context
  /// (FR-015/FR-016). Streams incremental text deltas (FR-013 — never a single block); completes
  /// when generation ends OR when [stop] is called (partial text already emitted is retained by
  /// the caller, FR-014). Implementations MUST run inference off the UI isolate (Principle IV) and
  /// perform no network I/O (Principle I).
  ///
  /// Throws [ImageProcessingException] if the image cannot be processed (FR-020), and [StateError]
  /// if called with an [image] while `capabilities.image` is false (the caller must gate first).
  Stream<String> generate({
    required List<ChatTurn> history,
    required String prompt,
    ImageInput? image,
  });

  /// Halt the in-flight generation immediately (FR-014). Idempotent / safe if idle.
  Future<void> stop();

  /// Release the model and session, freeing memory (FR-029). Idempotent. Calling [generate]
  /// after [close] throws [StateError].
  Future<void> close();
}
