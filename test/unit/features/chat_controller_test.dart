import 'package:ai_assistant/data/repositories/drift_conversation_repository.dart';
import 'package:ai_assistant/domain/entities/message.dart';
import 'package:ai_assistant/domain/repositories/conversation_repository.dart';
import 'package:ai_assistant/features/chat/chat_controller.dart';
import 'package:ai_assistant/infrastructure/gemma/flutter_gemma_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/container_harness.dart';
import '../../helpers/fake_gemma_service.dart';

/// US2 chat controller (FR-012–FR-014, SC-005, Q4) — driven by [FakeGemmaService] over an
/// in-memory drift DB. No native plugin, no device.
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

  ChatController controller() => container.read(chatControllerProvider.notifier);
  ChatState read() => container.read(chatControllerProvider);
  ConversationRepository repo() => container.read(conversationRepositoryProvider);

  test('send persists the user turn and streams a complete assistant reply (FR-013)', () async {
    gemma.scriptedDeltas = ['Hello', ', ', 'world'];

    await controller().send('hi there');

    final conversationId = read().conversationId!;
    final turns = await repo().loadTurns(conversationId);
    expect(turns, hasLength(2));
    expect(turns[0].role, MessageRole.user);
    expect(turns[0].content, 'hi there');
    expect(turns[1].role, MessageRole.assistant);
    expect(turns[1].content, 'Hello, world');
    expect(turns[1].status, MessageStatus.complete);
    expect(read().isGenerating, isFalse);
    // The prompt is passed separately; history excludes it (first turn → empty history).
    expect(gemma.lastPrompt, 'hi there');
    expect(gemma.lastHistory, isEmpty);
  });

  test('stop retains the partial reply as stoppedPartial (FR-014/SC-005)', () async {
    gemma.scriptedDeltas = ['aa', 'bb', 'cc', 'dd', 'ee'];
    gemma.deltaInterval = const Duration(milliseconds: 25);

    final sending = controller().send('hi'); // not awaited — stop mid-stream
    await Future<void>.delayed(const Duration(milliseconds: 40));
    await controller().stop();
    await sending;

    final conversationId = read().conversationId!;
    final assistant =
        (await repo().loadTurns(conversationId)).firstWhere((m) => m.role == MessageRole.assistant);
    expect(assistant.status, MessageStatus.stoppedPartial);
    expect(assistant.content, isNotEmpty);
    expect(assistant.content.length, lessThan('aabbccddee'.length));
    expect(read().isGenerating, isFalse);
    expect(gemma.stopCount, 1);
  });

  test('send is ignored while already generating (Q4 single in-flight)', () async {
    gemma.scriptedDeltas = ['x', 'y', 'z', 'w'];
    gemma.deltaInterval = const Duration(milliseconds: 25);

    final first = controller().send('first');
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(read().isGenerating, isTrue);

    await controller().send('second'); // no-op while generating

    final conversationId = read().conversationId!;
    final userTurns =
        (await repo().loadTurns(conversationId)).where((m) => m.role == MessageRole.user).toList();
    expect(userTurns, hasLength(1));
    expect(userTurns.single.content, 'first');

    await controller().stop();
    await first;
  });
}
