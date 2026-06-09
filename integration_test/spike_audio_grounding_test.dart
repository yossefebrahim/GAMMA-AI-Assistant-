// THROWAWAY SPIKE — 003-audio-input Phase 0. DO NOT SHIP, DO NOT EXTEND.
//
// Empirically verifies whether Gemma 4 E2B (.litertlm) grounds AUDIO input through
// flutter_gemma 0.15.3 on the Samsung A34 — the decision gate for feature 003.
// Mirrors FlutterGemmaService's exact load recipe (installModel → getActiveModel
// GPU-first/CPU-fallback, maxTokens 2048 → createChat) with supportAudio flipped on.
//
// Prereqs (done out-of-band by the spike runner):
//   * the 2.4GB model already downloaded by the app at <docs>/models/gemma-4-e2b.litertlm
//   * a 16kHz mono 16-bit PCM WAV pushed to <docs>/spike_audio.wav whose spoken content is:
//     "the yellow elephant danced on a purple piano at midnight, while seven green
//      turtles sang quietly under the old wooden bridge"
//
// Results are emitted as grep-able `SPIKE {json}` lines. Findings land in
// specs/003-audio-input/spike-findings.md.
//
// This file deliberately imports flutter_gemma directly: the Principle VII seam guard
// (tool/check_plugin_seam.sh) scopes to lib/ only, and a spike that must bypass the
// seam to probe the plugin is its sanctioned exception — on this branch, for this test.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show DebugPrintCallback, debugPrint;
import 'package:flutter_gemma/flutter_gemma.dart' hide ImageProcessingException;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // The plugin debugPrints several lines per token plus full history dumps per chunk;
  // filter the known noise so SPIKE lines stay readable (same prefixes the app filters).
  final DebugPrintCallback base = debugPrint;
  debugPrint = (String? message, {int? wrapWidth}) {
    if (message != null &&
        (message.startsWith('InferenceChat:') ||
            message.startsWith('[MobileSession') ||
            message.startsWith('--- Sending to Native ---') ||
            message.startsWith('History:') ||
            message.startsWith('Current Message:') ||
            message.startsWith('-------------------------') ||
            message.startsWith('ImageProcessor:'))) {
      return;
    }
    base(message, wrapWidth: wrapWidth);
  };

  testWidgets(
    'gemma 4 e2b audio grounding spike',
    timeout: const Timeout(Duration(minutes: 25)),
    (tester) async {
      var peakRss = 0;
      final rssTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
        peakRss = math.max(peakRss, ProcessInfo.currentRss);
      });

      int memAvailableKb() {
        try {
          final line = File('/proc/meminfo')
              .readAsLinesSync()
              .firstWhere((l) => l.startsWith('MemAvailable'));
          return int.parse(RegExp(r'\d+').firstMatch(line)!.group(0)!);
        } catch (_) {
          return -1;
        }
      }

      void spike(String stage, Map<String, Object?> data) {
        // ignore: avoid_print
        print('SPIKE ${jsonEncode({
              'stage': stage,
              'rssMb': (ProcessInfo.currentRss / (1024 * 1024)).round(),
              'peakRssMb': (peakRss / (1024 * 1024)).round(),
              'memAvailableMb': (memAvailableKb() / 1024).round(),
              ...data,
            })}');
      }

      Future<Map<String, Object?>> runTurn(InferenceChat chat, Message message) async {
        final addSw = Stopwatch()..start();
        await chat.addQueryChunk(message);
        addSw.stop();

        final genSw = Stopwatch()..start();
        int? firstTokenMs;
        var tokens = 0;
        final reply = StringBuffer();
        await for (final response in chat.generateChatResponseAsync()) {
          if (response is TextResponse) {
            firstTokenMs ??= genSw.elapsedMilliseconds;
            tokens++;
            reply.write(response.token);
          }
        }
        genSw.stop();
        return {
          'addQueryChunkMs': addSw.elapsedMilliseconds,
          'firstTokenMs': firstTokenMs,
          'totalGenMs': genSw.elapsedMilliseconds,
          'tokens': tokens,
          'reply': reply.toString(),
        };
      }

      try {
        final docs = await getApplicationDocumentsDirectory();
        final modelPath = '${docs.path}/models/gemma-4-e2b.litertlm';
        final wavFile = File('${docs.path}/spike_audio.wav');
        expect(File(modelPath).existsSync(), isTrue, reason: 'model not on device');
        expect(wavFile.existsSync(), isTrue, reason: 'spike WAV not pushed');
        final wavBytes = wavFile.readAsBytesSync();

        spike('baseline', {'wavBytes': wavBytes.length});

        await FlutterGemma.initialize();
        await FlutterGemma.installModel(
          modelType: ModelType.gemma4,
          fileType: ModelFileType.litertlm,
        ).fromFile(modelPath).install();

        // GPU-first, CPU-fallback — the app's exact activation order, audio enabled.
        InferenceModel? model;
        var backend = 'gpu';
        final loadSw = Stopwatch()..start();
        try {
          model = await FlutterGemma.getActiveModel(
            maxTokens: 2048,
            preferredBackend: PreferredBackend.gpu,
            supportAudio: true,
          );
        } catch (error) {
          spike('gpu-activation-failed', {'error': '$error'});
          backend = 'cpu';
          model = await FlutterGemma.getActiveModel(
            maxTokens: 2048,
            preferredBackend: PreferredBackend.cpu,
            supportAudio: true,
          );
        }
        final chat = await model.createChat(
          modelType: ModelType.gemma4,
          supportImage: false,
          supportAudio: true,
          supportsFunctionCalls: false,
          isThinking: false,
        );
        loadSw.stop();
        spike('model-loaded', {'backend': backend, 'loadMs': loadSw.elapsedMilliseconds});

        // Turn 1 — text-only baseline for RAM/latency comparison.
        final textTurn = await runTurn(
          chat,
          Message.text(text: 'reply with one short sentence: what is the capital of france?', isUser: true),
        );
        spike('text-baseline', textTurn);
        final rssAfterText = ProcessInfo.currentRss;
        peakRss = 0; // reset so the audio peak is measured in isolation

        // Turn 2 — the decisive turn: ~7s spoken clip, transcription request.
        final audioTurn = await runTurn(
          chat,
          Message.withAudio(
            text: 'Transcribe the speech in this audio clip exactly, word for word.',
            audioBytes: wavBytes,
            isUser: true,
          ),
        );
        spike('audio-turn', {
          ...audioTurn,
          'audioRssDeltaMb':
              ((ProcessInfo.currentRss - rssAfterText) / (1024 * 1024)).round(),
        });

        // Turn 3 — follow-up grounding: can it still refer to the clip next turn?
        final followUp = await runTurn(
          chat,
          Message.text(
            text: 'without me re-sending it: which animal was mentioned first in that audio?',
            isUser: true,
          ),
        );
        spike('follow-up', followUp);

        await model.close();
        spike('done', {});
      } finally {
        rssTimer.cancel();
      }
    },
  );
}
