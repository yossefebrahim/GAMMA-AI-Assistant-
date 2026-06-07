import 'package:ai_assistant/data/repositories/drift_conversation_repository.dart';
import 'package:ai_assistant/domain/entities/conversation.dart';
import 'package:ai_assistant/features/chat/chat_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Reactive conversation list, most-recently-updated first (FR-020). Updates live on any
/// create/delete/new-message via drift's `.watch`.
final conversationsProvider = StreamProvider.autoDispose<List<Conversation>>((ref) {
  return ref.watch(conversationRepositoryProvider).watchConversations();
});

/// Actions for the history surface (FR-019/FR-020/FR-022). Holds no state itself — the list is
/// [conversationsProvider]; this drives new/open/delete and keeps the chat surface in sync.
class HistoryController extends Notifier<void> {
  @override
  void build() {}

  /// Start a fresh, empty thread — existing conversations are preserved (FR-019).
  void newConversation() {
    ref.read(chatControllerProvider.notifier).openConversation(null);
  }

  /// Open an existing conversation in the chat surface (FR-020).
  void openConversation(int conversationId) {
    ref.read(chatControllerProvider.notifier).openConversation(conversationId);
  }

  /// Delete a conversation and its messages (FR-022). If it was the open thread, reset chat to a
  /// fresh, empty one so the UI never points at a deleted conversation.
  Future<void> deleteConversation(int conversationId) async {
    await ref.read(conversationRepositoryProvider).deleteConversation(conversationId);
    if (ref.read(chatControllerProvider).conversationId == conversationId) {
      ref.read(chatControllerProvider.notifier).openConversation(null);
    }
  }
}

final historyControllerProvider =
    NotifierProvider<HistoryController, void>(HistoryController.new);
