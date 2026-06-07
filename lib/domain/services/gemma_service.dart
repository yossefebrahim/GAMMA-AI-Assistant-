import 'package:ai_assistant/domain/entities/chat_turn.dart';
import 'package:ai_assistant/domain/entities/model_capabilities.dart';

/// Thrown when a model fails to load (e.g. backend init / OOM).
class ModelLoadException implements Exception {
  const ModelLoadException(this.message, {this.cause});
  final String message;
  final Object? cause;

  @override
  String toString() => 'ModelLoadException: $message';
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

  /// Load the model at [filePath] (a verified, app-private `.litertlm`). Releases any
  /// previously-loaded model first so exactly ONE model is active (Principle VIII).
  /// Throws [ModelLoadException] on failure.
  Future<void> loadModel(String filePath);

  /// Generate a reply for [prompt] given prior [history], streaming text deltas.
  ///
  /// The returned stream emits incremental text (FR-013 — never a single block); it completes
  /// when generation ends OR when [stop] is called (partial text already emitted is retained by
  /// the caller, FR-014). Implementations MUST run inference off the UI isolate (Principle IV)
  /// and perform no network I/O (Principle I).
  Stream<String> generate({
    required List<ChatTurn> history,
    required String prompt,
  });

  /// Halt the in-flight generation immediately (FR-014). Idempotent / safe if idle.
  Future<void> stop();

  /// Release the model and session, freeing memory (FR-029). Idempotent. Calling [generate]
  /// after [close] throws [StateError].
  Future<void> close();
}
