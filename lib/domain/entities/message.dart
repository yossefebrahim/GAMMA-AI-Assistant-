import 'package:ai_assistant/domain/entities/image_attachment.dart';
import 'package:meta/meta.dart';

/// Who produced a turn.
enum MessageRole { user, assistant }

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
  });

  final int id;
  final int conversationId;
  final MessageRole role;

  /// User: non-empty after trim **or** an [image] is present (FR-004). Assistant: may be empty
  /// only transiently while generating.
  final String content;

  /// Monotonic per conversation; defines turn order.
  final int sequence;

  final DateTime createdAt;

  /// Meaningful for assistant turns; user turns are always [MessageStatus.complete].
  final MessageStatus status;

  /// The image attached to this turn (FR-012). Non-null only on user turns that included an image;
  /// assistant turns never carry one. Maps to the `imagePath` / `imageMimeType` columns.
  final ImageAttachment? image;

  bool get isUser => role == MessageRole.user;

  Message copyWith({String? content, MessageStatus? status, ImageAttachment? image}) {
    return Message(
      id: id,
      conversationId: conversationId,
      role: role,
      content: content ?? this.content,
      sequence: sequence,
      createdAt: createdAt,
      status: status ?? this.status,
      image: image ?? this.image,
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
      other.image == image;

  @override
  int get hashCode =>
      Object.hash(id, conversationId, role, content, sequence, createdAt, status, image);
}
