import 'package:ai_assistant/app/theme/app_colors.dart';
import 'package:ai_assistant/app/theme/app_theme.dart';
import 'package:ai_assistant/data/audio/audio_file_store.dart';
import 'package:ai_assistant/data/images/image_file_store.dart';
import 'package:ai_assistant/domain/services/audio_recorder_service.dart';
import 'package:ai_assistant/features/chat/chat_providers.dart';
import 'package:ai_assistant/features/chat/chat_screen.dart';
import 'package:ai_assistant/features/chat/recording_controller.dart';
import 'package:ai_assistant/features/chat/widgets/audio_chip.dart';
import 'package:ai_assistant/features/chat/widgets/composer.dart';
import 'package:ai_assistant/features/chat/widgets/recording_indicator.dart';
import 'package:ai_assistant/infrastructure/gemma/flutter_gemma_service.dart';
import 'package:ai_assistant/infrastructure/media/permission_handler_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/container_harness.dart';
import '../helpers/fake_audio_file_store.dart';
import '../helpers/fake_audio_preview_player.dart';
import '../helpers/fake_audio_recorder_service.dart';
import '../helpers/fake_gemma_service.dart';
import '../helpers/fake_media_permission_service.dart';

/// US1 composer record → chip → send flow (003 FR-001…FR-005, FR-013/FR-014, FR-028/FR-029),
/// driven via UI + pump against the seam fakes (permission overridden to granted): mic tap shows
/// the recording state (elapsed + pulse + red stop), stop shows the chip with its duration, the
/// chip plays/stops via the fake player, remove clears, and send streams the reply.
void main() {
  late FakeGemmaService gemma;
  late FakeAudioRecorderService recorder;
  late FakeAudioPreviewPlayer player;
  late ProviderContainer container;

  setUp(() async {
    gemma = FakeGemmaService();
    // Loaded fake → modelCapabilitiesProvider derives image+audio true from the session (the
    // same data path production uses, Principle III).
    await gemma.loadModel('/fake/model');
    recorder = FakeAudioRecorderService();
    player = FakeAudioPreviewPlayer();
    container = makeContainer(
      overrides: [
        gemmaServiceProvider.overrideWithValue(gemma),
        modelSessionProvider.overrideWith((ref) => gemma),
        audioRecorderServiceProvider.overrideWithValue(recorder),
        audioPreviewPlayerProvider.overrideWithValue(player),
        mediaPermissionServiceProvider.overrideWithValue(FakeMediaPermissionService()),
        // No REAL file I/O in widget tests (the fake-async zone never completes it — the 002
        // 10-minute-hang lesson): in-memory store + no-op temp deleter.
        audioFileStoreProvider.overrideWithValue(FakeAudioFileStore()),
        tempFileDeleterProvider.overrideWithValue((path) async {}),
        imageFileStoreProvider.overrideWithValue(ImageFileStore()),
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

  /// Pump repeatedly so multi-await controller chains and the throttled stream drain.
  Future<void> pumpThrough(WidgetTester tester,
      {int times = 10, Duration step = const Duration(milliseconds: 30)}) async {
    for (var i = 0; i < times; i++) {
      await tester.pump(step);
    }
  }

  Future<void> record(WidgetTester tester, {required String clipName}) async {
    recorder.nextStop = RecordedAudio(
        path: '/fake/tmp/$clipName', mimeType: 'audio/wav', durationMs: 2000);
    await tester.tap(find.byKey(Composer.micKey));
    await tester.pump();
    await tester.tap(find.byKey(Composer.recordStopKey));
    await tester.pump();
  }

  testWidgets('mic tap shows the recording state: elapsed readout, pulse, red ≥48dp stop '
      '(FR-002/FR-028/FR-029, SC-004)', (tester) async {
    await tester.pumpWidget(app());
    await tester.pump();
    expect(find.byKey(Composer.micKey), findsOneWidget);

    recorder.nextStop = const RecordedAudio(
        path: '/fake/tmp/state.wav', mimeType: 'audio/wav', durationMs: 2000);
    await tester.tap(find.byKey(Composer.micKey));
    await tester.pump();

    // The recording state swapped in: pulse + elapsed + the red stop control.
    expect(find.byType(RecordingIndicator), findsOneWidget);
    expect(find.text('0:00'), findsOneWidget);
    expect(find.byKey(Composer.recordStopKey), findsOneWidget);
    expect(find.byTooltip('stop recording'), findsOneWidget, reason: 'screen-reader label');

    // Red is the sanctioned recording/stop accent (Principle X).
    final stopButton = tester.widget<IconButton>(find.byKey(Composer.recordStopKey));
    expect(stopButton.style!.backgroundColor!.resolve({}), AppColors.dark.accent);
    // ≥48dp touch target (Principle VI).
    final stopSize = tester.getSize(find.byKey(Composer.recordStopKey));
    expect(stopSize.width, greaterThanOrEqualTo(48));
    expect(stopSize.height, greaterThanOrEqualTo(48));

    // The elapsed readout ticks at ≥1/s (SC-004).
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('0:01'), findsOneWidget);

    await tester.tap(find.byKey(Composer.recordStopKey));
    await tester.pump();
  });

  testWidgets('stop shows the chip with its duration; play toggles via the preview player; '
      'remove clears (FR-003/FR-004, spec Q2)', (tester) async {
    await tester.pumpWidget(app());
    await tester.pump();

    await record(tester, clipName: 'chip.wav');

    // The chip carries the clip's duration.
    expect(find.byType(AudioChip), findsOneWidget);
    expect(find.text('0:02'), findsOneWidget);

    // Play delegates to the player; the toggle tracks its state stream.
    await tester.tap(find.byKey(AudioChip.playKey));
    await tester.pump();
    expect(player.playedPaths, hasLength(1));
    await tester.pump();
    expect(find.byTooltip('stop playback'), findsOneWidget);

    // Stop playback via the same toggle.
    await tester.tap(find.byKey(AudioChip.playKey));
    await tester.pump();
    expect(player.stopCalls, greaterThanOrEqualTo(1));

    // Remove clears the pending clip (the controller deletes the temp file — real I/O).
    await tester.tap(find.byKey(AudioChip.removeKey));
    await pumpThrough(tester);
    expect(find.byType(AudioChip), findsNothing);
  });

  testWidgets('a pending clip alone enables send; the sent turn renders the chip and the reply '
      'streams (FR-004/FR-013/FR-014)', (tester) async {
    gemma
      ..scriptedDeltas = ['heard ', 'you ', 'loud and clear']
      ..deltaInterval = const Duration(milliseconds: 40);

    await tester.pumpWidget(app());
    await tester.pump();

    // Send is disabled with neither text nor attachment.
    expect(tester.widget<IconButton>(find.byKey(Composer.sendKey)).onPressed, isNull);

    await record(tester, clipName: 'send.wav');
    expect(tester.widget<IconButton>(find.byKey(Composer.sendKey)).onPressed, isNotNull,
        reason: 'a clip alone enables send (FR-004)');

    await tester.tap(find.byKey(Composer.sendKey));
    // Drive the async send (persist → rows → stream) with pumps — never a bare await.
    await pumpThrough(tester, times: 25, step: const Duration(milliseconds: 40));

    // The user turn renders its static audio chip in place (FR-018) — the composer's own pending
    // chip was cleared by the send, so exactly one remains.
    expect(find.byType(AudioChip), findsOneWidget);
    // The reply streamed in.
    expect(find.textContaining('heard you loud and clear'), findsOneWidget);
    // The clip was handed to generate.
    expect(gemma.lastAudio, isNotNull);
  });
}
