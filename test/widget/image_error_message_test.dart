import 'dart:io';

import 'package:ai_assistant/app/theme/app_theme.dart';
import 'package:ai_assistant/data/images/image_file_store.dart';
import 'package:ai_assistant/data/repositories/drift_conversation_repository.dart';
import 'package:ai_assistant/domain/entities/model_capabilities.dart';
import 'package:ai_assistant/domain/repositories/conversation_repository.dart';
import 'package:ai_assistant/features/chat/attachment_controller.dart';
import 'package:ai_assistant/features/chat/chat_controller.dart';
import 'package:ai_assistant/features/chat/chat_providers.dart';
import 'package:ai_assistant/features/chat/chat_screen.dart';
import 'package:ai_assistant/features/chat/widgets/composer.dart';
import 'package:ai_assistant/infrastructure/gemma/flutter_gemma_service.dart';
import 'package:ai_assistant/infrastructure/media/image_picker_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fake_conversation_repository.dart';
import '../helpers/fake_gemma_service.dart';
import '../helpers/fake_media_picker_service.dart';

/// US6 error message UI (FR-020, SC-008) — an unprocessable image shows a clear, dismissible banner
/// in the chat surface and the composer stays usable. Uses a [FakeConversationRepository] (in-memory
/// streams) so the test exercises the UI without drift's reactive teardown timing.
void main() {
  late FakeGemmaService gemma;
  late FakeConversationRepository repo;
  late Directory tempDir;
  late ProviderContainer container;

  setUp(() async {
    gemma = FakeGemmaService()..throwImageProcessing = true;
    await gemma.loadModel('x', capabilities: const ModelCapabilities(image: true));
    repo = FakeConversationRepository();
    tempDir = Directory.systemTemp.createTempSync('img_err_widget_');
    container = ProviderContainer(
      overrides: [
        gemmaServiceProvider.overrideWithValue(gemma),
        modelSessionProvider.overrideWith((ref) => gemma),
        conversationRepositoryProvider.overrideWithValue(repo),
        mediaPickerServiceProvider.overrideWithValue(FakeMediaPickerService()),
        imageFileStoreProvider.overrideWithValue(
          ImageFileStore(documentsDirectory: () async => tempDir),
        ),
      ],
    );
  });

  tearDown(() async {
    await repo.dispose();
    container.dispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Widget app() => UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light,
          darkTheme: AppTheme.dark,
          themeMode: ThemeMode.dark,
          home: const ChatScreen(),
        ),
      );

  testWidgets('an unprocessable image shows a dismissible message; the composer stays usable '
      '(FR-020, SC-008)', (tester) async {
    final imgFile = File('${tempDir.path}/bad.jpg')..writeAsBytesSync([1, 2, 3, 4]);

    await tester.pumpWidget(app());
    await tester.pump(); // resolve the model session

    // Send an image the (fake) model cannot process. Real file I/O + streams run under runAsync.
    await tester.runAsync(() async {
      await container
          .read(chatControllerProvider.notifier)
          .send('what is this', image: PendingAttachment(path: imgFile.path));
    });
    await tester.pump();
    await tester.pump();

    // A clear error banner appears with the message.
    expect(find.byKey(ChatScreen.errorBannerKey), findsOneWidget);
    expect(find.text(ChatController.imageErrorMessage), findsOneWidget);

    // It is dismissible.
    await tester.tap(find.byKey(ChatScreen.errorDismissKey));
    await tester.pump();
    expect(find.byKey(ChatScreen.errorBannerKey), findsNothing);

    // The composer stays usable — text chat never dead-ends (FR-011/FR-020).
    expect(find.byKey(Composer.fieldKey), findsOneWidget);
    await tester.enterText(find.byKey(Composer.fieldKey), 'still works');
    await tester.pump();
    expect(tester.widget<IconButton>(find.byKey(Composer.sendKey)).onPressed, isNotNull);
  });
}
