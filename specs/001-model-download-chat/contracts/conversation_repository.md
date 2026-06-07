# Contract: ConversationRepository

**Feature**: `001-model-download-chat` | FR-017–FR-022, Principle VII

Abstraction over `drift` persistence (R3). The only seam for conversation/message storage.
`DriftConversationRepository` (in `lib/data/repositories/`) is the only file wiring drift DAOs;
controllers depend on this interface and test with an in-memory drift DB or a fake.

## Interface

```dart
abstract interface class ConversationRepository {
  /// Reactive list of conversations, most-recently-updated first (FR-020/FR-021).
  /// Emits a new value on any create/delete/new-message (drift .watch).
  Stream<List<Conversation>> watchConversations();

  /// Reactive ordered messages for a conversation (FR-020).
  Stream<List<Message>> watchMessages(int conversationId);

  /// Create a new, empty conversation and return it (FR-019).
  Future<Conversation> createConversation();

  /// Append a user message (validates non-empty after trim). Bumps updatedAt;
  /// sets the conversation title from the first message if still null (FR-021).
  Future<Message> appendUserMessage(int conversationId, String text);

  /// Create an assistant message in `streaming` state; returns its id (FR-013).
  Future<int> beginAssistantMessage(int conversationId);

  /// Replace the streaming assistant message content as deltas accumulate.
  Future<void> updateAssistantContent(int messageId, String content);

  /// Finalize an assistant message as `complete` or `stoppedPartial` (FR-014).
  Future<void> finalizeAssistantMessage(int messageId, MessageStatus status);

  /// Ordered turns for context assembly, including stopped-partial turns (FR-017).
  Future<List<Message>> loadTurns(int conversationId);

  /// Delete a conversation and cascade its messages (FR-022).
  Future<void> deleteConversation(int conversationId);
}
```

## Semantics & guarantees

| # | Behavior | Source |
|---|----------|--------|
| 1 | `watchConversations` ordered by `updatedAt DESC`; live updates with no manual invalidation. | FR-020, R3 |
| 2 | All writes/reads hit app-private OS-encrypted SQLite; no network. | FR-032, Principle I |
| 3 | `appendUserMessage` rejects empty/whitespace-only text. | Edge: empty send |
| 4 | First user message sets the conversation title (≤40 chars; fallback if empty). | FR-021 |
| 5 | `finalizeAssistantMessage(stoppedPartial)` keeps current content verbatim. | FR-014, SC-005 |
| 6 | `deleteConversation` cascades — messages become unretrievable. | FR-022 |
| 7 | Data survives process death/relaunch, ordering preserved. | FR-018, SC-006 |

## Test strategy

- **Repository tests**: real `drift` over `NativeDatabase.memory()` (R3) — exercises actual SQL,
  cascade, ordering, and `watch` emissions off-device.
- **Controller tests**: a lightweight in-memory `FakeConversationRepository` injected via Riverpod
  override, to drive chat/history controllers deterministically.
