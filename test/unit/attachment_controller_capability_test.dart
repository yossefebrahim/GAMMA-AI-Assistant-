import 'dart:io';

import 'package:ai_assistant/domain/entities/model_capabilities.dart';
import 'package:ai_assistant/domain/services/audio_recorder_service.dart';
import 'package:ai_assistant/features/chat/attachment_controller.dart';
import 'package:ai_assistant/features/chat/chat_providers.dart';
import 'package:ai_assistant/features/chat/recording_controller.dart';
import 'package:ai_assistant/infrastructure/media/permission_handler_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// StateProvider lives in the legacy entrypoint in Riverpod 3 — fine for test toggles.
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/container_harness.dart';
import '../helpers/fake_audio_preview_player.dart';
import '../helpers/fake_audio_recorder_service.dart';
import '../helpers/fake_media_permission_service.dart';

/// US2 pending-clip clearing on a capability flip (003 FR-008/FR-009): the clip is cleared with
/// its note ONLY when a GENUINELY LOADED model lacks audio (`modelSessionReadyProvider` true) —
/// never while the session is loading or failed (the 002 "image removed" masquerade,
/// regression-locked for audio).
final _capProvider = StateProvider<ModelCapabilities>(
  (ref) => const ModelCapabilities(image: true, audio: true),
);
final _readyProvider = StateProvider<bool>((ref) => true);

void main() {
  late FakeAudioRecorderService recorder;
  late Directory tempDir;
  late ProviderContainer container;

  setUp(() {
    recorder = FakeAudioRecorderService();
    tempDir = Directory.systemTemp.createTempSync('cap_flip_');
    container = makeContainer(
      overrides: [
        modelCapabilitiesProvider.overrideWith(
          (ref) => ref.watch(_capProvider),
        ),
        modelSessionReadyProvider.overrideWith(
          (ref) => ref.watch(_readyProvider),
        ),
        audioRecorderServiceProvider.overrideWithValue(recorder),
        audioPreviewPlayerProvider.overrideWithValue(FakeAudioPreviewPlayer()),
        mediaPermissionServiceProvider.overrideWithValue(
          FakeMediaPermissionService(),
        ),
      ],
    );
    // The flip listener lives in the attachment controller's build — keep it alive, as the
    // composer does in production.
    container.listen(attachmentControllerProvider, (_, _) {});
  });

  tearDown(() {
    container.dispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Future<void> recordClip() async {
    final file = File('${tempDir.path}/clip.wav')
      ..writeAsBytesSync(List.filled(100, 1));
    recorder.nextStop = RecordedAudio(
      path: file.path,
      mimeType: 'audio/wav',
      durationMs: 1500,
    );
    final controller = container.read(recordingControllerProvider.notifier);
    await controller.onMicTap();
    await controller.stopRecording();
    expect(container.read(recordingControllerProvider).hasClip, isTrue);
  }

  Future<void> flipAudioOff() async {
    container.read(_capProvider.notifier).state = const ModelCapabilities(
      image: true,
      audio: false,
    );
    // Let the listener and the controller's async clearing (incl. real temp-file I/O) run.
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }

  test(
    'flip to a LOADED audio-incapable model clears the clip with the note (FR-008)',
    () async {
      await recordClip();

      await flipAudioOff();

      final recording = container.read(recordingControllerProvider);
      expect(recording.clip, isNull);
      expect(recording.phase, RecordingPhase.idle);
      expect(recording.note, RecordingController.clearedOnModelSwitchNote);
    },
  );

  test(
    'NOTHING is cleared while the session is loading/failed (ready=false) — FR-009',
    () async {
      await recordClip();
      container.read(_readyProvider.notifier).state = false;

      await flipAudioOff();

      final recording = container.read(recordingControllerProvider);
      expect(
        recording.clip,
        isNotNull,
        reason: 'a transient load must not eat the clip',
      );
      expect(
        recording.note,
        isNull,
        reason: 'no misleading "does not accept audio" note during a load',
      );
    },
  );

  test('a flip with nothing pending fires no note', () async {
    await flipAudioOff();

    expect(container.read(recordingControllerProvider).note, isNull);
  });
}
