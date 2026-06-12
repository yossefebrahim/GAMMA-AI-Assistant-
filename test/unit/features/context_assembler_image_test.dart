import 'dart:typed_data';

import 'package:ai_assistant/domain/entities/image_attachment.dart';
import 'package:ai_assistant/domain/entities/image_input.dart';
import 'package:ai_assistant/domain/entities/message.dart';
import 'package:ai_assistant/features/chat/context_assembler.dart';
import 'package:flutter_test/flutter_test.dart';

/// US3 context assembler with images (FR-015/FR-016) — a prior image turn carries its image
/// forward; the sliding window still trims oldest; stored history is never mutated. Pure logic
/// (bytes are injected — no file I/O).
void main() {
  Message msg(
    int id,
    MessageRole role,
    String content, {
    ImageAttachment? image,
    MessageStatus status = MessageStatus.complete,
  }) {
    return Message(
      id: id,
      conversationId: 1,
      role: role,
      content: content,
      sequence: id,
      createdAt: DateTime.utc(2026, 6, 8, 0, 0, id),
      status: status,
      image: image,
    );
  }

  test(
    'a prior user turn with an image yields a ChatTurn carrying its image (FR-015/FR-016)',
    () {
      final messages = [
        msg(
          1,
          MessageRole.user,
          'what is this',
          image: const ImageAttachment(path: '/img/a.jpg'),
        ),
        msg(2, MessageRole.assistant, 'a cat'),
        msg(3, MessageRole.user, 'what color is it'),
      ];
      final bytes = Uint8List.fromList([1, 2, 3, 4]);

      final context = const ContextAssembler().assemble(
        messages,
        images: {1: ImageInput(bytes)},
      );

      expect(context, hasLength(3));
      expect(context[0].image, isNotNull);
      expect(context[0].image!.bytes, equals(bytes));
      expect(context[1].image, isNull); // assistant turn
      expect(context[2].image, isNull); // text-only follow-up
    },
  );

  test(
    'an image-only prior user turn (empty text) is still included with its image',
    () {
      final messages = [
        msg(
          1,
          MessageRole.user,
          '',
          image: const ImageAttachment(path: '/img/only.jpg'),
        ),
        msg(2, MessageRole.assistant, 'a landscape'),
      ];
      final bytes = Uint8List.fromList([5, 6]);

      final context = const ContextAssembler().assemble(
        messages,
        images: {1: ImageInput(bytes)},
      );

      expect(context, hasLength(2));
      expect(context[0].text, '');
      expect(context[0].image!.bytes, equals(bytes));
    },
  );

  test(
    'on overflow the OLDEST (image) turn is dropped; stored history untouched (Q2)',
    () {
      const assembler = ContextAssembler(maxContextTokens: 7);
      final messages = [
        msg(
          1,
          MessageRole.user,
          'a' * 20,
          image: const ImageAttachment(path: '/img/a.jpg'),
        ),
        msg(2, MessageRole.assistant, 'b' * 20),
        msg(3, MessageRole.user, 'cccc'),
      ];
      final snapshot = List<Message>.of(messages);

      final context = assembler.assemble(
        messages,
        images: {
          1: ImageInput(Uint8List.fromList([9])),
        },
      );

      // Oldest (turn 1, the image turn) dropped; the two most recent kept, in order.
      expect(context.map((t) => t.text).toList(), ['b' * 20, 'cccc']);
      expect(
        context.every((t) => t.image == null),
        isTrue,
        reason: 'the image turn was trimmed away',
      );
      // Stored history not mutated.
      expect(messages, snapshot);
    },
  );
}
