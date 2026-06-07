import 'package:ai_assistant/domain/entities/chat_turn.dart';
import 'package:ai_assistant/domain/entities/model_capabilities.dart';
import 'package:ai_assistant/domain/services/gemma_service.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// THE single concrete [GemmaService] — the ONLY file in the codebase permitted to import
/// `flutter_gemma` (Constitution Principle VII, enforced by tool/check_plugin_seam.sh). Everything
/// else depends on the interface and is tested with `FakeGemmaService`.
///
/// VERSION NOTE: written against the installed flutter_gemma **0.12.6** (the prerelease Dart SDK
/// caps it there — see pubspec.yaml). In 0.12.6 there is no dedicated `ModelType.gemma4` /
/// `ModelFileType.litertlm`: Gemma is `ModelType.gemmaIt` and `ModelFileType.task` already routes
/// `.litertlm` through MediaPipe. When the project moves to a stable Dart ≥3.10.7 and
/// flutter_gemma 0.16.4, switch to `ModelType.gemma4` + the litertlm file type here — and ONLY
/// here, because the seam isolates the change.
class FlutterGemmaService implements GemmaService {
  static const int _maxTokens = 2048;

  InferenceModel? _model;
  InferenceChat? _chat;
  bool _loaded = false;

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
      await FlutterGemma.installModel(
        modelType: ModelType.gemmaIt,
        fileType: ModelFileType.task,
      ).fromFile(filePath).install();

      // Prefer GPU; fall back to CPU if the backend can't initialize / OOMs on an 8 GB device (R1).
      _model = await _activate(PreferredBackend.gpu) ?? await _activate(PreferredBackend.cpu);
      if (_model == null) {
        throw const ModelLoadException('could not initialize a backend for the model');
      }
      _chat = await _model!.createChat(
        modelType: ModelType.gemmaIt,
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
