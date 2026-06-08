import 'package:ai_assistant/domain/entities/conversation.dart';
import 'package:ai_assistant/domain/entities/image_attachment.dart';
import 'package:ai_assistant/domain/entities/message.dart';

/// Abstraction over `drift` persistence (R3) — the only seam for conversation/message storage.
///
/// `DriftConversationRepository` (in `lib/data/repositories/`) is the only file wiring drift DAOs;
/// controllers depend on this interface and test with an in-memory drift DB or a fake. All
/// reads/writes hit app-private OS-encrypted SQLite — never the network (Principle I). See
/// `specs/001-model-download-chat/contracts/conversation_repository.md`.
abstract interface class ConversationRepository {
  /// Reactive list of conversations, most-recently-updated first (FR-020/FR-021). Emits a new
  /// value on any create/delete/new-message (drift `.watch`).
  Stream<List<Conversation>> watchConversations();

  /// Reactive ordered messages for a conversation (FR-020).
  Stream<List<Message>> watchMessages(int conversationId);

  /// Create a new, empty conversation and return it (FR-019).
  Future<Conversation> createConversation();

  /// Append a user message, optionally with an [image] (FR-012). Validates that the message has
  /// non-empty text after trim **OR** an image (FR-004) — throws [ArgumentError] when both are
  /// empty. When [image] is given, its bytes have already been persisted to app-private storage by
  /// the caller (`ImageFileStore`) and `image.path` is the STORED path. Bumps `updatedAt`; sets the
  /// conversation title from the first message's text if still null, falling back to a label for an
  /// image-only first message (FR-021).
  Future<Message> appendUserMessage(
    int conversationId,
    String text, {
    ImageAttachment? image,
  });

  /// Create an assistant message in `streaming` state; returns its id (FR-013).
  Future<int> beginAssistantMessage(int conversationId);

  /// Replace the streaming assistant message content as deltas accumulate.
  Future<void> updateAssistantContent(int messageId, String content);

  /// Finalize an assistant message as `complete` or `stoppedPartial` (FR-014). For
  /// [MessageStatus.stoppedPartial] the current content is kept verbatim (SC-005).
  Future<void> finalizeAssistantMessage(int messageId, MessageStatus status);

  /// Ordered turns for context assembly, including stopped-partial turns (FR-017).
  Future<List<Message>> loadTurns(int conversationId);

  /// Delete a conversation: removes its image files (FR-019), then deletes the row so its messages
  /// cascade, making them unretrievable (FR-022). No orphaned image files remain.
  Future<void> deleteConversation(int conversationId);
}
