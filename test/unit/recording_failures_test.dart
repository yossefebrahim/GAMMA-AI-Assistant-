import 'dart:io';

import 'package:ai_assistant/domain/entities/model_capabilities.dart';
import 'package:ai_assistant/domain/services/audio_recorder_service.dart';
import 'package:ai_assistant/features/chat/chat_providers.dart';
import 'package:ai_assistant/features/chat/recording_controller.dart';
import 'package:ai_assistant/infrastructure/media/permission_handler_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import '../helpers/container_harness.dart';
import '../helpers/fake_audio_preview_player.dart';
import '../helpers/fake_audio_recorder_service.dart';
import '../helpers/fake_media_permission_service.dart';

/// US6 recording failure matrix (003 FR-021, Principle V): a busy/broken recorder fails fast
/// with a clear composer message, and backgrounding mid-recording applies the stop-and-keep
/// rule (≥ minimum → chip + note, < minimum → discard + note); the preview player is released
/// on backgrounding (Principle VIII).
void main() {
  late FakeAudioRecorderService recorder;
  late FakeAudioPreviewPlayer player;
  late Directory tempDir;

  setUp(() {
    recorder = FakeAudioRecorderService();
    player = FakeAudioPreviewPlayer();
    tempDir = Directory.systemTemp.createTempSync('rec_fail_');
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  List<Override> overrides() => [
    audioRecorderServiceProvider.overrideWithValue(recorder),
    audioPreviewPlayerProvider.overrideWithValue(player),
    mediaPermissionServiceProvider.overrideWithValue(
      FakeMediaPermissionService(),
    ),
    modelCapabilitiesProvider.overrideWith(
      (ref) => const ModelCapabilities(image: true, audio: true),
    ),
    modelSessionReadyProvider.overrideWith((ref) => true),
  ];

  ProviderContainer makeFailureContainer() {
    final container = makeContainer(overrides: overrides());
    addTearDown(container.dispose);
    return container;
  }

  File tempClip(String name) =>
      File('${tempDir.path}/$name')..writeAsBytesSync(List.filled(100, 1));

  test(
    'RecorderUnavailableException → clear composer message, app stays usable (FR-021)',
    () async {
      final container = makeFailureContainer();
      final controller = container.read(recordingControllerProvider.notifier);
      recorder.throwOnStart = true;

      await controller.onMicTap();

      final state = container.read(recordingControllerProvider);
      expect(state.phase, RecordingPhase.idle);
      expect(state.error, RecordingController.recorderUnavailableError);

      // Recovery: the mic works again once the recorder does.
      recorder.throwOnStart = false;
      await controller.onMicTap();
      expect(
        container.read(recordingControllerProvider).phase,
        RecordingPhase.recording,
      );
      await container
          .read(recordingControllerProvider.notifier)
          .stopRecording();
    },
  );

  test(
    'backgrounding mid-recording with ≥ minimum captured keeps the clip with a note '
    '(FR-021 stop-and-keep)',
    () async {
      final container = makeFailureContainer();
      final controller = container.read(recordingControllerProvider.notifier);
      final clipFile = tempClip('kept.wav');
      recorder.nextStop = RecordedAudio(
        path: clipFile.path,
        mimeType: 'audio/wav',
        durationMs: 3000,
      );
      await controller.onMicTap();

      await controller.onAppBackgrounded();

      final state = container.read(recordingControllerProvider);
      expect(
        state.phase,
        RecordingPhase.previewing,
        reason: '≥ min → clip kept',
      );
      expect(state.clip!.durationMs, 3000);
      expect(state.note, RecordingController.interruptedKeptNote);
      expect(recorder.calls, ['start', 'stop']);
    },
  );

  test(
    'backgrounding mid-recording with < minimum captured discards with a note (FR-021)',
    () async {
      final container = makeFailureContainer();
      final controller = container.read(recordingControllerProvider.notifier);
      final clipFile = tempClip('short.wav');
      recorder.nextStop = RecordedAudio(
        path: clipFile.path,
        mimeType: 'audio/wav',
        durationMs: 200,
      );
      await controller.onMicTap();

      await controller.onAppBackgrounded();

      final state = container.read(recordingControllerProvider);
      expect(state.phase, RecordingPhase.idle);
      expect(state.clip, isNull);
      expect(state.note, RecordingController.interruptedDiscardedNote);
      expect(clipFile.existsSync(), isFalse, reason: 'discarded temp deleted');
    },
  );

  test(
    'backgrounding while a preview plays releases the player (Principle VIII)',
    () async {
      final container = makeFailureContainer();
      final controller = container.read(recordingControllerProvider.notifier);
      final clipFile = tempClip('playing.wav');
      recorder.nextStop = RecordedAudio(
        path: clipFile.path,
        mimeType: 'audio/wav',
        durationMs: 2000,
      );
      await controller.onMicTap();
      await controller.stopRecording();
      await controller.playPreview();
      await Future<void>.delayed(Duration.zero);
      expect(
        container.read(recordingControllerProvider).isPreviewPlaying,
        isTrue,
      );

      await controller.onAppBackgrounded();

      expect(player.stopCalls, greaterThanOrEqualTo(1));
      final state = container.read(recordingControllerProvider);
      expect(
        state.clip,
        isNotNull,
        reason: 'the pending clip itself survives backgrounding',
      );
    },
  );
}
