import 'dart:async';

import 'package:ai_assistant/domain/entities/audio_input.dart';
import 'package:ai_assistant/domain/entities/chat_turn.dart';
import 'package:ai_assistant/domain/entities/generation_event.dart';
import 'package:ai_assistant/domain/entities/image_input.dart';
import 'package:ai_assistant/domain/entities/model_capabilities.dart';
import 'package:ai_assistant/domain/entities/tool_spec.dart';
import 'package:ai_assistant/domain/services/gemma_service.dart';

/// In-memory [GemmaService] for unit tests (contract: gemma_service.md "Test double" + the 003
/// audio and 004 function-calling extensions and 005 memory extensions).
///
/// Emits a scripted sequence of [GenerationEvent]s with controllable timing, honors [stop] by
/// ending the stream early (FR-014), records the image/audio/history media passed to [generate]
/// (FR-015/FR-016 + 003 FR-017), can be scripted to fail with [ImageProcessingException] (FR-020) or
/// [AudioProcessingException] (003 FR-022), and asserts no [generate] after [close].
///
/// It models the seam's gates FOR REAL: `generate(audio:)` while `capabilities.audio` is false
/// throws [StateError] (003 guarantee 13), both media throws [StateError] (guarantee 14),
/// `loadModel(tools:)` while `!capabilities.functionCalling` throws [StateError] (004 guarantee
/// 18), `resumeWithToolResult` outside an in-flight tool turn throws [StateError] (guarantee 22),
/// and `startSession()` before `loadModel` throws [StateError] (005 guarantee 27).
class FakeGemmaService implements GemmaService {
  FakeGemmaService({
    this.capabilitiesData = const ModelCapabilities(image: true, audio: true),
  });

  /// Capabilities returned once loaded. Default mirrors 002/003 (image+audio true); pass a value
  /// with `functionCalling: true` for tool tests, or `ModelCapabilities.textOnly` for gating tests.
  ModelCapabilities capabilitiesData;

  bool throwOnLoad = false;
  bool throwImageProcessing = false;
  bool throwAudioProcessing = false;
  Object? scriptedStreamError;

  /// Back-compat (001–003): bare text deltas [generate] will emit when [scriptedEvents] is unset.
  List<String> scriptedDeltas = <String>[];

  /// 004: the exact [GenerationEvent] sequence [generate] emits. When non-null this takes
  /// precedence over [scriptedDeltas] — script `[ToolCallRequested(...)]`, or
  /// `[TextDelta('hm '), ToolCallRequested(...)]`, etc.
  List<GenerationEvent>? scriptedEvents;

  /// 004: the [GenerationEvent] sequence [resumeWithToolResult] emits (the final reply, or a SECOND
  /// `ToolCallRequested` for the FR-024 test).
  List<GenerationEvent> resumeEvents = <GenerationEvent>[];

  Duration deltaInterval = Duration.zero;
  String? trailingDeltaAfterStop;

  /// Test hook fired synchronously right after each event is added to the stream — lets a
  /// controller test request stop at a PRECISE point (e.g. after a `ToolCallRequested` is delivered
  /// but before the dispatch check, to exercise the `skipped` path deterministically).
  void Function(GenerationEvent event)? onEmit;

  // --- observed state, for assertions ---
  String? loadedPath;
  ModelCapabilities? loadedCapabilities;

  /// The tool specs passed to the last [loadModel] (004 — the gating test asserts empty vs. full).
  List<ToolSpec>? loadedTools;

  /// 005: the [systemInstruction] passed to the last [loadModel] call.
  /// Null means the call was made with no instruction (byte-parity case, guarantee 29).
  String? loadedSystemInstruction;

  /// 005: the [systemInstruction] passed to the last [startSession] call.
  /// Null either means [startSession] has not been called yet, or it was called with null.
  /// Use [startSessionCount] to distinguish the two.
  String? lastStartSessionInstruction;

  /// 005: how many times [startSession] has been called (allows asserting a null-instruction call
  /// vs no call at all).
  int startSessionCount = 0;

  List<ChatTurn>? lastHistory;
  String? lastPrompt;
  ImageInput? lastImage;
  AudioInput? lastAudio;
  List<ImageInput?>? lastHistoryImages;
  List<AudioInput?>? lastHistoryAudio;

  /// 004: the payload handed to the last [resumeWithToolResult] (round-trip assertion).
  String? lastResumeToolName;
  Map<String, Object?>? lastResumeResult;
  int resumeCount = 0;

  int loadCount = 0;
  int stopCount = 0;
  int closeCount = 0;

  bool _loaded = false;
  bool _closed = false;
  bool _stopped = false;
  bool _awaitingToolResult = false;
  StreamController<GenerationEvent>? _controller;

  @override
  bool get isLoaded => _loaded;

  @override
  ModelCapabilities get capabilities {
    if (!_loaded) {
      throw StateError('capabilities read before a model was loaded');
    }
    return capabilitiesData;
  }

  @override
  Future<void> loadModel(
    String filePath, {
    ModelCapabilities? capabilities,
    List<ToolSpec> tools = const [],
    String? systemInstruction,
  }) async {
    if (throwOnLoad) {
      throw const ModelLoadException('fake load failure');
    }
    final caps = capabilities ?? capabilitiesData;
    // Guarantee 18 (004): tool declarations without the capability are unrepresentable.
    if (tools.isNotEmpty && !caps.functionCalling) {
      throw StateError(
        'loadModel(tools:) requires capabilities.functionCalling',
      );
    }
    loadedPath = filePath;
    loadedCapabilities = capabilities;
    loadedTools = tools;
    loadedSystemInstruction = systemInstruction;
    if (capabilities != null) capabilitiesData = capabilities;
    loadCount++;
    _loaded = true;
    _closed = false;
  }

  @override
  Future<void> startSession({String? systemInstruction}) async {
    // Guarantee 27 (005): startSession before load is a programmer error.
    if (!_loaded) {
      throw StateError('startSession() called before a model was loaded');
    }
    lastStartSessionInstruction = systemInstruction;
    startSessionCount++;
    // Reset tool-turn gate so the next generate starts clean (mirrors the seam's epoch bump).
    _awaitingToolResult = false;
  }

  @override
  Stream<GenerationEvent> generate({
    required List<ChatTurn> history,
    required String prompt,
    ImageInput? image,
    AudioInput? audio,
  }) {
    if (_closed) {
      throw StateError('generate() called after close()');
    }
    if (image != null && audio != null) {
      throw StateError('generate() called with both an image and audio');
    }
    if (audio != null && !capabilitiesData.audio) {
      throw StateError(
        'generate(audio:) called while the model does not support audio',
      );
    }
    lastHistory = List<ChatTurn>.unmodifiable(history);
    lastHistoryImages = List<ImageInput?>.unmodifiable(
      history.map((turn) => turn.image),
    );
    lastHistoryAudio = List<AudioInput?>.unmodifiable(
      history.map((turn) => turn.audio),
    );
    lastPrompt = prompt;
    lastImage = image;
    lastAudio = audio;
    return _emit(
      scriptedEvents ?? [for (final d in scriptedDeltas) TextDelta(d)],
    );
  }

  @override
  Stream<GenerationEvent> resumeWithToolResult({
    required String toolName,
    required Map<String, Object?> result,
  }) {
    if (_closed) {
      throw StateError('resumeWithToolResult() called after close()');
    }
    // Guarantee 22: resume is valid only after a tool-call-terminated stream of the same turn.
    if (!_awaitingToolResult) {
      throw StateError(
        'resumeWithToolResult() called outside an in-flight tool turn',
      );
    }
    _awaitingToolResult = false;
    resumeCount++;
    lastResumeToolName = toolName;
    lastResumeResult = result;
    return _emit(resumeEvents);
  }

  Stream<GenerationEvent> _emit(List<GenerationEvent> events) {
    _stopped = false;
    final controller = StreamController<GenerationEvent>();
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
      for (final event in events) {
        if (_stopped || controller.isClosed) break;
        if (deltaInterval > Duration.zero) {
          await Future<void>.delayed(deltaInterval);
        }
        if (_stopped || controller.isClosed) break;
        controller.add(event);
        // After yielding a tool call, the seam permits exactly one resume (guarantee 22).
        if (event is ToolCallRequested) _awaitingToolResult = true;
        onEmit?.call(event);
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
      if (trailingDeltaAfterStop != null) {
        controller.add(TextDelta(trailingDeltaAfterStop!));
      }
      await controller.close();
    }
  }

  @override
  Future<void> close() async {
    closeCount++;
    _loaded = false;
    _closed = true;
    _awaitingToolResult = false;
    final controller = _controller;
    if (controller != null && !controller.isClosed) {
      await controller.close();
    }
  }
}
