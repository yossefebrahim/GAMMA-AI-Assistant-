import 'dart:io';
import 'dart:typed_data';

import 'package:ai_assistant/data/audio/audio_file_store.dart';
import 'package:ai_assistant/data/images/image_file_store.dart';
import 'package:ai_assistant/data/repositories/drift_conversation_repository.dart';
import 'package:ai_assistant/domain/entities/message.dart';
import 'package:ai_assistant/domain/entities/model_capabilities.dart';
import 'package:ai_assistant/domain/entities/pending_recording.dart';
import 'package:ai_assistant/domain/repositories/conversation_repository.dart';
import 'package:ai_assistant/features/chat/chat_controller.dart';
import 'package:ai_assistant/features/chat/chat_providers.dart';
import 'package:ai_assistant/features/chat/recording_controller.dart';
import 'package:ai_assistant/infrastructure/gemma/flutter_gemma_service.dart';
import 'package:ai_assistant/infrastructure/media/permission_handler_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/container_harness.dart';
import '../helpers/fake_audio_preview_player.dart';
import '../helpers/fake_audio_recorder_service.dart';
import '../helpers/fake_gemma_service.dart';
import '../helpers/fake_media_permission_service.dart';

/// US1 chat controller with audio (003 FR-013/FR-018) — extended [FakeGemmaService] + in-memory
/// drift repo + a temp-dir [AudioFileStore]. Persistence happens via the store at send only,
/// bytes are read just-in-time for `generate`, and a persist failure surfaces the composer-inline
/// "record again" error with NO message row (002 DF-2 applied). No native plugin, no device.
void main() {
  late FakeGemmaService gemma;
  late Directory tempDir;
  late ProviderContainer container;

  setUp(() {
    gemma = FakeGemmaService();
    tempDir = Directory.systemTemp.createTempSync('chat_audio_');
    container = makeContainer(
      overrides: [
        gemmaServiceProvider.overrideWithValue(gemma),
        imageFileStoreProvider.overrideWithValue(
          ImageFileStore(documentsDirectory: () async => tempDir),
        ),
        audioFileStoreProvider.overrideWithValue(
          AudioFileStore(documentsDirectory: () async => tempDir),
        ),
        audioRecorderServiceProvider.overrideWithValue(FakeAudioRecorderService()),
        audioPreviewPlayerProvider.overrideWithValue(FakeAudioPreviewPlayer()),
        mediaPermissionServiceProvider.overrideWithValue(FakeMediaPermissionService()),
        modelCapabilitiesProvider
            .overrideWith((ref) => const ModelCapabilities(image: true, audio: true)),
        modelSessionReadyProvider.overrideWith((ref) => true),
      ],
    );
  });

  tearDown(() {
    container.dispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  ChatController controller() => container.read(chatControllerProvider.notifier);
  ChatState read() => container.read(chatControllerProvider);
  ConversationRepository repo() => container.read(conversationRepositoryProvider);

  PendingRecording tempClip(String name, List<int> bytes) {
    final file = File('${tempDir.path}/$name')..writeAsBytesSync(bytes);
    return PendingRecording(path: file.path, mimeType: 'audio/wav', durationMs: 1500);
  }

  test('send with audio persists the clip on the user message and passes AudioInput to '
      'generate just-in-time (FR-013/FR-018)', () async {
    gemma.scriptedDeltas = ['you ', 'said ', 'hello'];
    final pending = tempClip('clip.wav', [1, 2, 3, 4]);

    await controller().send('what did i say', audio: pending);

    final conversationId = read().conversationId!;
    final turns = await repo().loadTurns(conversationId);
    final user = turns.firstWhere((m) => m.role == MessageRole.user);
    expect(user.content, 'what did i say');
    expect(user.audio, isNotNull);
    expect(user.audio!.path, contains('/${AudioFileStore.subdirectory}/'),
        reason: 'persisted via AudioFileStore at send');
    expect(user.audio!.mimeType, 'audio/wav');
    expect(File(user.audio!.path).existsSync(), isTrue, reason: 'stored copy persisted');
    expect(user.image, isNull, reason: 'audio XOR image (spec Q3)');

    // A non-null AudioInput with the stored file's bytes was handed to generate.
    expect(gemma.lastAudio, isNotNull);
    expect(gemma.lastAudio!.bytes, equals(Uint8List.fromList([1, 2, 3, 4])));
    expect(gemma.lastAudio!.mimeType, 'audio/wav');
    expect(gemma.lastImage, isNull);
    expect(gemma.lastPrompt, 'what did i say');

    // Reply deltas appended as before.
    final assistant = turns.firstWhere((m) => m.role == MessageRole.assistant);
    expect(assistant.content, 'you said hello');
    expect(assistant.status, MessageStatus.complete);
    expect(read().isGenerating, isFalse);
  });

  test('audio-only send (empty text) is allowed and titles the conversation as a voice clip '
      '(FR-004/FR-021)', () async {
    gemma.scriptedDeltas = ['a greeting'];
    final pending = tempClip('only.wav', [9, 9, 9]);

    await controller().send('', audio: pending);

    final conversationId = read().conversationId!;
    final turns = await repo().loadTurns(conversationId);
    final user = turns.firstWhere((m) => m.role == MessageRole.user);
    expect(user.content, '');
    expect(user.audio, isNotNull);
    expect(gemma.lastPrompt, '');
    expect(gemma.lastAudio, isNotNull);

    final conversations = await repo().watchConversations().first;
    expect(conversations.single.title, DriftConversationRepository.audioOnlyTitle);
  });

  test('the pending clip is cleared after a successful audio send', () async {
    gemma.scriptedDeltas = ['ok'];
    await controller().send('hi', audio: tempClip('clear.wav', [5, 5]));

    final recording = container.read(recordingControllerProvider);
    expect(recording.clip, isNull);
    expect(recording.phase, RecordingPhase.idle);
  });

  test('an oversized clip is rejected at persist with the "record again" error and NO message '
      'row (002 DF-2 / ArgumentError)', () async {
    final oversized =
        tempClip('big.wav', List.filled(AudioFileStore.maxBytes + 1, 0));

    await controller().send('hear this', audio: oversized);

    expect(read().conversationId, isNull, reason: 'send aborted before any row');
    expect(gemma.lastPrompt, isNull, reason: 'generate never called');
    expect(container.read(recordingControllerProvider).error,
        RecordingController.persistFailedError);
  });

  test('an unreadable temp file is rejected at persist with the same error and NO message row '
      '(002 DF-2 / FileSystemException)', () async {
    const missing = PendingRecording(
        path: '/nonexistent/gone.wav', mimeType: 'audio/wav', durationMs: 1500);

    await controller().send('hear this', audio: missing);

    expect(read().conversationId, isNull);
    expect(gemma.lastPrompt, isNull);
    expect(container.read(recordingControllerProvider).error,
        RecordingController.persistFailedError);
  });

  test('a text-only send still works and passes no audio (regression)', () async {
    gemma.scriptedDeltas = ['hello'];

    await controller().send('just text');

    expect(gemma.lastAudio, isNull);
    final turns = await repo().loadTurns(read().conversationId!);
    expect(turns.firstWhere((m) => m.role == MessageRole.user).audio, isNull);
  });
}
