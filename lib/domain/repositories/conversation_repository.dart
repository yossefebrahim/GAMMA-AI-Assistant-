import 'package:ai_assistant/domain/entities/audio_attachment.dart';
import 'package:ai_assistant/domain/entities/conversation.dart';
import 'package:ai_assistant/domain/entities/image_attachment.dart';
import 'package:ai_assistant/domain/entities/message.dart';
import 'package:ai_assistant/domain/entities/tool_outcome.dart';
import 'package:ai_assistant/domain/entities/web_access_override.dart';

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

  /// Append a user message, optionally with an [image] (FR-012) or an [audio] clip (003 FR-018).
  /// Validates that the message has non-empty text after trim **OR** an attachment (FR-004) —
  /// throws [ArgumentError] when all are empty — and that at most ONE of [image]/[audio] is given
  /// (audio XOR image, 003 spec Q3) — throws [ArgumentError] on both. When an attachment is given,
  /// its bytes have already been persisted to app-private storage by the caller
  /// (`ImageFileStore`/`AudioFileStore`) and its `path` is the STORED path. Bumps `updatedAt`;
  /// sets the conversation title from the first message's text if still null, falling back to a
  /// label for an attachment-only first message (FR-021).
  Future<Message> appendUserMessage(
    int conversationId,
    String text, {
    ImageAttachment? image,
    AudioAttachment? audio,
  });

  /// Create an assistant message in `streaming` state; returns its id (FR-013).
  Future<int> beginAssistantMessage(int conversationId);

  /// Delete a single message by id (004 — the controller's tool-turn ordering rule drops an EMPTY
  /// streaming assistant row before inserting the tool chip so history reads user → chip → answer,
  /// data-model §4).
  Future<void> deleteMessage(int messageId);

  /// Replace the streaming assistant message content as deltas accumulate.
  Future<void> updateAssistantContent(int messageId, String content);

  /// Finalize an assistant message as `complete` or `stoppedPartial` (FR-014). For
  /// [MessageStatus.stoppedPartial] the current content is kept verbatim (SC-005).
  Future<void> finalizeAssistantMessage(int messageId, MessageStatus status);

  /// Ordered turns for context assembly, including stopped-partial turns (FR-017).
  Future<List<Message>> loadTurns(int conversationId);

  /// Append a tool-invocation row in `running` state at the next sequence (004 contract
  /// conversation_repository.md). Returns its message id. Throws [ArgumentError] on the field
  /// invariants (empty [toolName]). The row's `content` (chip summary) is set on
  /// [finalizeToolInvocation].
  Future<int> appendToolInvocation({
    required int conversationId,
    required String toolName,
    required Map<String, Object?> args,
  });

  /// Finalize a tool invocation to a TERMINAL state (`success` | `error` | `skipped`) with its
  /// bounded result/error payload and the chip's one-line [summary] (004). Rejects
  /// [ToolCallStatus.running] with [ArgumentError] (guarantee 2); rejects a [result] JSON over the
  /// 4,400-char absolute ceiling (guarantee 4).
  Future<void> finalizeToolInvocation(
    int messageId, {
    required ToolCallStatus status,
    Map<String, Object?>? result,
    required String summary,
  });

  /// Finalize any stale `running` tool rows to `error('interrupted')` (004 data-model §4 terminal-
  /// state guarantee). Called at conversation open / startup — mirrors the existing stale-
  /// `streaming` finalization so reopened history never shows an in-flight chip. Returns the count
  /// swept.
  Future<int> sweepStaleToolInvocations();

  /// Read the per-conversation web-access override (006, FR-007). Returns `null` (the `inherit`
  /// state) when the conversation does not exist or stores NULL. Used by
  /// `conversationWebOverrideProvider` to seed the per-conversation quick toggle.
  Future<WebAccessOverride?> readWebAccessOverride(int conversationId);

  /// Persist the per-conversation web-access override (006, FR-007). `null` writes NULL (inherit);
  /// [WebAccessOverride.on] / [WebAccessOverride.off] write `'on'` / `'off'`. The controller calls
  /// `GemmaService.startSession` with the recomputed tool list after persisting (FR-032).
  Future<void> setWebAccessOverride(
    int conversationId,
    WebAccessOverride? override,
  );

  /// Delete a conversation: removes its image AND audio files (FR-019; 003
  /// contracts/conversation_repository.md #3 — file cleanup happens BEFORE the cascading row
  /// delete, since after the cascade the paths are unknowable), then deletes the row so its
  /// messages cascade, making them unretrievable (FR-022). No orphaned media files remain from
  /// this path.
  Future<void> deleteConversation(int conversationId);
}
