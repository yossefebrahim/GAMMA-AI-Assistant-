import 'package:ai_assistant/data/repositories/drift_conversation_repository.dart';
import 'package:ai_assistant/domain/repositories/conversation_repository.dart';
import 'package:ai_assistant/features/chat/chat_controller.dart';
import 'package:ai_assistant/features/history/history_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/container_harness.dart';

/// US4 history controller (FR-019/FR-020/FR-022) over an in-memory drift DB.
void main() {
  late ProviderContainer container;

  setUp(() => container = makeContainer());
  tearDown(() => container.dispose());

  ConversationRepository repo() => container.read(conversationRepositoryProvider);
  HistoryController history() => container.read(historyControllerProvider.notifier);
  int? openConversationId() => container.read(chatControllerProvider).conversationId;

  test('newConversation resets the chat to a fresh, empty thread (FR-019)', () {
    container.read(chatControllerProvider.notifier).openConversation(99);
    history().newConversation();
    expect(openConversationId(), isNull);
  });

  test('openConversation switches the chat to the selected conversation (FR-020)', () async {
    final a = await repo().createConversation();
    await repo().appendUserMessage(a.id, 'hello from a');
    final b = await repo().createConversation();
    await repo().appendUserMessage(b.id, 'hello from b');

    history().openConversation(a.id);
    expect(openConversationId(), a.id);
    expect((await repo().loadTurns(a.id)).first.content, 'hello from a');

    history().openConversation(b.id);
    expect(openConversationId(), b.id);
  });

  test('deleteConversation removes it, cascades messages, and resets the open chat (FR-022)',
      () async {
    final a = await repo().createConversation();
    await repo().appendUserMessage(a.id, 'doomed');
    history().openConversation(a.id);
    expect(openConversationId(), a.id);

    await history().deleteConversation(a.id);

    final remaining = await repo().watchConversations().first;
    expect(remaining.where((c) => c.id == a.id), isEmpty);
    expect(await repo().loadTurns(a.id), isEmpty);
    // The chat was pointed at the deleted conversation → reset to a fresh thread.
    expect(openConversationId(), isNull);
  });
}
