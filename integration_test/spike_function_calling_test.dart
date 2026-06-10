// THROWAWAY SPIKE — 004-function-calling Phase 0. DO NOT SHIP, DO NOT EXTEND.
//
// Empirically measures whether Gemma 4 E2B (.litertlm) does RELIABLE function calling
// through flutter_gemma 0.15.3 on the Samsung A34 — the decision gate for feature 004.
// Mirrors FlutterGemmaService's exact load recipe (installModel → getActiveModel
// GPU-first/CPU-fallback, maxTokens 2048 → createChat) with one registered tool
// (get_device_info → static JSON) and supportsFunctionCalls flipped on.
//
// 20 varied prompts across three buckets:
//   * 12 SHOULD-CALL  — device questions answerable only via the tool
//   *  5 SHOULD-TEXT  — ordinary questions; calling anything is a spurious call
//   *  3 PROBES       — requests resembling UNREGISTERED tools (timer/theme/weather);
//                       a call to a non-existent tool name is a hallucinated tool
//
// Each trial runs in a fresh single-turn context (`chat.clearHistory()` recreates the
// native conversation; the tools_json config is re-applied by the sessionCreator).
// A correct call gets the full round-trip: Message.toolResponse → resume generation →
// check the final answer is grounded in the returned sentinel values.
//
// Results are emitted as grep-able `SPIKE {json}` lines. Findings land in
// specs/004-function-calling/spike-findings.md.
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

/// Distinctive sentinel values so the grounding check is unambiguous — a grounded
/// final answer must echo at least one of these.
const Map<String, Object?> _deviceInfo = {
  'device': 'samsung galaxy a34 (sm-a346e)',
  'androidVersion': 'android 14',
  'ramTotal': '7.4 GB',
  'ramFree': '2.1 GB',
  'battery': '83%',
  'storageFree': '41 GB',
};

const List<String> _groundingMarkers = ['a34', 'sm-a346e', '7.4', '2.1', '83', '41 gb'];

const Tool _deviceInfoTool = Tool(
  name: 'get_device_info',
  description: 'Returns information about the device the assistant is running on: '
      'model name, android version, total and free RAM, battery level, and free storage.',
  parameters: {
    'type': 'object',
    'properties': {
      'section': {
        'type': 'string',
        'description': 'optional — restrict the result to one section',
        'enum': ['hardware', 'memory', 'battery', 'storage', 'all'],
      },
    },
    'required': <String>[],
  },
);

/// (bucket, prompt). Buckets: call = should call get_device_info; text = should answer
/// in plain text; probe = resembles an UNREGISTERED tool (hallucination bait).
const List<(String, String)> _trials = [
  ('call', 'what device am i running on?'),
  ('call', 'how much memory does this phone have?'),
  ('call', 'check the battery level for me'),
  ('call', 'use your get_device_info tool to show me my device details'),
  ('call', 'give me a quick spec readout of this phone'),
  ('call', "what's the exact model name of this handset?"),
  ('call', 'is this phone running low on battery right now?'),
  ('call', 'tell me about the hardware i am using'),
  ('call', 'how much free storage do i have left?'),
  ('call', 'which android version is this device on?'),
  ('call', 'can you look up my device details?'),
  ('call', 'battery status please'),
  ('text', 'write a haiku about rain'),
  ('text', 'what is the capital of france?'),
  ('text', 'explain in one sentence what binary search does'),
  ('text', "translate 'good morning' into spanish"),
  ('text', 'what is 17 times 23?'),
  ('probe', 'set a timer for 5 minutes'),
  ('probe', 'switch the app to light theme'),
  ('probe', 'what is the weather right now?'),
];

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
    'gemma 4 e2b function-calling reliability spike',
    timeout: const Timeout(Duration(minutes: 35)),
    (tester) async {
      var peakRss = 0;
      final rssTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
        peakRss = math.max(peakRss, ProcessInfo.currentRss);
      });

      void spike(String stage, Map<String, Object?> data) {
        // ignore: avoid_print
        print('SPIKE ${jsonEncode({
              'stage': stage,
              'rssMb': (ProcessInfo.currentRss / (1024 * 1024)).round(),
              'peakRssMb': (peakRss / (1024 * 1024)).round(),
              ...data,
            })}');
      }

      // Drains one generation; collects text tokens + any function call. On the gemma4
      // SDK path the call arrives as the FINAL stream event (after any text tokens).
      Future<({String text, int? firstTokenMs, int totalMs, List<FunctionCallResponse> calls})>
          drain(InferenceChat chat) async {
        final sw = Stopwatch()..start();
        int? firstTokenMs;
        final text = StringBuffer();
        final calls = <FunctionCallResponse>[];
        final stream = chat.generateChatResponseAsync().timeout(
              const Duration(seconds: 120),
              onTimeout: (sink) => sink.close(), // 120s token silence → give up on the turn
            );
        await for (final response in stream) {
          if (response is TextResponse) {
            firstTokenMs ??= sw.elapsedMilliseconds;
            text.write(response.token);
          } else if (response is FunctionCallResponse) {
            calls.add(response);
          } else if (response is ParallelFunctionCallResponse) {
            calls.addAll(response.calls);
          }
        }
        sw.stop();
        return (
          text: text.toString(),
          firstTokenMs: firstTokenMs,
          totalMs: sw.elapsedMilliseconds,
          calls: calls,
        );
      }

      // Strict arg validation against the declared schema (the dispatcher 004 would build).
      (bool, String?) validateArgs(Map<String, dynamic> args) {
        const allowed = {'section'};
        const enumValues = {'hardware', 'memory', 'battery', 'storage', 'all'};
        for (final key in args.keys) {
          if (!allowed.contains(key)) return (false, 'unexpected key: $key');
        }
        final section = args['section'];
        if (section != null && (section is! String || !enumValues.contains(section))) {
          return (false, 'invalid section: $section');
        }
        return (true, null);
      }

      final docs = await getApplicationDocumentsDirectory();
      final modelPath = '${docs.path}/models/gemma-4-e2b.litertlm';
      expect(File(modelPath).existsSync(), isTrue, reason: 'model not on device');

      try {
        spike('baseline', {});

        await FlutterGemma.initialize();
        await FlutterGemma.installModel(
          modelType: ModelType.gemma4,
          fileType: ModelFileType.litertlm,
        ).fromFile(modelPath).install();

        // GPU-first, CPU-fallback — the app's exact activation order.
        InferenceModel? model;
        var backend = 'gpu';
        final loadSw = Stopwatch()..start();
        try {
          model = await FlutterGemma.getActiveModel(
            maxTokens: 2048,
            preferredBackend: PreferredBackend.gpu,
          );
        } catch (error) {
          spike('gpu-activation-failed', {'error': '$error'});
          backend = 'cpu';
          model = await FlutterGemma.getActiveModel(
            maxTokens: 2048,
            preferredBackend: PreferredBackend.cpu,
          );
        }

        final chat = await model.createChat(
          modelType: ModelType.gemma4,
          supportImage: false,
          supportAudio: false,
          supportsFunctionCalls: true,
          isThinking: false,
          tools: const [_deviceInfoTool],
          // ToolChoice.auto — the production posture: the model decides per prompt.
        );
        loadSw.stop();
        spike('model-loaded', {'backend': backend, 'loadMs': loadSw.elapsedMilliseconds});

        final results = <Map<String, Object?>>[];

        for (var i = 0; i < _trials.length; i++) {
          final (bucket, prompt) = _trials[i];
          // Fresh single-turn context per trial; sessionCreator re-applies tools_json.
          await chat.clearHistory();

          await chat.addQueryChunk(Message.text(text: prompt, isUser: true));
          final first = await drain(chat);

          final called = first.calls.isNotEmpty;
          final call = called ? first.calls.first : null;
          final knownTool = call?.name == 'get_device_info';
          var argsValid = false;
          String? argsError;
          if (call != null && knownTool) {
            (argsValid, argsError) = validateArgs(call.args);
          }
          // The verified leak hazard: raw SDK JSON surfacing in the text channel.
          final leakedRawJson = first.text.contains('tool_call') ||
              RegExp(r'\{\s*"').hasMatch(first.text);

          String? finalReply;
          bool? grounded;
          var extraCallOnResume = false;
          int? resumeMs;
          if (called && knownTool && argsValid) {
            // Full round-trip: execute (static), return result, resume generation.
            await chat.addQuery(Message.toolResponse(
              toolName: call!.name,
              response: _deviceInfo,
            ));
            final resumed = await drain(chat);
            finalReply = resumed.text;
            resumeMs = resumed.totalMs;
            extraCallOnResume = resumed.calls.isNotEmpty;
            final lower = resumed.text.toLowerCase();
            grounded = _groundingMarkers.any(lower.contains);
          }

          final record = <String, Object?>{
            'trial': i + 1,
            'bucket': bucket,
            'prompt': prompt,
            'called': called,
            'tool': call?.name,
            'args': call?.args,
            'argsValid': call == null ? null : argsValid,
            'argsError': argsError,
            'parallelCalls': first.calls.length,
            'preCallText': first.text.trim(),
            'leakedRawJson': leakedRawJson,
            'finalReply': finalReply?.trim(),
            'grounded': grounded,
            'extraCallOnResume': extraCallOnResume,
            'firstTokenMs': first.firstTokenMs,
            'turnMs': first.totalMs,
            'resumeMs': resumeMs,
          };
          results.add(record);
          spike('trial', record);
        }

        // ---- scoring ----
        final shouldCall = results.where((r) => r['bucket'] == 'call').toList();
        final shouldText = results.where((r) => r['bucket'] == 'text').toList();
        final probes = results.where((r) => r['bucket'] == 'probe').toList();

        final correctCalls = shouldCall
            .where((r) =>
                r['called'] == true && r['tool'] == 'get_device_info' && r['argsValid'] == true)
            .length;
        final missedCalls = shouldCall.where((r) => r['called'] == false).length;
        final malformedArgs =
            results.where((r) => r['called'] == true && r['argsValid'] == false).length;
        final hallucinatedTools = results
            .where((r) => r['called'] == true && r['tool'] != 'get_device_info')
            .map((r) => r['tool'])
            .toList();
        final spuriousCalls = shouldText.where((r) => r['called'] == true).length;
        final probeCalls = probes.where((r) => r['called'] == true).length;
        final groundedCount = results.where((r) => r['grounded'] == true).length;
        final roundTrips = results.where((r) => r['grounded'] != null).length;
        final leaks = results.where((r) => r['leakedRawJson'] == true).length;

        final correctRate = correctCalls / shouldCall.length;
        spike('summary', {
          'correctCallRate': correctRate,
          'correctCalls': correctCalls,
          'shouldCallTotal': shouldCall.length,
          'missedCalls': missedCalls,
          'malformedArgs': malformedArgs,
          'hallucinatedTools': hallucinatedTools,
          'spuriousCallsOnTextPrompts': spuriousCalls,
          'callsOnUnregisteredToolProbes': probeCalls,
          'groundedReplies': groundedCount,
          'roundTripsRun': roundTrips,
          'rawJsonLeaks': leaks,
          'gatePass80pct': correctRate >= 0.8,
        });

        await model.close();
        spike('done', {});
      } finally {
        rssTimer.cancel();
      }
    },
  );
}
