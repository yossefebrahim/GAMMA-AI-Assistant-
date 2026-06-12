import 'dart:io';

import 'package:ai_assistant/core/audio_constants.dart';
import 'package:ai_assistant/domain/entities/model_capabilities.dart';
import 'package:ai_assistant/domain/services/audio_recorder_service.dart';
import 'package:ai_assistant/domain/services/media_permission_service.dart';
import 'package:ai_assistant/features/chat/chat_providers.dart';
import 'package:ai_assistant/features/chat/recording_controller.dart';
import 'package:ai_assistant/infrastructure/media/permission_handler_service.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// Riverpod 3 splits its public surface across entrypoints; `Override` lives in `misc`.
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import '../helpers/container_harness.dart';
import '../helpers/fake_audio_preview_player.dart';
import '../helpers/fake_audio_recorder_service.dart';
import '../helpers/fake_media_permission_service.dart';

/// US1 recording state machine (data-model.md §4): idle → recording → previewing, the 30 s cap
/// (auto-stop keeps the clip), the 500 ms minimum (discard + note), temp-file cleanup on
/// discard/replace, and preview-player ownership — all against the seam fakes, no plugin/device.
void main() {
  late FakeAudioRecorderService recorder;
  late FakeAudioPreviewPlayer player;
  late FakeMediaPermissionService permission;
  late Directory tempDir;

  setUp(() {
    recorder = FakeAudioRecorderService();
    player = FakeAudioPreviewPlayer();
    permission = FakeMediaPermissionService();
    tempDir = Directory.systemTemp.createTempSync('rec_ctl_');
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  List<Override> overrides() => [
    audioRecorderServiceProvider.overrideWithValue(recorder),
    audioPreviewPlayerProvider.overrideWithValue(player),
    mediaPermissionServiceProvider.overrideWithValue(permission),
    modelCapabilitiesProvider.overrideWith(
      (ref) => const ModelCapabilities(image: true, audio: true),
    ),
    modelSessionReadyProvider.overrideWith((ref) => true),
  ];

  ProviderContainer makeRecordingContainer() {
    final container = makeContainer(overrides: overrides());
    addTearDown(container.dispose);
    return container;
  }

  File tempClip(String name, {int bytes = 32044}) =>
      File('${tempDir.path}/$name')..writeAsBytesSync(List.filled(bytes, 7));

  test(
    'happy path: mic tap (granted) → recording → stop → previewing with the clip',
    () async {
      final container = makeRecordingContainer();
      final controller = container.read(recordingControllerProvider.notifier);
      final clipFile = tempClip('a.wav');
      recorder.nextStop = RecordedAudio(
        path: clipFile.path,
        mimeType: 'audio/wav',
        durationMs: 1500,
      );

      await controller.onMicTap();
      expect(
        container.read(recordingControllerProvider).phase,
        RecordingPhase.recording,
      );
      expect(recorder.calls, ['start']);
      // Permission was checked but no prompt fired (already granted, FR-010).
      expect(permission.micStatusCalls, 1);
      expect(permission.micRequestCalls, 0);

      await controller.stopRecording();
      final state = container.read(recordingControllerProvider);
      expect(state.phase, RecordingPhase.previewing);
      expect(state.clip, isNotNull);
      expect(state.clip!.path, clipFile.path);
      expect(state.clip!.durationMs, 1500);
      expect(state.note, isNull);
      expect(recorder.calls, ['start', 'stop']);
    },
  );

  test(
    'denied → request → granted starts recording (first-use request, FR-010)',
    () async {
      permission
        ..micStatusValue = MediaPermissionStatus.denied
        ..micRequestResults = [MediaPermissionStatus.granted];
      final container = makeRecordingContainer();
      final controller = container.read(recordingControllerProvider.notifier);

      await controller.onMicTap();

      expect(permission.micRequestCalls, 1);
      expect(
        container.read(recordingControllerProvider).phase,
        RecordingPhase.recording,
      );
    },
  );

  test(
    'cap auto-stop keeps the clip with the limit note (FR-002, spec Q1)',
    () {
      fakeAsync((async) {
        final container = ProviderContainer(overrides: overrides());
        final controller = container.read(recordingControllerProvider.notifier);
        recorder.nextStop = RecordedAudio(
          path: '${tempDir.path}/cap.wav',
          mimeType: 'audio/wav',
          durationMs: 30000,
        );

        controller.onMicTap();
        async.flushMicrotasks();
        expect(
          container.read(recordingControllerProvider).phase,
          RecordingPhase.recording,
        );

        // The elapsed readout ticks at ≥1/s (SC-004).
        async.elapse(const Duration(seconds: 3));
        expect(
          container.read(recordingControllerProvider).elapsed,
          const Duration(seconds: 3),
        );

        async.elapse(
          AudioConstants.maxClipDuration - const Duration(seconds: 3),
        );
        async.flushMicrotasks();

        final state = container.read(recordingControllerProvider);
        expect(
          state.phase,
          RecordingPhase.previewing,
          reason: 'cap keeps the clip',
        );
        expect(state.clip!.durationMs, 30000);
        expect(state.note, RecordingController.limitReachedNote);
        expect(recorder.calls, ['start', 'stop']);
        container.dispose();
      });
    },
  );

  test(
    'a stop under the 500 ms minimum discards the clip with the note (FR-002)',
    () async {
      final container = makeRecordingContainer();
      final controller = container.read(recordingControllerProvider.notifier);
      final clipFile = tempClip('short.wav');
      recorder.nextStop = RecordedAudio(
        path: clipFile.path,
        mimeType: 'audio/wav',
        durationMs: 300,
      );

      await controller.onMicTap();
      await controller.stopRecording();

      final state = container.read(recordingControllerProvider);
      expect(state.phase, RecordingPhase.idle);
      expect(state.clip, isNull);
      expect(state.note, RecordingController.tooShortNote);
      expect(
        clipFile.existsSync(),
        isFalse,
        reason: 'too-short temp is deleted',
      );
    },
  );

  test(
    'remove deletes the temp file, stops the preview, and returns to idle',
    () async {
      final container = makeRecordingContainer();
      final controller = container.read(recordingControllerProvider.notifier);
      final clipFile = tempClip('rm.wav');
      recorder.nextStop = RecordedAudio(
        path: clipFile.path,
        mimeType: 'audio/wav',
        durationMs: 2000,
      );
      await controller.onMicTap();
      await controller.stopRecording();
      await controller.playPreview();

      await controller.removeClip();

      expect(
        container.read(recordingControllerProvider).phase,
        RecordingPhase.idle,
      );
      expect(
        clipFile.existsSync(),
        isFalse,
        reason: 'nothing persists from a cancelled compose',
      );
      expect(
        player.stopCalls,
        greaterThanOrEqualTo(1),
        reason: 'preview stopped on remove',
      );
    },
  );

  test('re-record replaces the previous clip (old temp deleted)', () async {
    final container = makeRecordingContainer();
    final controller = container.read(recordingControllerProvider.notifier);
    final first = tempClip('first.wav');
    recorder.nextStop = RecordedAudio(
      path: first.path,
      mimeType: 'audio/wav',
      durationMs: 1000,
    );
    await controller.onMicTap();
    await controller.stopRecording();
    expect(container.read(recordingControllerProvider).clip!.path, first.path);
    await controller.playPreview();

    final second = tempClip('second.wav');
    recorder.nextStop = RecordedAudio(
      path: second.path,
      mimeType: 'audio/wav',
      durationMs: 1200,
    );
    await controller.onMicTap(); // re-record from previewing
    expect(
      container.read(recordingControllerProvider).phase,
      RecordingPhase.recording,
    );
    expect(first.existsSync(), isFalse, reason: 'old temp replaced');
    expect(
      player.stopCalls,
      greaterThanOrEqualTo(1),
      reason: 'preview stopped on replace',
    );

    await controller.stopRecording();
    expect(container.read(recordingControllerProvider).clip!.path, second.path);
  });

  test(
    'preview play/stop delegates to the player and tracks its state',
    () async {
      final container = makeRecordingContainer();
      final controller = container.read(recordingControllerProvider.notifier);
      final clipFile = tempClip('play.wav');
      recorder.nextStop = RecordedAudio(
        path: clipFile.path,
        mimeType: 'audio/wav',
        durationMs: 2000,
      );
      await controller.onMicTap();
      await controller.stopRecording();

      await controller.playPreview();
      expect(player.playedPaths, [clipFile.path]);
      // Let the player's state event propagate to the controller's subscription.
      await Future<void>.delayed(Duration.zero);
      expect(
        container.read(recordingControllerProvider).isPreviewPlaying,
        isTrue,
      );

      await controller.stopPreview();
      await Future<void>.delayed(Duration.zero);
      expect(
        container.read(recordingControllerProvider).isPreviewPlaying,
        isFalse,
      );
      expect(player.stopCalls, 1);
    },
  );

  test(
    'clearAfterSend stops the preview, drops the temp, and returns to idle',
    () async {
      final container = makeRecordingContainer();
      final controller = container.read(recordingControllerProvider.notifier);
      final clipFile = tempClip('send.wav');
      recorder.nextStop = RecordedAudio(
        path: clipFile.path,
        mimeType: 'audio/wav',
        durationMs: 2000,
      );
      await controller.onMicTap();
      await controller.stopRecording();
      await controller.playPreview();

      await controller.clearAfterSend();

      expect(
        container.read(recordingControllerProvider).phase,
        RecordingPhase.idle,
      );
      expect(container.read(recordingControllerProvider).clip, isNull);
      expect(
        clipFile.existsSync(),
        isFalse,
        reason: 'composer temp dropped after persist',
      );
      expect(
        player.stopCalls,
        greaterThanOrEqualTo(1),
        reason: 'preview stopped on send',
      );
    },
  );

  test(
    'a recorder-unavailable start surfaces the inline error and stays idle (FR-021)',
    () async {
      final container = makeRecordingContainer();
      final controller = container.read(recordingControllerProvider.notifier);
      recorder.throwOnStart = true;

      await controller.onMicTap();

      final state = container.read(recordingControllerProvider);
      expect(state.phase, RecordingPhase.idle);
      expect(state.error, RecordingController.recorderUnavailableError);
    },
  );
}
