import 'package:ai_assistant/domain/entities/audio_input.dart';
import 'package:ai_assistant/domain/entities/image_input.dart';
import 'package:meta/meta.dart';

/// A prior turn passed back to the model as context (FR-017), optionally carrying an [image] or an
/// [audio] clip so a follow-up keeps referring to earlier media without re-attaching
/// (FR-015/FR-016; 003 FR-016/FR-017).
///
/// A user turn carries **at most one** of `image`/`audio` (spec 003 Q3); assistant turns never
/// carry media. A **tool** turn (004) carries [toolName]/[toolArgs]/[toolResult] and replays as the
/// plugin's `Message.toolCall` + `Message.toolResponse` pair (data-model §3) — the app DB is the
/// source of truth since the plugin's own history omits streamed tool calls.
///
/// Deliberately minimal so the context assembler can hand the `GemmaService` an ordered,
/// sliding-window-trimmed history without leaking persistence or presentation types into the seam.
@immutable
class ChatTurn {
  const ChatTurn({
    required this.isUser,
    required this.text,
    this.image,
    this.audio,
    this.toolName,
    this.toolArgs,
    this.toolResult,
  });

  /// Convenience constructor for a user turn (optionally media-bearing).
  const ChatTurn.user(this.text, {this.image, this.audio})
      : isUser = true,
        toolName = null,
        toolArgs = null,
        toolResult = null;

  /// Convenience constructor for an assistant turn (including stopped-partial turns). Assistant
  /// turns never carry media.
  const ChatTurn.assistant(this.text)
      : isUser = false,
        image = null,
        audio = null,
        toolName = null,
        toolArgs = null,
        toolResult = null;

  /// Convenience constructor for a tool turn (004) — replayed as the plugin call+response pair.
  /// [result] is the success payload OR `{error: reason}` for error/skipped rows (context fidelity
  /// over prettiness — the model remembers failures honestly, data-model §3).
  const ChatTurn.tool({
    required String name,
    required Map<String, Object?> args,
    required Map<String, Object?> result,
  })  : isUser = false,
        text = '',
        image = null,
        audio = null,
        toolName = name,
        toolArgs = args,
        toolResult = result;

  final bool isUser;
  final String text;

  /// The image to replay with this turn (FR-015/FR-016). Null for text-only and assistant turns.
  final ImageInput? image;

  /// The voice clip to replay with this turn (003 FR-016/FR-017). Null for text-only and
  /// assistant turns; exclusive with [image].
  final AudioInput? audio;

  /// The tool name for a tool turn (004); null for user/assistant turns. When non-null this turn
  /// replays as `Message.toolCall` + `Message.toolResponse`.
  final String? toolName;

  /// The tool args for a tool turn (004) — reconstructed into the raw SDK call JSON on replay.
  final Map<String, Object?>? toolArgs;

  /// The tool result for a tool turn (004) — the `Message.toolResponse` payload on replay.
  final Map<String, Object?>? toolResult;

  /// Whether this is a tool turn (004) — drives the seam's replay expansion.
  bool get isTool => toolName != null;

  @override
  bool operator ==(Object other) =>
      other is ChatTurn &&
      other.isUser == isUser &&
      other.text == text &&
      other.image == image &&
      other.audio == audio &&
      other.toolName == toolName &&
      _mapEquals(other.toolArgs, toolArgs) &&
      _mapEquals(other.toolResult, toolResult);

  @override
  int get hashCode => Object.hash(
      isUser, text, image, audio, toolName, _mapHash(toolArgs), _mapHash(toolResult));
}

bool _mapEquals(Map<String, Object?>? a, Map<String, Object?>? b) {
  if (a == null || b == null) return a == b;
  if (a.length != b.length) return false;
  for (final entry in a.entries) {
    if (!b.containsKey(entry.key) || b[entry.key] != entry.value) return false;
  }
  return true;
}

int _mapHash(Map<String, Object?>? map) {
  if (map == null) return 0;
  var hash = 0;
  for (final entry in map.entries) {
    hash ^= Object.hash(entry.key, entry.value);
  }
  return hash;
}
