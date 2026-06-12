part of 'package:ai_assistant/data/db/app_database.dart';

/// Drift query primitives for conversations + messages (R3). Reactive `watch*` queries drive the
/// reactive UI with no manual invalidation; the repository layer maps these rows to domain
/// entities and owns the higher-level rules (title derivation, sequencing, updatedAt bumps).
@DriftAccessor(tables: [Conversations, Messages])
class ConversationDao extends DatabaseAccessor<AppDatabase>
    with _$ConversationDaoMixin {
  ConversationDao(super.db);

  /// Conversations most-recently-updated first; id desc breaks ties so ordering is deterministic
  /// even when two rows share an `updatedAt` (FR-020).
  Stream<List<ConversationRow>> watchConversations() {
    return (select(conversations)..orderBy([
          (c) => OrderingTerm(expression: c.updatedAt, mode: OrderingMode.desc),
          (c) => OrderingTerm(expression: c.id, mode: OrderingMode.desc),
        ]))
        .watch();
  }

  /// Messages for a conversation in turn order (FR-020).
  Stream<List<MessageRow>> watchMessages(int conversationId) {
    return (select(messages)
          ..where((m) => m.conversationId.equals(conversationId))
          ..orderBy([(m) => OrderingTerm(expression: m.sequence)]))
        .watch();
  }

  /// One-shot ordered read for context assembly (FR-017).
  Future<List<MessageRow>> messagesFor(int conversationId) {
    return (select(messages)
          ..where((m) => m.conversationId.equals(conversationId))
          ..orderBy([(m) => OrderingTerm(expression: m.sequence)]))
        .get();
  }

  /// Next monotonic sequence for a conversation (max + 1, or 0 for the first message).
  Future<int> nextSequence(int conversationId) async {
    final maxSeq = messages.sequence.max();
    final query = selectOnly(messages)
      ..addColumns([maxSeq])
      ..where(messages.conversationId.equals(conversationId));
    final row = await query.getSingleOrNull();
    return (row?.read(maxSeq) ?? -1) + 1;
  }

  Future<int> insertConversation(ConversationsCompanion entry) =>
      into(conversations).insert(entry);

  Future<ConversationRow> conversationById(int id) =>
      (select(conversations)..where((c) => c.id.equals(id))).getSingle();

  /// Bump `updatedAt` and, optionally, set the derived title (only passed when it should change).
  Future<void> touchConversation(int id, DateTime updatedAt, {String? title}) {
    return (update(conversations)..where((c) => c.id.equals(id))).write(
      ConversationsCompanion(
        updatedAt: Value(updatedAt),
        title: title == null ? const Value.absent() : Value(title),
      ),
    );
  }

  Future<int> insertMessage(MessagesCompanion entry) =>
      into(messages).insert(entry);

  Future<MessageRow> messageById(int id) =>
      (select(messages)..where((m) => m.id.equals(id))).getSingle();

  Future<void> writeMessage(int id, MessagesCompanion entry) =>
      (update(messages)..where((m) => m.id.equals(id))).write(entry);

  /// All tool-invocation rows still in the transient `running` state (004) — the startup/open
  /// sweep finalizes these to `error('interrupted')` so reopened history never shows an in-flight
  /// chip (data-model §4).
  Future<List<MessageRow>> runningToolMessages() {
    return (select(
          messages,
        )..where((m) => m.role.equals('tool') & m.toolStatus.equals('running')))
        .get();
  }

  /// Deletes the conversation; messages cascade via the FK (FR-022).
  Future<int> deleteConversationById(int id) =>
      (delete(conversations)..where((c) => c.id.equals(id))).go();

  /// Delete a single message row (004 — the controller's ordering rule drops an EMPTY streaming
  /// assistant row before a tool chip so history reads user → chip → answer).
  Future<int> deleteMessageById(int id) =>
      (delete(messages)..where((m) => m.id.equals(id))).go();
}
