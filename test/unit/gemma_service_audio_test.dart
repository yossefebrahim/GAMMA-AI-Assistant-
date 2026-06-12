import 'dart:typed_data';

import 'package:ai_assistant/domain/entities/audio_input.dart';
import 'package:ai_assistant/domain/entities/chat_turn.dart';
import 'package:ai_assistant/domain/entities/image_input.dart';
import 'package:ai_assistant/domain/entities/model_capabilities.dart';
import 'package:ai_assistant/domain/services/gemma_service.dart';
import 'package:ai_assistant/infrastructure/gemma/flutter_gemma_service.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fake_gemma_service.dart';

/// 003 seam contract (gemma_service.md guarantees 13–15) — the audio gates modeled FOR REAL in
/// [FakeGemmaService] (closing 002 audit L6), plus the contract-shaped pure-logic check on the
/// concrete [FlutterGemmaService] (the parts exercisable without a device/native model).
void main() {
  AudioInput clip([int length = 8]) => AudioInput(
    Uint8List.fromList(List.filled(length, 1)),
    mimeType: 'audio/wav',
  );
  ImageInput picture() => ImageInput(Uint8List.fromList(const [1, 2, 3]));

  group('FakeGemmaService models the seam gates (002 audit L6 closed)', () {
    test(
      'guarantee 13: generate(audio:) while capabilities.audio is false throws StateError '
      'synchronously — the FFI silent-drop guard',
      () async {
        final gemma = FakeGemmaService(
          capabilitiesData: const ModelCapabilities(image: true, audio: false),
        );
        await gemma.loadModel('/fake');

        expect(
          () => gemma.generate(history: const [], prompt: 'hi', audio: clip()),
          throwsStateError,
          reason:
              'the plugin silently drops ungated audio — the seam MUST throw instead',
        );
      },
    );

    test(
      'guarantee 14: both image and audio on one prompt throws StateError (spec Q3)',
      () async {
        final gemma = FakeGemmaService();
        await gemma.loadModel('/fake');

        expect(
          () => gemma.generate(
            history: const [],
            prompt: 'hi',
            image: picture(),
            audio: clip(),
          ),
          throwsStateError,
        );
      },
    );

    test('gated audio passes and is recorded as lastAudio', () async {
      final gemma = FakeGemmaService();
      await gemma.loadModel('/fake');
      gemma.scriptedDeltas = ['ok'];

      await gemma
          .generate(history: const [], prompt: 'transcribe', audio: clip(16))
          .drain<void>();

      expect(gemma.lastAudio, isNotNull);
      expect(gemma.lastAudio!.bytes.length, 16);
    });

    test(
      'history audio is recorded per turn as lastHistoryAudio (FR-017 replay assertions)',
      () async {
        final gemma = FakeGemmaService();
        await gemma.loadModel('/fake');
        gemma.scriptedDeltas = ['ok'];
        final history = [
          ChatTurn.user('listen to this', audio: clip(32)),
          const ChatTurn.assistant('heard it'),
        ];

        await gemma
            .generate(history: history, prompt: 'which words came first?')
            .drain<void>();

        expect(gemma.lastHistoryAudio, isNotNull);
        expect(gemma.lastHistoryAudio!.first, isNotNull);
        expect(gemma.lastHistoryAudio!.first!.bytes.length, 32);
        expect(
          gemma.lastHistoryAudio![1],
          isNull,
          reason: 'assistant turns carry no media',
        );
      },
    );

    test(
      'a scripted AudioProcessingException surfaces on the stream (FR-022 path)',
      () async {
        final gemma = FakeGemmaService();
        await gemma.loadModel('/fake');
        gemma.throwAudioProcessing = true;

        expect(
          gemma
              .generate(history: const [], prompt: 'transcribe', audio: clip())
              .drain<void>(),
          throwsA(isA<AudioProcessingException>()),
        );
      },
    );

    test(
      'L4 rule: a generic error on an audio-free follow-up reaches the caller UN-remapped',
      () async {
        final gemma = FakeGemmaService();
        await gemma.loadModel('/fake');
        gemma.scriptedStreamError = StateError('native blew up mid-stream');

        expect(
          gemma
              .generate(
                history: [ChatTurn.user('earlier clip turn', audio: clip())],
                prompt: 'text follow-up',
              )
              .drain<void>(),
          throwsA(
            predicate(
              (e) =>
                  e is! AudioProcessingException &&
                  e is! ImageProcessingException,
            ),
          ),
          reason:
              'errors on turns that merely replay audio history propagate unchanged',
        );
      },
    );
  });

  group('FlutterGemmaService pure-logic contract shape', () {
    test(
      'guarantee 14 is state-free: both media throws StateError even before any load',
      () {
        final service = FlutterGemmaService();

        expect(
          () => service
              .generate(
                history: const [],
                prompt: 'hi',
                image: picture(),
                audio: clip(),
              )
              .first,
          throwsStateError,
        );
      },
    );

    test(
      'generate with no model loaded throws StateError (unchanged 001 contract)',
      () {
        final service = FlutterGemmaService();

        expect(
          () => service
              .generate(history: const [], prompt: 'hi', audio: clip())
              .first,
          throwsStateError,
        );
      },
    );
  });
}
