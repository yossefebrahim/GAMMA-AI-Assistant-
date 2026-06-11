import 'package:ai_assistant/domain/entities/audio_attachment.dart';
import 'package:ai_assistant/domain/entities/image_attachment.dart';
import 'package:ai_assistant/domain/entities/tool_outcome.dart';
import 'package:meta/meta.dart';

/// Who produced a turn. `tool` (004) is a persisted invocation row rendered as a chip.
enum MessageRole { user, assistant, tool }

/// Lifecycle of an assistant turn (user turns are always [complete]).
enum MessageStatus {
  /// Generation finished normally.
  complete,

  /// Currently being generated; `content` grows as deltas arrive.
  streaming,

  /// User pressed stop; `content` retains all text produced up to that instant (FR-014) and the
  /// turn is treated as completed for context assembly (FR-017).
  stoppedPartial,
}

/// One turn within a conversation (FR-012…FR-014, FR-017). Persisted in the `messages` table.
///
/// A user turn carries at most ONE attachment: `image == null || audio == null` (spec 003 Q3 —
/// audio XOR image), enforced upstream by the attachment controller and validated by
/// `appendUserMessage`. Assistant turns never carry media.
///
/// A **tool** turn (004) carries `toolName`/`toolStatus` (and, once dispatched, `toolArgs`/
/// `toolResult`); its `content` is the chip's quiet one-line summary (display only, never fed to
/// the model). Tool turns never carry image/audio. The all-null-vs-non-null split is the same XOR
/// discipline as the 003 attachment fields, enforced at the repository boundary.
@immutable
class Message {
  const Message({
    required this.id,
    required this.conversationId,
    required this.role,
    required this.content,
    required this.sequence,
    required this.createdAt,
    required this.status,
    this.image,
    this.audio,
    this.toolName,
    this.toolArgs,
    this.toolStatus,
    this.toolResult,
  });

  final int id;
  final int conversationId;
  final MessageRole role;

  /// User: non-empty after trim **or** an attachment is present (FR-004). Assistant: may be empty
  /// only transiently while generating. Tool: the chip's quiet summary line (lowercase microcopy).
  final String content;

  /// Monotonic per conversation; defines turn order.
  final int sequence;

  final DateTime createdAt;

  /// Meaningful for assistant turns; user turns are always [MessageStatus.complete]. Tool rows are
  /// `complete` on the streaming axis — their lifecycle lives in [toolStatus], not here.
  final MessageStatus status;

  /// The image attached to this turn (FR-012). Non-null only on user turns that included an image.
  final ImageAttachment? image;

  /// The voice clip attached to this turn (003 FR-018). Non-null only on user turns; exclusive
  /// with [image].
  final AudioAttachment? audio;

  /// The model-facing tool name (004). Non-null iff [role] == [MessageRole.tool].
  final String? toolName;

  /// The model's arguments as validated/attempted (004). Present on tool rows (may be empty).
  final Map<String, Object?>? toolArgs;

  /// The invocation lifecycle state (004). Non-null iff [role] == [MessageRole.tool].
  final ToolCallStatus? toolStatus;

  /// The result on success, or `{error: reason}` otherwise (004). Null while `running`/`skipped`
  /// has no payload.
  final Map<String, Object?>? toolResult;

  bool get isUser => role == MessageRole.user;

  /// Whether this is a tool-invocation row (004) — rendered as a chip, not a bubble.
  bool get isTool => role == MessageRole.tool;

  /// The repository-enforced field invariant (004 data-model §1 / contract guarantee 1; mirrors
  /// the 003 attachment XOR). True when the tool fields are consistent with the role: a tool row
  /// has `toolName` + `toolStatus` and no media; a non-tool row has no tool fields.
  bool get hasValidToolInvariant {
    if (role == MessageRole.tool) {
      return toolName != null &&
          toolStatus != null &&
          image == null &&
          audio == null;
    }
    return toolName == null &&
        toolArgs == null &&
        toolStatus == null &&
        toolResult == null;
  }

  Message copyWith({
    String? content,
    MessageStatus? status,
    ImageAttachment? image,
    AudioAttachment? audio,
    String? toolName,
    Map<String, Object?>? toolArgs,
    ToolCallStatus? toolStatus,
    Map<String, Object?>? toolResult,
  }) {
    return Message(
      id: id,
      conversationId: conversationId,
      role: role,
      content: content ?? this.content,
      sequence: sequence,
      createdAt: createdAt,
      status: status ?? this.status,
      image: image ?? this.image,
      audio: audio ?? this.audio,
      toolName: toolName ?? this.toolName,
      toolArgs: toolArgs ?? this.toolArgs,
      toolStatus: toolStatus ?? this.toolStatus,
      toolResult: toolResult ?? this.toolResult,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Message &&
      other.id == id &&
      other.conversationId == conversationId &&
      other.role == role &&
      other.content == content &&
      other.sequence == sequence &&
      other.createdAt == createdAt &&
      other.status == status &&
      other.image == image &&
      other.audio == audio &&
      other.toolName == toolName &&
      _mapEquals(other.toolArgs, toolArgs) &&
      other.toolStatus == toolStatus &&
      _mapEquals(other.toolResult, toolResult);

  @override
  int get hashCode => Object.hash(id, conversationId, role, content, sequence, createdAt, status,
      image, audio, toolName, toolStatus, _mapHash(toolArgs), _mapHash(toolResult));
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
