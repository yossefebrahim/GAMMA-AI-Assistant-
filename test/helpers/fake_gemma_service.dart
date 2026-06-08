import 'dart:async';

import 'package:ai_assistant/domain/entities/chat_turn.dart';
import 'package:ai_assistant/domain/entities/image_input.dart';
import 'package:ai_assistant/domain/entities/model_capabilities.dart';
import 'package:ai_assistant/domain/services/gemma_service.dart';

/// In-memory [GemmaService] for unit tests (contract: gemma_service.md "Test double").
///
/// Emits a scripted list of deltas with controllable timing, honors [stop] by ending the stream
/// early (so partial-retention / FR-014 can be tested), records the image passed to [generate] and
/// the images carried on [history] turns (so FR-015/FR-016 context replay is assertable), can be
/// scripted to fail an image with [ImageProcessingException] (FR-020), and asserts no [generate]
/// after [close].
class FakeGemmaService implements GemmaService {
  FakeGemmaService({this.capabilitiesData = ModelCapabilities.textOnly});

  /// Capabilities returned once loaded (default text-only; set `image: true` for image tests).
  ModelCapabilities capabilitiesData;

  /// When true, [loadModel] throws [ModelLoadException] (backend-init / OOM simulation).
  bool throwOnLoad = false;

  /// When true, [generate] surfaces an [ImageProcessingException] on the stream (FR-020 path).
  bool throwImageProcessing = false;

  /// Deltas [generate] will emit, in order.
  List<String> scriptedDeltas = <String>[];

  /// Delay between scripted deltas (default: emit synchronously).
  Duration deltaInterval = Duration.zero;

  // --- observed state, for assertions ---
  String? loadedPath;
  ModelCapabilities? loadedCapabilities;
  List<ChatTurn>? lastHistory;
  String? lastPrompt;

  /// The image passed with the current prompt on the last [generate] call (FR-012).
  ImageInput? lastImage;

  /// The image (or null) carried by each [history] turn on the last [generate] call, in order
  /// (FR-015/FR-016 — asserts a prior image is replayed as context).
  List<ImageInput?>? lastHistoryImages;

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
  Future<void> loadModel(String filePath, {ModelCapabilities? capabilities}) async {
    if (throwOnLoad) {
      throw const ModelLoadException('fake load failure');
    }
    loadedPath = filePath;
    loadedCapabilities = capabilities;
    if (capabilities != null) capabilitiesData = capabilities;
    loadCount++;
    _loaded = true;
    _closed = false;
  }

  @override
  Stream<String> generate({
    required List<ChatTurn> history,
    required String prompt,
    ImageInput? image,
  }) {
    if (_closed) {
      throw StateError('generate() called after close()');
    }
    lastHistory = List<ChatTurn>.unmodifiable(history);
    lastHistoryImages =
        List<ImageInput?>.unmodifiable(history.map((turn) => turn.image));
    lastPrompt = prompt;
    lastImage = image;
    _stopped = false;
    final controller = StreamController<String>();
    _controller = controller;

    Future<void> pump() async {
      if (throwImageProcessing) {
        controller.addError(
          const ImageProcessingException('fake image processing failure'),
        );
        if (!controller.isClosed) await controller.close();
        return;
      }
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
