import 'package:ai_assistant/domain/entities/chat_turn.dart';
import 'package:ai_assistant/domain/entities/image_input.dart';
import 'package:ai_assistant/domain/entities/model_capabilities.dart';
import 'package:ai_assistant/domain/services/gemma_service.dart';
import 'package:flutter/foundation.dart' show debugPrint;
// `flutter_gemma` exports its OWN `ImageProcessingException` from `image_processor.dart`; hide it
// so the domain `ImageProcessingException` (from gemma_service.dart) is the unprefixed type this
// seam throws. The plugin's image failures are caught generically and re-mapped (FR-020).
import 'package:flutter_gemma/flutter_gemma.dart' hide ImageProcessingException;
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// THE single concrete [GemmaService] — the ONLY file in the codebase permitted to import
/// `flutter_gemma` (Constitution Principle VII, enforced by tool/check_plugin_seam.sh). Everything
/// else depends on the interface and is tested with `FakeGemmaService`.
///
/// VERSION NOTE: written against flutter_gemma **0.15.3** on stable Dart 3.12.1. Gemma 4 E2B is
/// loaded as `ModelType.gemma4` from a `ModelFileType.litertlm` artifact (LiteRT-LM handles the
/// chat template on Android). The file is downloaded out-of-band by `BackgroundModelDownloader`
/// (foreground service) and handed to the modern `FlutterGemma.installModel().fromFile(...)`
/// builder, which references it in place (no copy). Any future model/runtime change stays confined
/// to this seam.
///
/// IMAGE INPUT (002): when the active model's [ModelCapabilities.image] is true, the chat is created
/// with `supportImage: true, maxNumImages: 1` (vision modality on), the current prompt and any
/// image-bearing history turns are sent via `Message.withImage`/`Message.imageOnly`, and the
/// plugin's image decode/validate/resize (its `ImageProcessor`, 896², 10 MB) runs natively off the
/// UI isolate (R1/R4). Image failures are mapped to a domain [ImageProcessingException] (FR-020).
class FlutterGemmaService implements GemmaService {
  static const int _maxTokens = 2048;

  /// flutter_gemma's `ServiceRegistry` must be initialized once before `installModel()`; it throws
  /// otherwise. `main.dart` can't do it (plugin-seam rule), so we do it lazily + idempotently here.
  /// No `huggingFaceToken` — the model is a public artifact (Principle I: the only network egress is
  /// the download, and that runs through `BackgroundModelDownloader`, not this seam).
  static bool _initialized = false;

  InferenceModel? _model;
  InferenceChat? _chat;
  bool _loaded = false;
  ModelCapabilities _capabilities = ModelCapabilities.textOnly;

  /// The real error from the most recent backend-activation attempt. Surfaced as the `cause` of the
  /// [ModelLoadException] thrown when EVERY backend fails, so a load failure is diagnosable (e.g. a
  /// 0.16.x `BackendInitException` / vision-encoder rejection) instead of silently masquerading as a
  /// text-only model that "does not accept images" (002 audit).
  Object? _lastActivationError;

  Future<void> _ensureInitialized() async {
    if (_initialized) return;
    await FlutterGemma.initialize();
    _initialized = true;
  }

  @override
  bool get isLoaded => _loaded;

  @override
  ModelCapabilities get capabilities {
    if (!_loaded) {
      throw StateError('capabilities read before a model was loaded');
    }
    // Capabilities are DATA from the catalog, passed into loadModel (Principle III) — never a fixed
    // value or a per-model `if`.
    return _capabilities;
  }

  @override
  Future<void> loadModel(
    String filePath, {
    ModelCapabilities capabilities = ModelCapabilities.textOnly,
  }) async {
    // Release any previously-loaded model first → exactly one active (Principle VIII).
    await close();
    try {
      await _ensureInitialized();
      // `.fromFile()` references the already-downloaded artifact in place (FileSourceHandler does
      // not copy) and sets it as the active inference model. Gemma 4 E2B `.litertlm`.
      await FlutterGemma.installModel(
        modelType: ModelType.gemma4,
        fileType: ModelFileType.litertlm,
      ).fromFile(filePath).install();

      // Prefer GPU; fall back to CPU if the backend can't initialize / OOMs on an 8 GB device (R1).
      // The model is created with vision enabled (and one image cap) when the catalog declares it.
      _lastActivationError = null;
      _model = await _activate(PreferredBackend.gpu, supportImage: capabilities.image) ??
          await _activate(PreferredBackend.cpu, supportImage: capabilities.image);
      if (_model == null) {
        // Carry the swallowed backend error so the failure is diagnosable rather than generic (002
        // audit): without this, a vision-load rejection surfaces downstream as a misleading
        // "this model does not accept images" capability flip.
        throw ModelLoadException(
          'could not initialize a backend for the model',
          cause: _lastActivationError,
        );
      }
      // Vision modality on the chat session follows the catalog capability
      // (enableVisionModality: supportImage), one image per message this slice (FR-005/FR-006, R1).
      // maxNumImages lives on getActiveModel (createChat has no such param, even in 0.16.x).
      _chat = await _model!.createChat(
        modelType: ModelType.gemma4,
        supportImage: capabilities.image,
        supportAudio: false,
        supportsFunctionCalls: false,
        isThinking: false,
      );
      _capabilities = capabilities;
      _loaded = true;
    } on ModelLoadException {
      await close();
      rethrow;
    } catch (error) {
      await close();
      throw ModelLoadException('failed to load model', cause: error);
    }
  }

  Future<InferenceModel?> _activate(
    PreferredBackend backend, {
    required bool supportImage,
  }) async {
    try {
      return await FlutterGemma.getActiveModel(
        maxTokens: _maxTokens,
        preferredBackend: backend,
        supportImage: supportImage,
        maxNumImages: supportImage ? 1 : null,
      );
    } catch (error, stackTrace) {
      // Return null so the GPU→CPU fallback still proceeds, but DON'T discard the cause: keep it for
      // the ModelLoadException, and log it so an on-device load failure is visible in logcat instead
      // of a silent capability flip (002 audit). A backend that fails only with vision enabled is the
      // smoking gun for the "image removed — this model does not accept images" symptom.
      _lastActivationError = error;
      debugPrint(
        'GemmaService: $backend activation failed (supportImage: $supportImage): $error\n$stackTrace',
      );
      return null;
    }
  }

  @override
  Stream<String> generate({
    required List<ChatTurn> history,
    required String prompt,
    ImageInput? image,
  }) async* {
    final chat = _chat;
    if (!_loaded || chat == null) {
      throw StateError('generate() called with no model loaded');
    }
    // The caller must gate on capabilities before sending an image (FR-005, contract #12).
    if (image != null && !_capabilities.image) {
      throw StateError('generate(image:) called while the model does not support images');
    }

    final involvesImage = image != null || history.any((turn) => turn.image != null);
    try {
      // The caller owns context assembly + sliding window (FR-017/Q2), so rebuild the chat history
      // from what it passes — including any image-bearing turns (FR-015/FR-016) — then add the new
      // prompt. (Re-ingesting history each turn is the cost of a stateless seam; a kept-warm
      // session is a later optimization — R1 risk.)
      await chat.clearHistory(
        replayHistory: history.map(_toPluginMessage).toList(),
      );
      await chat.addQueryChunk(_promptMessage(prompt, image));

      await for (final response in chat.generateChatResponseAsync()) {
        if (response is TextResponse) {
          yield response.token;
        }
        // ThinkingResponse / FunctionCallResponse are ignored this slice (text + image only).
      }
    } catch (error) {
      // Map image decode/validation/resize/OOM failures to a typed, user-facing failure (FR-020,
      // Principle V). Text-only failures propagate unchanged so the chat controller keeps the
      // partial reply as stopped-partial.
      if (involvesImage && error is! StateError) {
        throw ImageProcessingException('could not process the image', cause: error);
      }
      rethrow;
    }
  }

  /// Map a history [turn] to the plugin's `Message`, carrying its image when present.
  Message _toPluginMessage(ChatTurn turn) {
    final image = turn.image;
    if (image == null) {
      return Message.text(text: turn.text, isUser: turn.isUser);
    }
    if (turn.text.isEmpty) {
      return Message.imageOnly(imageBytes: image.bytes, isUser: turn.isUser);
    }
    return Message.withImage(text: turn.text, imageBytes: image.bytes, isUser: turn.isUser);
  }

  /// Build the current prompt message: text-only, image+text, or image-only (empty text, FR-004).
  Message _promptMessage(String prompt, ImageInput? image) {
    if (image == null) {
      return Message.text(text: prompt, isUser: true);
    }
    if (prompt.isEmpty) {
      return Message.imageOnly(imageBytes: image.bytes, isUser: true);
    }
    return Message.withImage(text: prompt, imageBytes: image.bytes, isUser: true);
  }

  @override
  Future<void> stop() async {
    await _chat?.stopGeneration();
  }

  @override
  Future<void> close() async {
    try {
      await _model?.close();
    } finally {
      _model = null;
      _chat = null;
      _loaded = false;
    }
  }
}

/// Kept-alive [GemmaService] (R5) — never auto-disposed, so the ~2.4 GB model doesn't thrash on
/// rebuilds. The model is loaded/released explicitly by the chat session lifecycle.
final gemmaServiceProvider = Provider<GemmaService>((ref) {
  final service = FlutterGemmaService();
  ref.onDispose(service.close);
  return service;
});
