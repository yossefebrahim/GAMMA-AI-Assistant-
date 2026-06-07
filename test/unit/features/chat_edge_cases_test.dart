import 'package:ai_assistant/data/repositories/drift_conversation_repository.dart';
import 'package:ai_assistant/domain/entities/message.dart';
import 'package:ai_assistant/domain/repositories/conversation_repository.dart';
import 'package:ai_assistant/features/chat/chat_controller.dart';
import 'package:ai_assistant/infrastructure/gemma/flutter_gemma_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/container_harness.dart';
import '../../helpers/fake_gemma_service.dart';

/// Polish T049 — chat edge cases (spec Edge Cases): empty send + stop-before-first-token.
void main() {
  late FakeGemmaService gemma;
  late ProviderContainer container;

  setUp(() {
    gemma = FakeGemmaService();
    container = makeContainer(
      overrides: [gemmaServiceProvider.overrideWithValue(gemma)],
    );
  });

  tearDown(() => container.dispose());

  ConversationRepository repo() => container.read(conversationRepositoryProvider);

  test('empty / whitespace send is a no-op — no conversation is created', () async {
    await container.read(chatControllerProvider.notifier).send('   ');
    expect(container.read(chatControllerProvider).conversationId, isNull);
  });

  test('stop before the first token yields an empty stoppedPartial turn', () async {
    gemma
      ..scriptedDeltas = ['too late']
      ..deltaInterval = const Duration(milliseconds: 200);

    final sending = container.read(chatControllerProvider.notifier).send('hi');
    await Future<void>.delayed(const Duration(milliseconds: 10)); // before any token
    await container.read(chatControllerProvider.notifier).stop();
    await sending;

    final conversationId = container.read(chatControllerProvider).conversationId!;
    final assistant =
        (await repo().loadTurns(conversationId)).firstWhere((m) => m.role == MessageRole.assistant);
    expect(assistant.status, MessageStatus.stoppedPartial);
    expect(assistant.content, isEmpty);
  });
}
