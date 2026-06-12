import 'package:ai_assistant/app/theme/app_theme.dart';
import 'package:ai_assistant/domain/entities/model_capabilities.dart';
import 'package:ai_assistant/domain/services/audio_recorder_service.dart';
import 'package:ai_assistant/domain/services/media_permission_service.dart';
import 'package:ai_assistant/features/chat/chat_providers.dart';
import 'package:ai_assistant/features/chat/recording_controller.dart';
import 'package:ai_assistant/features/chat/widgets/composer.dart';
import 'package:ai_assistant/infrastructure/media/permission_handler_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/container_harness.dart';
import '../helpers/fake_audio_preview_player.dart';
import '../helpers/fake_audio_recorder_service.dart';
import '../helpers/fake_media_permission_service.dart';

/// US4 mic permission decision tree (003 FR-010…FR-012, SC-007), scripted through
/// [FakeMediaPermissionService]: request on first tap only (never at build), denied → explainer
/// with re-request, permanently denied → explainer with open-settings and NO grant button,
/// restricted → explainer; dismissing always returns a fully usable composer.
void main() {
  late FakeMediaPermissionService permission;
  late FakeAudioRecorderService recorder;
  late ProviderContainer container;

  setUp(() {
    permission = FakeMediaPermissionService();
    recorder = FakeAudioRecorderService();
    container = makeContainer(
      overrides: [
        mediaPermissionServiceProvider.overrideWithValue(permission),
        audioRecorderServiceProvider.overrideWithValue(recorder),
        audioPreviewPlayerProvider.overrideWithValue(FakeAudioPreviewPlayer()),
        modelCapabilitiesProvider.overrideWith(
          (ref) => const ModelCapabilities(image: true, audio: true),
        ),
        modelSessionReadyProvider.overrideWith((ref) => true),
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
      home: const Scaffold(body: Composer()),
    ),
  );

  testWidgets('no permission call fires at build — first-use only (FR-010)', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    await tester.pump();

    expect(permission.micStatusCalls, 0);
    expect(permission.micRequestCalls, 0);
  });

  testWidgets('granted → recording starts with no explainer', (tester) async {
    recorder.nextStop = const RecordedAudio(
      path: '/fake/tmp/x.wav',
      mimeType: 'audio/wav',
      durationMs: 1000,
    );
    await tester.pumpWidget(app());
    await tester.pump();

    await tester.tap(find.byKey(Composer.micKey));
    await tester.pump();

    expect(find.byKey(Composer.recordStopKey), findsOneWidget);
    expect(find.byKey(Composer.micPermissionExplainerKey), findsNothing);
    // Cleanly stop so no timers leak from the test.
    await tester.tap(find.byKey(Composer.recordStopKey));
    await tester.pump();
  });

  testWidgets('denied → request → granted records (FR-010)', (tester) async {
    permission
      ..micStatusValue = MediaPermissionStatus.denied
      ..micRequestResults = [MediaPermissionStatus.granted];
    recorder.nextStop = const RecordedAudio(
      path: '/fake/tmp/x.wav',
      mimeType: 'audio/wav',
      durationMs: 1000,
    );
    await tester.pumpWidget(app());
    await tester.pump();

    await tester.tap(find.byKey(Composer.micKey));
    await tester.pump();

    expect(permission.micRequestCalls, 1);
    expect(find.byKey(Composer.recordStopKey), findsOneWidget);
    expect(find.byKey(Composer.micPermissionExplainerKey), findsNothing);
    await tester.tap(find.byKey(Composer.recordStopKey));
    await tester.pump();
  });

  testWidgets(
    'denied → request → denied shows the explainer with a re-request path (FR-011)',
    (tester) async {
      permission
        ..micStatusValue = MediaPermissionStatus.denied
        ..micRequestResults = [MediaPermissionStatus.denied];
      await tester.pumpWidget(app());
      await tester.pump();

      await tester.tap(find.byKey(Composer.micKey));
      await tester.pumpAndSettle();

      expect(find.byKey(Composer.micPermissionExplainerKey), findsOneWidget);
      expect(
        find.byKey(Composer.micPermissionGrantKey),
        findsOneWidget,
        reason: 'still askable → re-request offered',
      );
      expect(find.byKey(Composer.micPermissionDismissKey), findsOneWidget);
    },
  );

  testWidgets(
    'permanently denied → explainer WITHOUT grant but WITH open settings, which '
    'invokes the service (FR-011)',
    (tester) async {
      permission.micStatusValue = MediaPermissionStatus.permanentlyDenied;
      await tester.pumpWidget(app());
      await tester.pump();

      await tester.tap(find.byKey(Composer.micKey));
      await tester.pumpAndSettle();

      expect(find.byKey(Composer.micPermissionExplainerKey), findsOneWidget);
      expect(
        find.byKey(Composer.micPermissionGrantKey),
        findsNothing,
        reason: 'no grant path for a permanently-denied permission',
      );
      expect(find.byKey(Composer.micPermissionSettingsKey), findsOneWidget);

      await tester.tap(find.byKey(Composer.micPermissionSettingsKey));
      await tester.pumpAndSettle();
      expect(
        permission.openSettingsCalls,
        1,
        reason: 'recorded call on the seam',
      );
    },
  );

  testWidgets('restricted → explainer with no grant path (FR-011)', (
    tester,
  ) async {
    permission.micStatusValue = MediaPermissionStatus.restricted;
    await tester.pumpWidget(app());
    await tester.pump();

    await tester.tap(find.byKey(Composer.micKey));
    await tester.pumpAndSettle();

    expect(find.byKey(Composer.micPermissionExplainerKey), findsOneWidget);
    expect(find.byKey(Composer.micPermissionGrantKey), findsNothing);
    expect(find.textContaining('restricted'), findsOneWidget);
  });

  testWidgets(
    'dismissing the explainer returns a fully usable composer — declining never '
    'breaks text chat (FR-012, SC-007)',
    (tester) async {
      permission.micStatusValue = MediaPermissionStatus.permanentlyDenied;
      await tester.pumpWidget(app());
      await tester.pump();

      await tester.tap(find.byKey(Composer.micKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Composer.micPermissionDismissKey));
      await tester.pumpAndSettle();

      expect(find.byKey(Composer.micPermissionExplainerKey), findsNothing);
      expect(find.byKey(Composer.fieldKey), findsOneWidget);
      await tester.enterText(find.byKey(Composer.fieldKey), 'still works');
      await tester.pump();
      expect(
        tester.widget<IconButton>(find.byKey(Composer.sendKey)).onPressed,
        isNotNull,
      );
    },
  );
}
