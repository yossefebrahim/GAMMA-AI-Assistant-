import 'dart:io';
import 'dart:typed_data';

import 'package:ai_assistant/data/audio/audio_file_store.dart';
import 'package:ai_assistant/data/images/image_file_store.dart';
import 'package:ai_assistant/domain/entities/audio_attachment.dart';
import 'package:ai_assistant/domain/entities/audio_input.dart';
import 'package:ai_assistant/domain/entities/message.dart';
import 'package:ai_assistant/domain/entities/model_capabilities.dart';
import 'package:ai_assistant/domain/entities/pending_recording.dart';
import 'package:ai_assistant/features/chat/chat_controller.dart';
import 'package:ai_assistant/features/chat/chat_providers.dart';
import 'package:ai_assistant/features/chat/context_assembler.dart';
import 'package:ai_assistant/infrastructure/gemma/flutter_gemma_service.dart';
import 'package:ai_assistant/infrastructure/media/permission_handler_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/container_harness.dart';
import '../helpers/fake_audio_preview_player.dart';
import '../helpers/fake_audio_recorder_service.dart';
import '../helpers/fake_gemma_service.dart';
import '../helpers/fake_media_permission_service.dart';

/// US3 context assembly with audio (003 FR-016/FR-017): audio-bearing history turns carry their
/// clip into `ChatTurn.audio` via the id-keyed map (the assembler stays PURE — bytes are
/// injected, no file I/O), the sliding window still trims, and a text-only follow-up replays the
/// clip to `generate` (proved via `FakeGemmaService.lastHistoryAudio`).
void main() {
  Message message(
    int id,
    MessageRole role,
    String content, {
    String? audioPath,
  }) => Message(
    id: id,
    conversationId: 1,
    role: role,
    content: content,
    sequence: id,
    createdAt: DateTime.utc(2026, 6, 10),
    status: MessageStatus.complete,
    audio: audioPath == null
        ? null
        : AudioAttachment(path: audioPath, mimeType: 'audio/wav'),
  );

  group('assembler (pure, bytes injected)', () {
    test(
      'audio-bearing turns get their AudioInput from the id-keyed map (FR-017)',
      () {
        const assembler = ContextAssembler();
        final clip = AudioInput(
          Uint8List.fromList(const [1, 2, 3]),
          mimeType: 'audio/wav',
        );
        final prior = [
          message(1, MessageRole.user, 'listen', audioPath: '/audio/a.wav'),
          message(2, MessageRole.assistant, 'heard it'),
          message(3, MessageRole.user, 'thanks'),
        ];

        final turns = assembler.assemble(prior, audio: {1: clip});

        expect(turns, hasLength(3));
        expect(turns[0].audio, same(clip));
        expect(turns[0].isUser, isTrue);
        expect(
          turns[1].audio,
          isNull,
          reason: 'assistant turns never carry media',
        );
        expect(turns[2].audio, isNull);
      },
    );

    test('an audio-only user turn (empty text) is still included', () {
      const assembler = ContextAssembler();
      final clip = AudioInput(Uint8List.fromList(const [9]));
      final prior = [
        message(1, MessageRole.user, '', audioPath: '/audio/only.wav'),
        message(2, MessageRole.assistant, 'a greeting'),
      ];

      final turns = assembler.assemble(prior, audio: {1: clip});

      expect(turns, hasLength(2));
      expect(turns.first.text, isEmpty);
      expect(turns.first.audio, isNotNull);
    });

    test(
      'the sliding window still trims oldest-first across audio turns (Q2)',
      () {
        // Budget of ~25 tokens: 100-char turns cost 25 each, so only the newest survives.
        const assembler = ContextAssembler(maxContextTokens: 25);
        final longText = 'x' * 100;
        final clip = AudioInput(Uint8List.fromList(const [1]));
        final prior = [
          message(1, MessageRole.user, longText, audioPath: '/audio/old.wav'),
          message(2, MessageRole.assistant, longText),
          message(3, MessageRole.user, longText),
        ];

        final turns = assembler.assemble(prior, audio: {1: clip});

        expect(
          turns,
          hasLength(1),
          reason: 'oldest (audio-bearing) turns trimmed',
        );
        expect(turns.single.audio, isNull);
      },
    );
  });

  group('follow-up replay through the chat controller (FR-016/FR-017)', () {
    late FakeGemmaService gemma;
    late Directory tempDir;
    late ProviderContainer container;

    setUp(() {
      gemma = FakeGemmaService();
      tempDir = Directory.systemTemp.createTempSync('ctx_audio_');
      container = makeContainer(
        overrides: [
          gemmaServiceProvider.overrideWithValue(gemma),
          audioFileStoreProvider.overrideWithValue(
            AudioFileStore(documentsDirectory: () async => tempDir),
          ),
          imageFileStoreProvider.overrideWithValue(
            ImageFileStore(documentsDirectory: () async => tempDir),
          ),
          audioRecorderServiceProvider.overrideWithValue(
            FakeAudioRecorderService(),
          ),
          audioPreviewPlayerProvider.overrideWithValue(
            FakeAudioPreviewPlayer(),
          ),
          mediaPermissionServiceProvider.overrideWithValue(
            FakeMediaPermissionService(),
          ),
          modelCapabilitiesProvider.overrideWith(
            (ref) => const ModelCapabilities(image: true, audio: true),
          ),
          modelSessionReadyProvider.overrideWith((ref) => true),
        ],
      );
    });

    tearDown(() {
      container.dispose();
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    test(
      'a text-only follow-up replays the earlier clip to generate via history',
      () async {
        final controller = container.read(chatControllerProvider.notifier);
        final clipFile = File('${tempDir.path}/clip.wav')
          ..writeAsBytesSync([7, 7, 7, 7]);

        // First turn: send with audio.
        gemma.scriptedDeltas = ['a sentence'];
        await controller.send(
          'transcribe this',
          audio: PendingRecording(
            path: clipFile.path,
            mimeType: 'audio/wav',
            durationMs: 1500,
          ),
        );

        // Follow-up: text only — must replay the earlier clip as context.
        gemma.scriptedDeltas = ['the first words were…'];
        await controller.send('which words came first in that audio?');

        // The follow-up carries no NEW clip…
        expect(gemma.lastAudio, isNull);
        // …but the assembled history replays the prior audio turn with its bytes (just-in-time).
        expect(gemma.lastHistoryAudio, isNotNull);
        expect(
          gemma.lastHistoryAudio!.any((a) => a != null),
          isTrue,
          reason:
              'a prior audio turn is present in the assembled context (FR-017)',
        );
        expect(
          gemma.lastHistoryAudio!.firstWhere((a) => a != null)!.bytes,
          equals(Uint8List.fromList([7, 7, 7, 7])),
        );
      },
    );
  });
}
