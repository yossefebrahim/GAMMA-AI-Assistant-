import 'package:ai_assistant/app/theme/app_theme.dart';
import 'package:ai_assistant/domain/entities/audio_attachment.dart';
import 'package:ai_assistant/domain/entities/message.dart';
import 'package:ai_assistant/domain/entities/model_capabilities.dart';
import 'package:ai_assistant/features/chat/chat_providers.dart';
import 'package:ai_assistant/features/chat/recording_controller.dart';
import 'package:ai_assistant/features/chat/widgets/audio_chip.dart';
import 'package:ai_assistant/features/chat/widgets/composer.dart';
import 'package:ai_assistant/features/chat/widgets/message_bubble.dart';
import 'package:ai_assistant/infrastructure/media/permission_handler_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// StateProvider lives in the legacy entrypoint in Riverpod 3 — fine for a test toggle.
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/container_harness.dart';
import '../helpers/fake_audio_preview_player.dart';
import '../helpers/fake_audio_recorder_service.dart';
import '../helpers/fake_media_permission_service.dart';

/// US2 audio capability gating (003 FR-006…FR-009, SC-002) — the mic tracks `capabilities.audio`
/// as DATA and flips live on a model switch with NO restart; while the session is merely
/// loading/failed there is no mic AND no misleading "does not accept audio" note (the 002
/// loading-vs-text-only conflation lesson); history audio chips render independent of the active
/// model's capabilities.
final _capProvider = StateProvider<ModelCapabilities>(
  (ref) => const ModelCapabilities(image: true, audio: true),
);

void main() {
  late ProviderContainer container;

  setUp(() {
    container = makeContainer(
      overrides: [
        modelCapabilitiesProvider.overrideWith(
          (ref) => ref.watch(_capProvider),
        ),
        modelSessionReadyProvider.overrideWith((ref) => true),
        audioRecorderServiceProvider.overrideWithValue(
          FakeAudioRecorderService(),
        ),
        audioPreviewPlayerProvider.overrideWithValue(FakeAudioPreviewPlayer()),
        mediaPermissionServiceProvider.overrideWithValue(
          FakeMediaPermissionService(),
        ),
        tempFileDeleterProvider.overrideWithValue((path) async {}),
      ],
    );
  });

  tearDown(() => container.dispose());

  Widget app({Widget body = const Composer()}) => UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: ThemeMode.dark,
      home: Scaffold(body: body),
    ),
  );

  testWidgets(
    'the mic tracks capability data live — present iff audio, no restart '
    '(FR-006/FR-007/FR-008, SC-002)',
    (tester) async {
      await tester.pumpWidget(app());
      await tester.pump();
      expect(find.byKey(Composer.micKey), findsOneWidget);

      // Switch to an audio-incapable model → the mic disappears without a restart…
      container.read(_capProvider.notifier).state = const ModelCapabilities(
        image: true,
        audio: false,
      );
      await tester.pump();
      expect(find.byKey(Composer.micKey), findsNothing);

      // …while text AND image input still work (independent gates).
      expect(find.byKey(Composer.fieldKey), findsOneWidget);
      expect(find.byKey(Composer.attachKey), findsOneWidget);
      await tester.enterText(find.byKey(Composer.fieldKey), 'hello');
      await tester.pump();
      expect(
        tester.widget<IconButton>(find.byKey(Composer.sendKey)).onPressed,
        isNotNull,
      );

      // Switch back → the mic reappears live.
      container.read(_capProvider.notifier).state = const ModelCapabilities(
        image: true,
        audio: true,
      );
      await tester.pump();
      expect(find.byKey(Composer.micKey), findsOneWidget);
    },
  );

  testWidgets(
    'no mic and NO "does not accept audio" note while the session is loading '
    '(FR-009, the 002 conflation lesson)',
    (tester) async {
      // A genuinely-loading session: capabilities report text-only and ready is FALSE.
      container.read(_capProvider.notifier).state = ModelCapabilities.textOnly;
      final loadingContainer = makeContainer(
        overrides: [
          modelCapabilitiesProvider.overrideWith(
            (ref) => ModelCapabilities.textOnly,
          ),
          modelSessionReadyProvider.overrideWith((ref) => false),
          audioRecorderServiceProvider.overrideWithValue(
            FakeAudioRecorderService(),
          ),
          audioPreviewPlayerProvider.overrideWithValue(
            FakeAudioPreviewPlayer(),
          ),
          mediaPermissionServiceProvider.overrideWithValue(
            FakeMediaPermissionService(),
          ),
          tempFileDeleterProvider.overrideWithValue((path) async {}),
        ],
      );
      addTearDown(loadingContainer.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: loadingContainer,
          child: MaterialApp(
            theme: AppTheme.dark,
            themeMode: ThemeMode.dark,
            home: const Scaffold(body: Composer()),
          ),
        ),
      );
      await tester.pump();

      expect(find.byKey(Composer.micKey), findsNothing);
      expect(
        find.textContaining('does not accept audio'),
        findsNothing,
        reason:
            'a loading session must never masquerade as an audio-incapable model',
      );
      expect(find.byKey(Composer.recordingMessageKey), findsNothing);
    },
  );

  testWidgets(
    'a history audio chip renders even when the active model has audio off (FR-018)',
    (tester) async {
      container.read(_capProvider.notifier).state = ModelCapabilities.textOnly;
      final message = Message(
        id: 1,
        conversationId: 1,
        role: MessageRole.user,
        content: 'what did i say',
        sequence: 0,
        createdAt: DateTime.utc(2026, 6, 10),
        status: MessageStatus.complete,
        audio: const AudioAttachment(
          path: '/fake/audio/clip.wav',
          mimeType: 'audio/wav',
        ),
      );

      await tester.pumpWidget(app(body: MessageBubble(message: message)));
      await tester.pump();

      // The chip reads from the stored attachment, not from `capabilities` (FR-018).
      expect(find.byType(AudioChip), findsOneWidget);
    },
  );
}
