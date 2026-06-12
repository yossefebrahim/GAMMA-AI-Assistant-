import 'package:ai_assistant/app/theme/app_theme.dart';
import 'package:ai_assistant/domain/entities/image_attachment.dart';
import 'package:ai_assistant/domain/entities/message.dart';
import 'package:ai_assistant/domain/entities/model_capabilities.dart';
import 'package:ai_assistant/features/chat/chat_providers.dart';
import 'package:ai_assistant/features/chat/widgets/message_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// US2 history retention (FR-017) — an already-sent image still renders even when the active model
/// is text-only. The bubble renders from the stored file, NOT from current `capabilities`, so the
/// image survives a switch to an image-unsupported model.
void main() {
  testWidgets(
    'a persisted image message still renders under a text-only model (FR-017)',
    (tester) async {
      final message = Message(
        id: 1,
        conversationId: 1,
        role: MessageRole.user,
        content: 'what is this?',
        sequence: 0,
        createdAt: DateTime.utc(2026, 6, 8),
        status: MessageStatus.complete,
        image: const ImageAttachment(
          path: '/tmp/persisted.jpg',
          mimeType: 'image/jpeg',
        ),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            // The active model is text-only — yet the persisted image must still show.
            modelCapabilitiesProvider.overrideWith(
              (ref) => const ModelCapabilities(image: false),
            ),
          ],
          child: MaterialApp(
            theme: AppTheme.light,
            darkTheme: AppTheme.dark,
            themeMode: ThemeMode.dark,
            home: Scaffold(body: MessageBubble(message: message)),
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(Image), findsOneWidget);
      expect(find.bySemanticsLabel('attached image'), findsOneWidget);
      expect(find.text('what is this?'), findsOneWidget);
    },
  );
}
