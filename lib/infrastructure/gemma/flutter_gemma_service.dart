import 'package:ai_assistant/domain/entities/chat_turn.dart';
import 'package:ai_assistant/domain/entities/model_capabilities.dart';
import 'package:ai_assistant/domain/services/gemma_service.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
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
    // Text-only scope this slice (FR-016, Principle III). When multimodal Gemma is enabled, read
    // the active model's modality flags here instead of returning a fixed value.
    return ModelCapabilities.textOnly;
  }

  @override
  Future<void> loadModel(String filePath) async {
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
      _model = await _activate(PreferredBackend.gpu) ?? await _activate(PreferredBackend.cpu);
      if (_model == null) {
        throw const ModelLoadException('could not initialize a backend for the model');
      }
      _chat = await _model!.createChat(
        modelType: ModelType.gemma4,
        supportImage: false,
        supportAudio: false,
        supportsFunctionCalls: false,
        isThinking: false,
      );
      _loaded = true;
    } on ModelLoadException {
      await close();
      rethrow;
    } catch (error) {
      await close();
      throw ModelLoadException('failed to load model', cause: error);
    }
  }

  Future<InferenceModel?> _activate(PreferredBackend backend) async {
    try {
      return await FlutterGemma.getActiveModel(
        maxTokens: _maxTokens,
        preferredBackend: backend,
      );
    } catch (_) {
      return null;
    }
  }

  @override
  Stream<String> generate({
    required List<ChatTurn> history,
    required String prompt,
  }) async* {
    final chat = _chat;
    if (!_loaded || chat == null) {
      throw StateError('generate() called with no model loaded');
    }
    // The caller owns context assembly + sliding window (FR-017/Q2), so rebuild the chat history
    // from what it passes, then add the new prompt. (Re-ingesting history each turn is the cost of
    // a stateless seam; a kept-warm session is a later optimization.)
    await chat.clearHistory(
      replayHistory: history
          .map((turn) => Message.text(text: turn.text, isUser: turn.isUser))
          .toList(),
    );
    await chat.addQueryChunk(Message.text(text: prompt, isUser: true));

    await for (final response in chat.generateChatResponseAsync()) {
      if (response is TextResponse) {
        yield response.token;
      }
      // ThinkingResponse / FunctionCallResponse are ignored this slice (text-only, FR-016).
    }
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
/// rebuilds. The model is loaded/released explicitly by the chat session lifecycle (T033).
final gemmaServiceProvider = Provider<GemmaService>((ref) {
  final service = FlutterGemmaService();
  ref.onDispose(service.close);
  return service;
});
