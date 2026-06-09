import 'package:ai_assistant/app/theme/app_theme.dart';
import 'package:ai_assistant/features/chat/chat_controller.dart';
import 'package:ai_assistant/features/chat/chat_providers.dart';
import 'package:ai_assistant/features/chat/chat_screen.dart';
import 'package:ai_assistant/features/chat/widgets/composer.dart';
import 'package:ai_assistant/infrastructure/gemma/flutter_gemma_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/container_harness.dart';
import '../helpers/fake_gemma_service.dart';

/// US6 error message UI (FR-020, SC-008) — when generation surfaces an [ImageProcessingException]
/// the chat shows a clear, dismissible banner and the composer stays usable. Mirrors the proven
/// `chat_screen_test` harness (real in-memory drift, UI-driven send, explicit pumps); the fake maps
/// the generation to the same error the image path produces (the real image-bearing flow with file
/// I/O is covered by `chat_controller_image_error_test`).
void main() {
  late FakeGemmaService gemma;
  late ProviderContainer container;

  setUp(() {
    gemma = FakeGemmaService()..throwImageProcessing = true;
    container = makeContainer(
      overrides: [
        gemmaServiceProvider.overrideWithValue(gemma),
        modelSessionProvider.overrideWith((ref) => gemma),
      ],
    );
  });

  tearDown(() => container.dispose());

  Widget app() => UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light,
          darkTheme: AppTheme.dark,
          themeMode: ThemeMode.dark,
          home: const ChatScreen(),
        ),
      );

  testWidgets('an unprocessable input shows a dismissible message; the composer stays usable '
      '(FR-020, SC-008)', (tester) async {
    await tester.pumpWidget(app());
    await tester.pump(); // resolve the model session

    await tester.enterText(find.byKey(Composer.fieldKey), 'what is this');
    await tester.pump();
    await tester.tap(find.byKey(Composer.sendKey));
    await tester.pump(); // drain the send → ImageProcessingException → error state
    await tester.pump(const Duration(milliseconds: 350)); // drain the scroll animation

    // A clear error banner appears with the message.
    expect(find.byKey(ChatScreen.errorBannerKey), findsOneWidget);
    expect(find.text(ChatController.imageErrorMessage), findsOneWidget);

    // It is dismissible.
    await tester.tap(find.byKey(ChatScreen.errorDismissKey));
    await tester.pump();
    expect(find.byKey(ChatScreen.errorBannerKey), findsNothing);

    // The composer stays usable — chat never dead-ends (FR-011/FR-020).
    expect(find.byKey(Composer.fieldKey), findsOneWidget);
    await tester.enterText(find.byKey(Composer.fieldKey), 'still works');
    await tester.pump();
    expect(tester.widget<IconButton>(find.byKey(Composer.sendKey)).onPressed, isNotNull);
  }, timeout: const Timeout(Duration(seconds: 60)));
}
