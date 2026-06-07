import 'dart:async';

import 'package:ai_assistant/domain/entities/chat_turn.dart';
import 'package:ai_assistant/domain/entities/model_capabilities.dart';
import 'package:ai_assistant/domain/services/gemma_service.dart';

/// In-memory [GemmaService] for unit tests (contract: gemma_service.md "Test double").
///
/// Emits a scripted list of deltas with controllable timing, honors [stop] by ending the stream
/// early (so partial-retention / FR-014 can be tested), and asserts no [generate] after [close].
class FakeGemmaService implements GemmaService {
  FakeGemmaService({this.capabilitiesData = ModelCapabilities.textOnly});

  /// Capabilities returned once loaded (default text-only).
  ModelCapabilities capabilitiesData;

  /// When true, [loadModel] throws [ModelLoadException] (backend-init / OOM simulation).
  bool throwOnLoad = false;

  /// Deltas [generate] will emit, in order.
  List<String> scriptedDeltas = <String>[];

  /// Delay between scripted deltas (default: emit synchronously).
  Duration deltaInterval = Duration.zero;

  // --- observed state, for assertions ---
  String? loadedPath;
  List<ChatTurn>? lastHistory;
  String? lastPrompt;
  int loadCount = 0;
  int stopCount = 0;
  int closeCount = 0;

  bool _loaded = false;
  bool _closed = false;
  bool _stopped = false;
  StreamController<String>? _controller;

  @override
  bool get isLoaded => _loaded;

  @override
  ModelCapabilities get capabilities {
    if (!_loaded) throw StateError('capabilities read before a model was loaded');
    return capabilitiesData;
  }

  @override
  Future<void> loadModel(String filePath) async {
    if (throwOnLoad) {
      throw const ModelLoadException('fake load failure');
    }
    loadedPath = filePath;
    loadCount++;
    _loaded = true;
    _closed = false;
  }

  @override
  Stream<String> generate({
    required List<ChatTurn> history,
    required String prompt,
  }) {
    if (_closed) {
      throw StateError('generate() called after close()');
    }
    lastHistory = List<ChatTurn>.unmodifiable(history);
    lastPrompt = prompt;
    _stopped = false;
    final controller = StreamController<String>();
    _controller = controller;

    Future<void> pump() async {
      for (final delta in scriptedDeltas) {
        if (_stopped || controller.isClosed) break;
        if (deltaInterval > Duration.zero) {
          await Future<void>.delayed(deltaInterval);
        }
        if (_stopped || controller.isClosed) break;
        controller.add(delta);
      }
      if (!controller.isClosed) await controller.close();
    }

    unawaited(pump());
    return controller.stream;
  }

  @override
  Future<void> stop() async {
    stopCount++;
    _stopped = true;
    final controller = _controller;
    if (controller != null && !controller.isClosed) {
      await controller.close();
    }
  }

  @override
  Future<void> close() async {
    closeCount++;
    _loaded = false;
    _closed = true;
    final controller = _controller;
    if (controller != null && !controller.isClosed) {
      await controller.close();
    }
  }
}
