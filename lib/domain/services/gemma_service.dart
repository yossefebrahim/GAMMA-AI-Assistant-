import 'package:ai_assistant/domain/entities/audio_input.dart';
import 'package:ai_assistant/domain/entities/chat_turn.dart';
import 'package:ai_assistant/domain/entities/generation_event.dart';
import 'package:ai_assistant/domain/entities/image_input.dart';
import 'package:ai_assistant/domain/entities/model_capabilities.dart';
import 'package:ai_assistant/domain/entities/tool_spec.dart';

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

/// Thrown when a voice clip cannot be processed by the active model/device (003 FR-022, sibling of
/// [ImageProcessingException]). Narrowly scoped (contract guarantee 15 / 002 audit L4): the seam
/// remaps plugin/native errors to this type ONLY when the **current prompt** carries audio —
/// errors on turns that merely replay audio history propagate unchanged.
class AudioProcessingException implements Exception {
  const AudioProcessingException(this.message, {this.cause});
  final String message;
  final Object? cause;

  @override
  String toString() => 'AudioProcessingException: $message';
}

/// The **single** abstraction over `flutter_gemma` (Constitution Principle VII).
///
/// It is the only seam through which the rest of the app touches model loading, inference,
/// capabilities, and release. The concrete `FlutterGemmaService` (in `lib/infrastructure/gemma/`)
/// is the ONLY file permitted to import `flutter_gemma`; domain and presentation depend on this
/// interface and are unit-tested with `FakeGemmaService`. See
/// `specs/001-model-download-chat/contracts/gemma_service.md` and the 003 audio extensions in
/// `specs/003-audio-input/contracts/gemma_service.md` (guarantees 13–17).
abstract interface class GemmaService {
  /// Whether a model is currently loaded and active.
  bool get isLoaded;

  /// Capabilities of the active model; throws [StateError] if not loaded.
  ModelCapabilities get capabilities;

  /// Load the model at [filePath] (a verified, app-private `.litertlm`), configuring modality from
  /// the active model's declared [capabilities] (e.g. enable vision when `capabilities.image`,
  /// audio when `capabilities.audio` — Principle III). Releases any previously-loaded model first
  /// so exactly ONE model is active (Principle VIII). Throws [ModelLoadException] on failure.
  ///
  /// FUNCTION CALLING (004): [tools] declarations ride model load, STRUCTURALLY COUPLED to the
  /// capability — passing a non-empty [tools] while `capabilities.functionCalling == false` throws
  /// [StateError] synchronously (guarantee 18 — the spike's silent-trap closure: the plugin's FFI
  /// path injects declarations on `tools.isNotEmpty` ALONE, so a mismatch silently no-ops or spills
  /// raw JSON). The seam derives `supportsFunctionCalls` and `tools` from ONE source — there is no
  /// representable state with one but not the others.
  ///
  /// MEMORY / FACTS INJECTION (005, guarantee 26): [systemInstruction] is the fully-composed string
  /// built by `SystemInstructionComposer` (facts block + capture instruction + tool-use instruction).
  /// It is forwarded verbatim to `createChat(systemInstruction:)` → FFI `createConversation
  /// (systemMessage:)` — a TRUE native system message, never a user-turn prepend. `null` means no
  /// instruction (byte-parity guarantee 29). Composition happens OUTSIDE the seam so the seam has
  /// no ToolRegistry dependency for the instruction string.
  Future<void> loadModel(
    String filePath, {
    ModelCapabilities capabilities = ModelCapabilities.textOnly,
    List<ToolSpec> tools = const [],
    String? systemInstruction,
  });

  /// Recreate the chat with a (possibly new) [systemInstruction] WITHOUT reloading the model
  /// (005, guarantee 27). Called at each session boundary: conversation open (FR-008) and memory
  /// toggle (FR-014).
  ///
  /// Closes the current session FIRST (the FFI cached-session caveat — a second `createChat` on the
  /// same loaded model returns the cached session unless the prior one is closed; spike §1.2), then
  /// calls `createChat` on the SAME loaded [_model] with the SAME tools/capabilities and the given
  /// [systemInstruction]. Resets warm fingerprints and bumps the session epoch so the next
  /// [generate] does a full replay (no stale native context).
  ///
  /// Throws [StateError] if no model is loaded (guarantee 27).
  Future<void> startSession({String? systemInstruction});

  /// Generate a reply for [prompt] given prior [history], optionally grounded in [image] or
  /// [audio] for THIS prompt; [history] may itself contain media turns that are replayed as
  /// context (FR-015/FR-016; 003 guarantee 16). Streams incremental text deltas (FR-013 — never a
  /// single block); completes when generation ends OR when [stop] is called (partial text already
  /// emitted is retained by the caller, FR-014). Implementations MUST run inference off the UI
  /// isolate (Principle IV) and perform no network I/O (Principle I).
  ///
  /// Throws [ImageProcessingException] if the image cannot be processed (FR-020), and
  /// [AudioProcessingException] if the current prompt's clip cannot be processed (003 guarantee
  /// 15 — narrowly scoped to audio-bearing prompts).
  ///
  /// Throws [StateError] synchronously when:
  ///  * [image] is passed while `capabilities.image` is false (002 contract #12);
  ///  * [audio] is passed while `capabilities.audio` is false (003 guarantee 13 — load-bearing,
  ///    not ceremony: the plugin's FFI path SILENTLY DROPS ungated audio, so without this gate a
  ///    mis-configured load produces replies that ignore the clip with no error anywhere);
  ///  * both [image] and [audio] are non-null (003 guarantee 14 — one attachment per message,
  ///    spec Q3).
  ///
  /// The caller must gate on [capabilities] first.
  ///
  /// FUNCTION CALLING (004 R2, guarantees 19–21): the stream yields sealed [GenerationEvent]s
  /// rather than bare tokens. [TextDelta]s carry prose (the raw tool-call JSON leak is suppressed
  /// at the seam, guarantee 20 — never crosses as a delta); a [ToolCallRequested] is always the
  /// FINAL event of its stream (the plugin yields it at end-of-stream). With
  /// `functionCalling == false` the stream is byte-parity [TextDelta]s only (guarantee 19).
  Stream<GenerationEvent> generate({
    required List<ChatTurn> history,
    required String prompt,
    ImageInput? image,
    AudioInput? audio,
  });

  /// Complete the ONE allowed tool round trip of the current turn (004, guarantee 22): send the
  /// plugin the tool [result] for [toolName] and re-invoke generation on the same chat, returning
  /// the same [GenerationEvent] stream for the turn's completion. [result] is the success payload
  /// OR `{error: reason}` so the model can acknowledge a failure honestly.
  ///
  /// Valid exactly once, only after a [ToolCallRequested]-terminated [generate] stream of the same
  /// turn; otherwise throws [StateError]. A SECOND [ToolCallRequested] on the resumed stream is
  /// surfaced (for the controller to chip-and-skip, FR-006/FR-024), not executed here.
  Stream<GenerationEvent> resumeWithToolResult({
    required String toolName,
    required Map<String, Object?> result,
  });

  /// Halt the in-flight generation immediately (FR-014). Idempotent / safe if idle.
  Future<void> stop();

  /// Release the model and session, freeing memory (FR-029). Idempotent. Calling [generate]
  /// after [close] throws [StateError].
  Future<void> close();
}
