import 'package:ai_assistant/app/theme/app_theme.dart';
import 'package:ai_assistant/domain/entities/image_attachment.dart';
import 'package:ai_assistant/domain/entities/message.dart';
import 'package:ai_assistant/features/chat/widgets/message_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// US1 in-bubble image rendering (FR-012). A user message carrying an image renders it in place,
/// above any text, with a screen-reader label (Principle VI).
void main() {
  Widget host(Message message) => MaterialApp(
        theme: AppTheme.light,
        darkTheme: AppTheme.dark,
        themeMode: ThemeMode.dark,
        home: Scaffold(body: MessageBubble(message: message)),
      );

  Message imageMessage({String content = 'look at this'}) => Message(
        id: 1,
        conversationId: 1,
        role: MessageRole.user,
        content: content,
        sequence: 0,
        createdAt: DateTime.utc(2026, 6, 8),
        status: MessageStatus.complete,
        image: const ImageAttachment(path: '/tmp/fake-bubble.jpg', mimeType: 'image/jpeg'),
      );

  testWidgets('a user message with an image renders the image in place (FR-012)', (tester) async {
    await tester.pumpWidget(host(imageMessage()));
    await tester.pump();

    expect(find.byType(Image), findsOneWidget);
    expect(find.bySemanticsLabel('attached image'), findsOneWidget);
    expect(find.text('look at this'), findsOneWidget);
  });

  testWidgets('an image-only message (empty text) still renders the image (FR-004/FR-012)',
      (tester) async {
    await tester.pumpWidget(host(imageMessage(content: '')));
    await tester.pump();

    expect(find.byType(Image), findsOneWidget);
    expect(find.bySemanticsLabel('attached image'), findsOneWidget);
  });
}
