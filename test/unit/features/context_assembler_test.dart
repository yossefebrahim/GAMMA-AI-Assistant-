import 'package:ai_assistant/domain/entities/chat_turn.dart';
import 'package:ai_assistant/domain/entities/message.dart';
import 'package:ai_assistant/features/chat/context_assembler.dart';
import 'package:flutter_test/flutter_test.dart';

/// US3 context assembler (FR-017, Q2) — pure logic, no repo/db.
void main() {
  Message msg(
    int id,
    MessageRole role,
    String content, {
    MessageStatus status = MessageStatus.complete,
  }) {
    return Message(
      id: id,
      conversationId: 1,
      role: role,
      content: content,
      sequence: id,
      createdAt: DateTime.utc(2026, 6, 7, 0, 0, id),
      status: status,
    );
  }

  test(
    'includes prior turns in order, including a stopped-partial turn (FR-017)',
    () {
      final messages = [
        msg(1, MessageRole.user, 'what is the capital of france'),
        msg(2, MessageRole.assistant, 'paris'),
        msg(3, MessageRole.user, 'and its population'),
        msg(
          4,
          MessageRole.assistant,
          'about two',
          status: MessageStatus.stoppedPartial,
        ),
      ];

      final context = const ContextAssembler().assemble(messages);

      expect(context, const [
        ChatTurn(isUser: true, text: 'what is the capital of france'),
        ChatTurn(isUser: false, text: 'paris'),
        ChatTurn(isUser: true, text: 'and its population'),
        ChatTurn(
          isUser: false,
          text: 'about two',
        ), // stopped-partial is included
      ]);
    },
  );

  test('skips an empty streaming placeholder turn', () {
    final messages = [
      msg(1, MessageRole.user, 'hi'),
      msg(2, MessageRole.assistant, '', status: MessageStatus.streaming),
    ];

    final context = const ContextAssembler().assemble(messages);

    expect(context, const [ChatTurn(isUser: true, text: 'hi')]);
  });

  test(
    'on overflow, drops the OLDEST turns only; stored history is untouched (Q2)',
    () {
      // ~4 chars/token → 20-char turns cost ~5 tokens, 4-char turn costs ~1.
      const assembler = ContextAssembler(maxContextTokens: 7);
      final messages = [
        msg(1, MessageRole.user, 'a' * 20),
        msg(2, MessageRole.assistant, 'b' * 20),
        msg(3, MessageRole.user, 'cccc'),
      ];
      final snapshot = List<Message>.of(messages);

      final context = assembler.assemble(messages);

      // Oldest (turn 1) dropped; the two most recent kept, in order.
      expect(context.map((t) => t.text).toList(), ['b' * 20, 'cccc']);
      // The stored message list was not mutated.
      expect(messages, snapshot);
    },
  );
}
