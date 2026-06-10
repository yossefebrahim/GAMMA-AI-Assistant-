import 'package:ai_assistant/app/theme/app_theme.dart';
import 'package:ai_assistant/data/repositories/drift_conversation_repository.dart';
import 'package:ai_assistant/domain/entities/message.dart';
import 'package:ai_assistant/features/chat/chat_controller.dart';
import 'package:ai_assistant/features/chat/chat_providers.dart';
import 'package:ai_assistant/features/chat/chat_screen.dart';
import 'package:ai_assistant/features/chat/recording_controller.dart';
import 'package:ai_assistant/features/chat/widgets/composer.dart';
import 'package:ai_assistant/infrastructure/gemma/flutter_gemma_service.dart';
import 'package:ai_assistant/infrastructure/media/permission_handler_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/container_harness.dart';
import '../helpers/fake_audio_preview_player.dart';
import '../helpers/fake_audio_recorder_service.dart';
import '../helpers/fake_gemma_service.dart';
import '../helpers/fake_media_permission_service.dart';

/// US6 unprocessable-clip UI (003 FR-022, SC-008): an [AudioProcessingException] finalizes the
/// turn as stopped-partial and shows the dismissible "couldn't process this audio" banner with
/// `isGenerating` reset — and (the 002 L4 regression lock) a GENERIC error on an audio-free turn
/// is NOT remapped into that banner.
void main() {
  late FakeGemmaService gemma;
  late ProviderContainer container;

  setUp(() async {
    gemma = FakeGemmaService();
    await gemma.loadModel('/fake/model');
    container = makeContainer(
      overrides: [
        gemmaServiceProvider.overrideWithValue(gemma),
        modelSessionProvider.overrideWith((ref) => gemma),
        audioRecorderServiceProvider.overrideWithValue(FakeAudioRecorderService()),
        audioPreviewPlayerProvider.overrideWithValue(FakeAudioPreviewPlayer()),
        mediaPermissionServiceProvider.overrideWithValue(FakeMediaPermissionService()),
        tempFileDeleterProvider.overrideWithValue((path) async {}),
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

  Future<void> sendText(WidgetTester tester, String text) async {
    await tester.enterText(find.byKey(Composer.fieldKey), text);
    await tester.pump();
    await tester.tap(find.byKey(Composer.sendKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
  }

  testWidgets('an AudioProcessingException shows the dismissible audio banner; the turn '
      'finalizes stopped-partial and isGenerating resets (FR-022, SC-008)', (tester) async {
    gemma.throwAudioProcessing = true;

    await tester.pumpWidget(app());
    await tester.pump();
    await sendText(tester, 'transcribe this');

    // The clear, dismissible message.
    expect(find.byKey(ChatScreen.errorBannerKey), findsOneWidget);
    expect(find.text(ChatController.audioErrorMessage), findsOneWidget);
    expect(container.read(chatControllerProvider).isGenerating, isFalse);

    // The assistant turn was finalized stopped-partial — never a hang (Principle V).
    final conversationId = container.read(chatControllerProvider).conversationId!;
    final turns =
        await container.read(conversationRepositoryProvider).loadTurns(conversationId);
    final assistant = turns.firstWhere((m) => m.role == MessageRole.assistant);
    expect(assistant.status, MessageStatus.stoppedPartial);

    // Dismissible; the composer stays usable.
    await tester.tap(find.byKey(ChatScreen.errorDismissKey));
    await tester.pump();
    expect(find.byKey(ChatScreen.errorBannerKey), findsNothing);
    await tester.enterText(find.byKey(Composer.fieldKey), 'still works');
    await tester.pump();
    expect(tester.widget<IconButton>(find.byKey(Composer.sendKey)).onPressed, isNotNull);
  }, timeout: const Timeout(Duration(seconds: 60)));

  testWidgets('a generic error on an audio-free follow-up is NOT remapped to the audio banner '
      '(002 audit L4 regression lock)', (tester) async {
    gemma.scriptedStreamError = StateError('native blew up mid-stream');

    await tester.pumpWidget(app());
    await tester.pump();
    await sendText(tester, 'plain text follow-up');

    // No audio (or image) banner — the failure is kept generic; the turn still finalizes.
    expect(find.text(ChatController.audioErrorMessage), findsNothing);
    expect(find.text(ChatController.imageErrorMessage), findsNothing);
    expect(container.read(chatControllerProvider).isGenerating, isFalse);

    final conversationId = container.read(chatControllerProvider).conversationId!;
    final turns =
        await container.read(conversationRepositoryProvider).loadTurns(conversationId);
    final assistant = turns.firstWhere((m) => m.role == MessageRole.assistant);
    expect(assistant.status, MessageStatus.stoppedPartial);
  }, timeout: const Timeout(Duration(seconds: 60)));
}
