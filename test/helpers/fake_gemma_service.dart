import 'dart:async';

import 'package:ai_assistant/domain/entities/audio_input.dart';
import 'package:ai_assistant/domain/entities/chat_turn.dart';
import 'package:ai_assistant/domain/entities/image_input.dart';
import 'package:ai_assistant/domain/entities/model_capabilities.dart';
import 'package:ai_assistant/domain/services/gemma_service.dart';

/// In-memory [GemmaService] for unit tests (contract: gemma_service.md "Test double" + the 003
/// audio extensions).
///
/// Emits a scripted list of deltas with controllable timing, honors [stop] by ending the stream
/// early (so partial-retention / FR-014 can be tested), records the image/audio passed to
/// [generate] and the media carried on [history] turns (so FR-015/FR-016 + 003 FR-017 context
/// replay is assertable), can be scripted to fail with [ImageProcessingException] (FR-020) or
/// [AudioProcessingException] (003 FR-022), and asserts no [generate] after [close].
///
/// It models the seam's gates FOR REAL (003 contract, closing 002 audit L6): `generate(audio:)`
/// while `capabilities.audio` is false throws [StateError] (guarantee 13 — the FFI silent-drop
/// guard), and passing both media throws [StateError] (guarantee 14).
class FakeGemmaService implements GemmaService {
  FakeGemmaService({this.capabilitiesData = const ModelCapabilities(image: true, audio: true)});

  /// Capabilities returned once loaded. Default mirrors the catalog (image+audio true — 003
  /// contract); pass `ModelCapabilities.textOnly` (or audio:false) for gating tests.
  ModelCapabilities capabilitiesData;

  /// When true, [loadModel] throws [ModelLoadException] (backend-init / OOM simulation).
  bool throwOnLoad = false;

  /// When true, [generate] surfaces an [ImageProcessingException] on the stream (FR-020 path).
  bool throwImageProcessing = false;

  /// When true, [generate] surfaces an [AudioProcessingException] on the stream (003 FR-022
  /// path — scripted unprocessable clip / OOM-ish native failure).
  bool throwAudioProcessing = false;

  /// When set, [generate] surfaces this generic error on the stream — the L4 regression lock:
  /// a failure on a turn that does NOT carry current-prompt audio must reach the caller
  /// UN-remapped (003 guarantee 15), never as an audio/image banner.
  Object? scriptedStreamError;

  /// Deltas [generate] will emit, in order.
  List<String> scriptedDeltas = <String>[];

  /// Delay between scripted deltas (default: emit synchronously).
  Duration deltaInterval = Duration.zero;

  /// When set, [stop] emits this one final delta BEFORE closing the stream — simulating a token the
  /// plugin produced concurrently with `stopGeneration()`. Lets a test prove the caller retains it
  /// (FR-014) rather than dropping it.
  String? trailingDeltaAfterStop;

  // --- observed state, for assertions ---
  String? loadedPath;
  ModelCapabilities? loadedCapabilities;
  List<ChatTurn>? lastHistory;
  String? lastPrompt;

  /// The image passed with the current prompt on the last [generate] call (FR-012).
  ImageInput? lastImage;

  /// The clip passed with the current prompt on the last [generate] call (003 FR-013).
  AudioInput? lastAudio;

  /// The image (or null) carried by each [history] turn on the last [generate] call, in order
  /// (FR-015/FR-016 — asserts a prior image is replayed as context).
  List<ImageInput?>? lastHistoryImages;

  /// The clip (or null) carried by each [history] turn on the last [generate] call, in order
  /// (003 FR-017 — asserts a prior clip is replayed as context).
  List<AudioInput?>? lastHistoryAudio;

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
    AudioInput? audio,
  }) {
    if (_closed) {
      throw StateError('generate() called after close()');
    }
    // Guarantee 14 (003): one attachment per message — audio XOR image (spec Q3).
    if (image != null && audio != null) {
      throw StateError('generate() called with both an image and audio');
    }
    // Guarantee 13 (003, closes 002 audit L6): the ungated-audio gate is REAL in the fake — the
    // plugin's FFI path silently drops ungated audio, so the seam (and this double) must throw.
    if (audio != null && !capabilitiesData.audio) {
      throw StateError('generate(audio:) called while the model does not support audio');
    }
    lastHistory = List<ChatTurn>.unmodifiable(history);
    lastHistoryImages =
        List<ImageInput?>.unmodifiable(history.map((turn) => turn.image));
    lastHistoryAudio =
        List<AudioInput?>.unmodifiable(history.map((turn) => turn.audio));
    lastPrompt = prompt;
    lastImage = image;
    lastAudio = audio;
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
      if (throwAudioProcessing) {
        controller.addError(
          const AudioProcessingException('fake audio processing failure'),
        );
        if (!controller.isClosed) await controller.close();
        return;
      }
      if (scriptedStreamError != null) {
        controller.addError(scriptedStreamError!);
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
      // Deliver one final, already-produced token concurrently with stop (FR-014 path).
      if (trailingDeltaAfterStop != null) {
        controller.add(trailingDeltaAfterStop!);
      }
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
