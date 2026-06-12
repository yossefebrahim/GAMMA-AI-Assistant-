import 'package:ai_assistant/domain/entities/audio_input.dart';
import 'package:ai_assistant/domain/entities/chat_turn.dart';
import 'package:ai_assistant/domain/entities/generation_event.dart';
import 'package:ai_assistant/domain/entities/image_input.dart';
import 'package:ai_assistant/domain/entities/model_capabilities.dart';
import 'package:ai_assistant/domain/entities/tool_spec.dart';
import 'package:ai_assistant/domain/services/gemma_service.dart';
import 'package:ai_assistant/infrastructure/gemma/leak_filter.dart';
import 'package:ai_assistant/infrastructure/gemma/tool_call_json.dart';
import 'package:flutter/foundation.dart' show DebugPrintCallback, debugPrint;
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
///
/// AUDIO INPUT (003): when [ModelCapabilities.audio] is true, `supportAudio: true` is threaded to
/// BOTH backend activation attempts and to `createChat` (→ `enableAudioModality`); the current
/// prompt and audio-bearing history turns map to `Message.withAudio`/`Message.audioOnly`. The
/// seam gates ungated audio with its own [StateError] — load-bearing, because the plugin's FFI
/// path SILENTLY DROPS audio when the flag was off at load (003 research R1, spike §1.2).
///
/// FUNCTION CALLING (004): when [ModelCapabilities.functionCalling] is true, model load threads the
/// mapped tool declarations + `supportsFunctionCalls: true` + `toolChoice: ToolChoice.auto` + the
/// R6 tool-use `systemInstruction` into `createChat` — all derived from ONE source so they can
/// never desync (the spike's silent-trap rule, guarantee 18). `generate` yields sealed
/// [GenerationEvent]s: text deltas pass through the [LeakFilter] (which suppresses the 100% raw-JSON
/// leak, guarantee 20) and the end-of-stream `FunctionCallResponse` surfaces as a typed
/// [ToolCallRequested]; `resumeWithToolResult` sends `Message.toolResponse` and re-generates for the
/// ONE allowed round trip. Tool turns in `history` replay as the plugin's `Message.toolCall` +
/// `Message.toolResponse` pair (the plugin's own history omits streamed tool calls — the app DB is
/// the source of truth, guarantee 23).
///
/// KEPT-WARM SESSION (the R1 "later optimization", now load-bearing for responsiveness): the
/// plugin executes session create / prompt prefill / image encode ON THE ANDROID MAIN THREAD
/// (its Pigeon handlers have no TaskQueue), so a full `clearHistory(replayHistory:)` per send —
/// which recreates the native session and re-encodes EVERY history image — froze input and the
/// keyboard for seconds. `generate` therefore fingerprints what the native session already holds
/// and, when the caller's history is exactly the prior context plus the last exchange, appends
/// only the new prompt instead of replaying. Any stop / error / cancel / reload — OR any tool turn
/// in the conversation — marks the session dirty so the next send falls back to the full, correct
/// resync. The seam contract is unchanged: callers still pass the full history every turn.
class FlutterGemmaService implements GemmaService {
  static const int _maxTokens = 2048;

  /// flutter_gemma's `ServiceRegistry` must be initialized once before `installModel()`; it throws
  /// otherwise. `main.dart` can't do it (plugin-seam rule), so we do it lazily + idempotently here.
  static bool _initialized = false;

  InferenceModel? _model;
  InferenceChat? _chat;
  bool _loaded = false;
  ModelCapabilities _capabilities = ModelCapabilities.textOnly;

  /// Whether the active chat was created with function calling on — the SINGLE source the leak
  /// filter and resume discipline derive from (guarantee 18 structural coupling).
  bool _supportsFunctionCalls = false;

  /// The tool specs and capabilities that were active when the current [_chat] was created. Stored
  /// so [startSession] can recreate the chat with the SAME tools/capabilities but a new instruction
  /// (guarantee 27 — same model, same tools, new facts block).
  List<ToolSpec> _activeChatTools = const [];
  ModelCapabilities _activeChatCapabilities = ModelCapabilities.textOnly;

  /// True between a [ToolCallRequested]-terminated stream and its [resumeWithToolResult] — gates
  /// the one-allowed round trip (guarantee 22). Resume outside this window is a programmer error.
  bool _awaitingToolResult = false;

  /// The real error from the most recent backend-activation attempt. Surfaced as the `cause` of the
  /// [ModelLoadException] thrown when EVERY backend fails, so a load failure is diagnosable.
  Object? _lastActivationError;

  /// What the native session currently holds, as cheap per-turn fingerprints. Null whenever the
  /// native context may diverge from the caller's history (after load / stop / a stream error /
  /// cancel / close / any tool turn), which forces the next [generate] to do the full
  /// `clearHistory(replayHistory:)` resync.
  List<_TurnFingerprint>? _sessionTurns;

  /// Bumped by [loadModel] / [stop] / [close] so an in-flight [generate] can never commit
  /// fingerprints for a session that was invalidated underneath it.
  int _sessionEpoch = 0;

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
    return _capabilities;
  }

  @override
  Future<void> loadModel(
    String filePath, {
    ModelCapabilities capabilities = ModelCapabilities.textOnly,
    List<ToolSpec> tools = const [],
    String? systemInstruction,
  }) async {
    // Guarantee 18 — the silent-trap closure (spike §1.3): tool declarations without the
    // capability are unrepresentable. Checked BEFORE close() so it is a pure, state-free contract
    // violation (testable without a device), and synchronous (a programmer error, not an async
    // failure).
    if (tools.isNotEmpty && !capabilities.functionCalling) {
      throw StateError(
        'loadModel(tools:) requires capabilities.functionCalling — refusing the silent-trap '
        'combination (ungated tools would spill raw JSON / no-op)',
      );
    }
    // Release any previously-loaded model first → exactly one active (Principle VIII).
    await close();
    try {
      await _ensureInitialized();
      await FlutterGemma.installModel(
        modelType: ModelType.gemma4,
        fileType: ModelFileType.litertlm,
      ).fromFile(filePath).install();

      // Prefer GPU; fall back to CPU if the backend can't initialize / OOMs on an 8 GB device (R1).
      _lastActivationError = null;
      _model =
          await _activate(
            PreferredBackend.gpu,
            supportImage: capabilities.image,
            supportAudio: capabilities.audio,
          ) ??
          await _activate(
            PreferredBackend.cpu,
            supportImage: capabilities.image,
            supportAudio: capabilities.audio,
          );
      if (_model == null) {
        throw ModelLoadException(
          'could not initialize a backend for the model',
          cause: _lastActivationError,
        );
      }

      // Create the chat via the shared helper (F5): tools / supportsFunctionCalls / system
      // instruction all derive from one source so they can never desync (guarantee 18 / 26 / 29).
      _chat = await _createChat(capabilities, tools, systemInstruction);
      _capabilities = capabilities;
      _activeChatTools = tools;
      _activeChatCapabilities = capabilities;
      _loaded = true;
    } on ModelLoadException {
      await close();
      rethrow;
    } catch (error) {
      await close();
      throw ModelLoadException('failed to load model', cause: error);
    }
  }

  @override
  Future<void> startSession({String? systemInstruction}) async {
    // Guarantee 27: must have a loaded model to recreate the chat.
    if (!_loaded || _model == null) {
      throw StateError('startSession() called before a model was loaded');
    }

    // FFI cached-session caveat (spike §1.2): a second createChat on the same loaded model returns
    // the CACHED native session unless the prior session is closed first. Close it now so the new
    // createChat always gets a fresh native conversation with the new systemInstruction.
    await _chat?.session.close();
    _chat = null;

    // Reset warm-session state: the next generate must do a full clearHistory replay (there is no
    // prior context in the newly created session).
    _sessionTurns = null;
    _sessionEpoch++;
    _awaitingToolResult = false;

    // Recreate on the SAME loaded model with the SAME tools/capabilities and the new instruction
    // (guarantee 27 — no model reload, no re-mmap). If recreation throws (e.g. OOM), fall back to a
    // full unload so the seam never reports `isLoaded == true` with a null chat (matches
    // loadModel's honest-state contract): callers see an unloaded service and can reload.
    try {
      _chat = await _createChat(
        _activeChatCapabilities,
        _activeChatTools,
        systemInstruction,
      );
    } catch (_) {
      await close();
      rethrow;
    }
  }

  /// Create the native chat from [capabilities] + [tools] + [systemInstruction], setting
  /// [_supportsFunctionCalls] from the same source so the leak filter / resume discipline can never
  /// desync (guarantee 18). Shared verbatim by [loadModel] and [startSession] (F5 — one createChat
  /// call site). The systemInstruction is composed OUTSIDE the seam (guarantee 26 / 005) and
  /// forwarded as-is; null ⇒ none.
  Future<InferenceChat> _createChat(
    ModelCapabilities capabilities,
    List<ToolSpec> tools,
    String? systemInstruction,
  ) async {
    final functionCalling = capabilities.functionCalling;
    final pluginTools = functionCalling
        ? [for (final spec in tools) _toPluginTool(spec)]
        : const <Tool>[];
    _supportsFunctionCalls = functionCalling;
    return _model!.createChat(
      modelType: ModelType.gemma4,
      supportImage: capabilities.image,
      supportAudio: capabilities.audio,
      supportsFunctionCalls: functionCalling,
      tools: pluginTools,
      toolChoice: ToolChoice.auto,
      systemInstruction: systemInstruction,
      isThinking: false,
    );
  }

  Future<InferenceModel?> _activate(
    PreferredBackend backend, {
    required bool supportImage,
    required bool supportAudio,
  }) async {
    try {
      return await FlutterGemma.getActiveModel(
        maxTokens: _maxTokens,
        preferredBackend: backend,
        supportImage: supportImage,
        maxNumImages: supportImage ? 1 : null,
        supportAudio: supportAudio,
      );
    } catch (error, stackTrace) {
      _lastActivationError = error;
      debugPrint(
        'GemmaService: $backend activation failed (supportImage: $supportImage, '
        'supportAudio: $supportAudio): $error\n$stackTrace',
      );
      return null;
    }
  }

  /// Map a domain [ToolSpec] to the plugin's `Tool` (the only place the two types meet).
  Tool _toPluginTool(ToolSpec spec) => Tool(
    name: spec.name,
    description: spec.description,
    parameters: spec.parameters,
  );

  @override
  Stream<GenerationEvent> generate({
    required List<ChatTurn> history,
    required String prompt,
    ImageInput? image,
    AudioInput? audio,
  }) async* {
    // One attachment per message — audio XOR image (003 guarantee 14, spec Q3). State-free, so the
    // contract is unit-testable without a device.
    if (image != null && audio != null) {
      throw StateError('generate() called with both an image and audio');
    }
    final chat = _chat;
    if (!_loaded || chat == null) {
      throw StateError('generate() called with no model loaded');
    }
    if (image != null && !_capabilities.image) {
      throw StateError(
        'generate(image:) called while the model does not support images',
      );
    }
    // The audio gate is LOAD-BEARING (003 guarantee 13): the plugin's FFI path silently drops audio
    // that wasn't enabled at load.
    if (audio != null && !_capabilities.audio) {
      throw StateError(
        'generate(audio:) called while the model does not support audio',
      );
    }

    final involvesImage =
        image != null || history.any((turn) => turn.image != null);

    // A tool turn anywhere in the conversation forces a full replay (the resume path mutates the
    // native session in ways the warm fingerprints don't track — correctness over the optimization).
    final fingerprints = [
      for (final turn in history) _TurnFingerprint.ofTurn(turn),
    ];
    final warm =
        !history.any((turn) => turn.isTool) && _matchesSession(fingerprints);
    _sessionTurns = null;
    final epoch = _sessionEpoch;
    _awaitingToolResult = false;

    final filter = LeakFilter(active: _supportsFunctionCalls);

    try {
      if (!warm) {
        // Rebuild the chat history from what the caller passes — expanding tool turns into the
        // plugin's call+response replay pair (guarantee 23) — then add the new prompt.
        await chat.clearHistory(
          replayHistory: [for (final turn in history) ..._replayMessages(turn)],
        );
      }
      await chat.addQueryChunk(_promptMessage(prompt, image, audio));

      final reply = StringBuffer();
      var sawToolCall = false;
      await for (final response in chat.generateChatResponseAsync()) {
        if (response is TextResponse) {
          final emit = filter.process(response.token);
          if (emit.isNotEmpty) {
            reply.write(emit);
            yield TextDelta(emit);
          }
        } else if (response is FunctionCallResponse) {
          // End-of-stream call (guarantee 21). The withheld text was the raw-JSON leak — discard it.
          sawToolCall = true;
          filter.discardOnToolCall();
          _awaitingToolResult = true;
          yield ToolCallRequested(
            response.name,
            Map<String, Object?>.from(response.args),
          );
        } else if (response is ParallelFunctionCallResponse) {
          // Parallel calls collapse to ONE event: first + extraCallCount (FR-006/FR-024 handled by
          // the controller).
          sawToolCall = true;
          filter.discardOnToolCall();
          _awaitingToolResult = true;
          final calls = response.calls;
          final first = calls.first;
          yield ToolCallRequested(
            first.name,
            Map<String, Object?>.from(first.args),
            extraCallCount: calls.length - 1,
          );
        }
      }

      if (!sawToolCall) {
        // Text-terminated turn: a withheld `{`-prefix was a false positive — flush it verbatim.
        final flushed = filter.flushOnText();
        if (flushed.isNotEmpty) {
          reply.write(flushed);
          yield TextDelta(flushed);
        }
      }

      // Commit warm fingerprints ONLY on a clean, tool-free text turn (a tool turn leaves the
      // session dirty so the next send replays fully).
      if (epoch == _sessionEpoch && !sawToolCall) {
        _sessionTurns = [
          ...fingerprints,
          _TurnFingerprint(
            isUser: true,
            text: prompt,
            imageByteLength: image?.bytes.length,
            audioByteLength: audio?.bytes.length,
          ),
          _TurnFingerprint(
            isUser: false,
            text: reply.toString(),
            imageByteLength: null,
            audioByteLength: null,
          ),
        ];
      }
    } catch (error) {
      if (error is StateError) rethrow;
      if (audio != null) {
        throw AudioProcessingException(
          'could not process the audio',
          cause: error,
        );
      }
      if (involvesImage) {
        throw ImageProcessingException(
          'could not process the image',
          cause: error,
        );
      }
      rethrow;
    }
  }

  @override
  Stream<GenerationEvent> resumeWithToolResult({
    required String toolName,
    required Map<String, Object?> result,
  }) async* {
    final chat = _chat;
    if (!_loaded || chat == null) {
      throw StateError('resumeWithToolResult() called with no model loaded');
    }
    // Guarantee 22 — resume is valid exactly once, only after a tool-call-terminated stream.
    if (!_awaitingToolResult) {
      throw StateError(
        'resumeWithToolResult() called outside an in-flight tool turn',
      );
    }
    _awaitingToolResult = false;
    // A tool turn leaves the session dirty: the next send does a full replay (the call+response are
    // now in the native context but not in the warm fingerprints — correctness wins).
    _sessionTurns = null;

    final filter = LeakFilter(active: _supportsFunctionCalls);
    try {
      // The plugin reaches the model as a user-role `<tool_response>` block on Android/.litertlm.
      await chat.addQuery(
        Message.toolResponse(toolName: toolName, response: result),
      );
      await for (final response in chat.generateChatResponseAsync()) {
        if (response is TextResponse) {
          final emit = filter.process(response.token);
          if (emit.isNotEmpty) yield TextDelta(emit);
        } else if (response is FunctionCallResponse) {
          // A SECOND call on resume is surfaced, not executed (the controller chips-and-skips it,
          // FR-006/FR-024).
          filter.discardOnToolCall();
          yield ToolCallRequested(
            response.name,
            Map<String, Object?>.from(response.args),
          );
        } else if (response is ParallelFunctionCallResponse) {
          filter.discardOnToolCall();
          final calls = response.calls;
          final first = calls.first;
          yield ToolCallRequested(
            first.name,
            Map<String, Object?>.from(first.args),
            extraCallCount: calls.length - 1,
          );
        }
      }
      final flushed = filter.flushOnText();
      if (flushed.isNotEmpty) yield TextDelta(flushed);
    } catch (error) {
      if (error is StateError) rethrow;
      rethrow;
    }
  }

  /// Whether the native session already holds exactly [fingerprints] — the warm fast-path test.
  bool _matchesSession(List<_TurnFingerprint> fingerprints) {
    final held = _sessionTurns;
    if (held == null || held.length != fingerprints.length) return false;
    for (var i = 0; i < held.length; i++) {
      if (held[i] != fingerprints[i]) return false;
    }
    return true;
  }

  /// Expand one history [turn] into the plugin message(s) that replay it (guarantee 23). A tool
  /// turn becomes the call+response PAIR; everything else is a single message.
  Iterable<Message> _replayMessages(ChatTurn turn) {
    if (turn.isTool) {
      // Error/skipped rows carry their `{error: …}` result so the model remembers failures
      // honestly (data-model §3). The raw-JSON reconstruction is the pure, unit-tested helper.
      return [
        Message.toolCall(
          text: reconstructToolCallJson(
            turn.toolName!,
            turn.toolArgs ?? const {},
          ),
        ),
        Message.toolResponse(
          toolName: turn.toolName!,
          response: turn.toolResult ?? const {},
        ),
      ];
    }
    return [_toPluginMessage(turn)];
  }

  /// Map a non-tool history [turn] to the plugin's `Message`, carrying its image or clip when
  /// present (003 guarantee 16).
  Message _toPluginMessage(ChatTurn turn) {
    final image = turn.image;
    final audio = turn.audio;
    if (audio != null) {
      if (turn.text.isEmpty) {
        return Message.audioOnly(audioBytes: audio.bytes, isUser: turn.isUser);
      }
      return Message.withAudio(
        text: turn.text,
        audioBytes: audio.bytes,
        isUser: turn.isUser,
      );
    }
    if (image == null) {
      return Message.text(text: turn.text, isUser: turn.isUser);
    }
    if (turn.text.isEmpty) {
      return Message.imageOnly(imageBytes: image.bytes, isUser: turn.isUser);
    }
    return Message.withImage(
      text: turn.text,
      imageBytes: image.bytes,
      isUser: turn.isUser,
    );
  }

  /// Build the current prompt message: text-only, media+text, or media-only (empty text, FR-004).
  Message _promptMessage(String prompt, ImageInput? image, AudioInput? audio) {
    if (audio != null) {
      if (prompt.isEmpty) {
        return Message.audioOnly(audioBytes: audio.bytes, isUser: true);
      }
      return Message.withAudio(
        text: prompt,
        audioBytes: audio.bytes,
        isUser: true,
      );
    }
    if (image == null) {
      return Message.text(text: prompt, isUser: true);
    }
    if (prompt.isEmpty) {
      return Message.imageOnly(imageBytes: image.bytes, isUser: true);
    }
    return Message.withImage(
      text: prompt,
      imageBytes: image.bytes,
      isUser: true,
    );
  }

  @override
  Future<void> stop() async {
    // A stopped generation leaves the native context mid-turn (no end-of-turn) — unknowable from
    // here, so mark dirty: the next send resyncs with a full replay.
    _sessionEpoch++;
    _sessionTurns = null;
    _awaitingToolResult = false;
    await _chat?.stopGeneration();
  }

  @override
  Future<void> close() async {
    _sessionEpoch++;
    _sessionTurns = null;
    _awaitingToolResult = false;
    _supportsFunctionCalls = false;
    try {
      await _model?.close();
    } finally {
      _model = null;
      _chat = null;
      _loaded = false;
    }
  }
}

/// Cheap identity of one turn the native session has ingested: role + exact text + image/audio
/// byte LENGTH (stored media files are write-once, so same path ⇒ same length ⇒ same media —
/// without retaining or comparing megabytes of bytes, Principle VIII).
class _TurnFingerprint {
  const _TurnFingerprint({
    required this.isUser,
    required this.text,
    required this.imageByteLength,
    required this.audioByteLength,
  });

  _TurnFingerprint.ofTurn(ChatTurn turn)
    : this(
        isUser: turn.isUser,
        text: turn.text,
        imageByteLength: turn.image?.bytes.length,
        audioByteLength: turn.audio?.bytes.length,
      );

  final bool isUser;
  final String text;
  final int? imageByteLength;
  final int? audioByteLength;

  @override
  bool operator ==(Object other) =>
      other is _TurnFingerprint &&
      other.isUser == isUser &&
      other.text == text &&
      other.imageByteLength == imageByteLength &&
      other.audioByteLength == audioByteLength;

  @override
  int get hashCode =>
      Object.hash(isUser, text, imageByteLength, audioByteLength);
}

/// Kept-alive [GemmaService] (R5) — never auto-disposed, so the ~2.4 GB model doesn't thrash on
/// rebuilds. The model is loaded/released explicitly by the chat session lifecycle.
final gemmaServiceProvider = Provider<GemmaService>((ref) {
  final service = FlutterGemmaService();
  ref.onDispose(service.close);
  return service;
});

bool _logFilterInstalled = false;

/// Silence flutter_gemma's hot-path log spam: the plugin `debugPrint`s several lines PER TOKEN
/// while streaming, and dumps the ENTIRE accumulated history per ingested chunk — in release
/// builds too (`debugPrint` is not compiled out). Installed once from `main()`; everything not
/// matching the plugin's known prefixes passes through untouched.
void installGemmaLogFilter() {
  if (_logFilterInstalled) return;
  _logFilterInstalled = true;
  final DebugPrintCallback base = debugPrint;
  debugPrint = (String? message, {int? wrapWidth}) {
    if (message != null && _isGemmaLogNoise(message)) return;
    base(message, wrapWidth: wrapWidth);
  };
}

/// Prefixes of flutter_gemma 0.15.3's per-token / per-chunk log lines.
bool _isGemmaLogNoise(String message) =>
    message.startsWith('InferenceChat:') ||
    message.startsWith('[MobileSession') ||
    message.startsWith('--- Sending to Native ---') ||
    message.startsWith('History:') ||
    message.startsWith('Current Message:') ||
    message.startsWith('-------------------------') ||
    message.startsWith('ImageProcessor:');
