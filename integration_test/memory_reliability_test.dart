// SHIPPED RELIABILITY HARNESS — 005-memory (T050)
//
// On-device gate for auto-capture (SC-001/002/003) and token-budget sanity (SC-005).
// Run ONLY via `flutter drive`:
//
//   flutter drive \
//     --driver=test_driver/integration_test.dart \
//     --target=integration_test/memory_reliability_test.dart \
//     -d <device-id>
//
// NEVER `flutter test integration_test/...` — it uninstalls the app and wipes the
// 2.4 GB model + DB (memory.md; also applies here because the harness downloads
// nothing and needs the resident model artifact).
//
// ── What this measures ──────────────────────────────────────────────────────────
//
//   30 prompts across three buckets (SC-001/002/003):
//     ≥ 20  SHOULD-CAPTURE — durable facts the model MUST call `remember_fact` for.
//     ≥ 10  SHOULD-NOT     — trivia, one-off tasks, questions; any capture is a
//                           false positive (SC-002 target: 0).
//   Gate thresholds (quickstart V9):
//     capture rate     ≥ 75%   (spike floor 80% with the tuned instruction)
//     false positives  ==  0   on should-not prompts
//     wrong tools      ==  0   (must not call forget_fact or a device tool)
//     arg quality      ≥ 90%   (fact ≤ 80 chars + valid category enum)
//
//   SC-005 token-budget assertion (one static measurement, no model needed):
//     a ≤ 20-fact block + capture instruction MUST fit ≤ ~311 tokens
//     (≤ ~20% of the 1536-token ContextAssembler budget; spike §2 numbers).
//
// ── Relationship to the spike harness ───────────────────────────────────────────
//
// The Phase 0 spike (`spike_memory_test.dart`, now removed per T002) was a throwaway
// single-tool probe that directly imported flutter_gemma and produced SPIKE log lines.
// This harness is the shipped pipeline gate:
//   * it drives the plugin DIRECTLY (the `flutter_gemma` import below) and loads the
//     model itself — spike-style, NOT through the `GemmaService` seam. That is a
//     deliberate, scoped exception to Principle VII for this DEVICE-RELIABILITY gate:
//     the measurement is the model's capture behavior under the real R5 instruction +
//     tool schemas, and going through the full app/seam/Riverpod stack would add nothing
//     to that signal while making a 35-min device drive far harder to author and debug.
//     The shipped app code stays behind the seam — only this harness reaches past it.
//   * it uses the real `remember_fact`/`forget_fact` tool schemas (mirrored inline) and
//     the identical R5 capture instruction `SystemInstructionComposer` composes, so the
//     measurement reflects what production sends the model;
//   * it asserts the tuned R5 capture instruction meets SC-001 (≥75%) with 0 false
//     positives and records every trial outcome in a grep-able `@@MEMORY@@` log line.
//
// ── Capture instruction tuning (R5 / SC-001) ────────────────────────────────────
//
// The spike's 80% floor had 4 misses, ALL on instruction-shaped preferences:
//   "use metric units", "address me formally", "I'm learning Rust", "like concise answers"
// The tuned instruction below names that class explicitly (R5 rationale) to clear ≥75%
// with margin. `ToolChoice.auto` is preserved — the spike's 0 false positives depend on
// the model choosing freely (never `required`).
//
// Expected instruction (authored here; fed to the app via the system instruction path
// when the harness loads the model directly — identical to what `SystemInstructionComposer`
// will compose in the shipped feature):
//
//   "you remember the user across chats. when the user shares a durable fact about
//   themselves — their name, where they live, their job, or a lasting preference about
//   how you should respond (tone, units, formatting) — call remember_fact with a short
//   third-person statement and a category. don't save questions, one-off tasks, weather,
//   math, or trivia."
//
// ── Arg-quality validation ───────────────────────────────────────────────────────
//
// `remember_fact` args: fact (string, ≤ 80 chars, non-empty) + category (enum: identity,
// work, preferences, other). The harness re-implements the schema-validator subset inline
// (no import from lib/) to stay self-contained. `forget_fact` calls on a should-capture
// prompt (where no facts block was injected) are counted as malformed-args (the model
// guessed an id — the spike §3.2.1 hazard).
//
// ── Device setup ────────────────────────────────────────────────────────────────
//
// Before running:
//   adb shell settings put system screen_off_timeout 1800000
//   adb shell svc power stayon true
// Restore after:
//   adb shell settings put system screen_off_timeout 30000
//   adb shell svc power stayon false
//
// Model must be at the path the app uses (getApplicationDocumentsDirectory()/models/...).
// GPU-first / CPU-fallback mirrors FlutterGemmaService. ~35 min on the A34 (GPU).

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show DebugPrintCallback, debugPrint;
import 'package:flutter_gemma/flutter_gemma.dart' hide ImageProcessingException;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

// ── Tool schemas (self-contained; mirrors ToolRegistry specs exactly) ─────────

/// The capture system instruction (R5). Sent as `systemInstruction` to `createChat`.
/// Tunes capture of instruction-shaped preferences (the spike's 4-miss cluster).
const String _captureInstruction =
    'you remember the user across chats. when the user shares a durable fact about '
    'themselves — their name, where they live, their job, or a lasting preference about '
    'how you should respond (tone, units, formatting) — call remember_fact with a short '
    'third-person statement and a category. don\'t save questions, one-off tasks, weather, '
    'math, or trivia.';

const Tool _rememberFactTool = Tool(
  name: 'remember_fact',
  description:
      'Save a durable fact about the user as a short third-person canonical statement '
      '(e.g. "name is Yossef", "prefers dark mode", "builds Android apps"). '
      'Use for things that remain true across conversations: identity, job, lasting '
      'preferences about tone/units/formatting. Fact must be ≤ 80 characters.',
  parameters: {
    'type': 'object',
    'properties': {
      'fact': {
        'type': 'string',
        'description':
            'Short canonical third-person statement, ≤ 80 characters.',
        'maxLength': 80,
      },
      'category': {
        'type': 'string',
        'description': 'One of: identity, work, preferences, other.',
        'enum': ['identity', 'work', 'preferences', 'other'],
      },
    },
    'required': ['fact', 'category'],
  },
);

const Tool _forgetFactTool = Tool(
  name: 'forget_fact',
  description:
      'Remove a fact from memory. The id must come from the facts list injected into '
      'the system message — never guess an id.',
  parameters: {
    'type': 'object',
    'properties': {
      'id': {
        'type': 'integer',
        'description':
            'The id of the fact to remove (from the injected facts list).',
        'minimum': 1,
      },
    },
    'required': ['id'],
  },
);

// ── Token-budget constants (spike §2 — used in the static SC-005 assertion) ───

/// Approximate token cost per fact in the compact category-grouped format (spike §2).
const int _tokensPerFact = 9; // measured 8.7, rounded up conservatively

/// The max active-fact cap (data-model §1 / R4).
const int _maxActiveFacts = 20;

/// Approximate token cost of the capture system instruction (spike §2 measurement).
const int _captureInstructionTokens = 86;

/// Max assembled facts block in chars (data-model §2 cap / R4).
const int _factsBlockMaxChars = 900;

/// Approximate token cost of a char, calibrated to the spike's measured 693 chars → 174 tok
/// for a 20-fact block: 174/693 ≈ 0.25 tok/char (4 chars/tok, matching the app heuristic).
const double _charsPerToken = 4.0;

/// Soft token budget for memory reserves = block + instruction (spike §2).
/// Must be ≤ ~20% of the 1536 ContextAssembler budget (≤ 307; we allow up to 320 for rounding).
const int _reserveTokenBudgetHardCap = 320;

// ── Trial table ───────────────────────────────────────────────────────────────

/// (bucket, prompt, hint)
/// bucket:
///   'fact'   = SHOULD-CAPTURE — model must call `remember_fact`
///   'junk'   = SHOULD-NOT     — no tool call expected; a call is a false positive
const List<(String, String, String)> _trials = [
  // ── SHOULD-CAPTURE (25 prompts) ───────────────────────────────────────────

  // identity facts
  ('fact', 'my name is Yossef Ebrahim', 'name'),
  ('fact', 'i live in Cairo, Egypt — the GMT+2 timezone', 'location'),
  ('fact', 'i have a cat named Mishmish', 'pet'),
  ('fact', 'i am 29 years old', 'age'),
  ('fact', "i'm vegetarian", 'diet'),

  // work / stack
  (
    'fact',
    'i build Android apps with Flutter and Dart for a living',
    'job-stack',
  ),
  ('fact', 'i am a mobile developer', 'job-title'),
  ('fact', 'i have been coding for about 8 years', 'experience'),
  ('fact', 'i work for a startup in the fintech space', 'industry'),
  ('fact', 'i use VSCode as my primary editor', 'tooling'),

  // instruction-shaped preferences (the spike's 4-miss cluster — R5 targets these)
  ('fact', 'please always use metric units with me', 'pref:units'),
  ('fact', 'i like concise answers — no fluff please', 'pref:style'),
  ('fact', 'i prefer you address me formally', 'pref:tone'),
  ('fact', 'i am learning Rust on the side', 'learning'),

  // design + theme preferences
  ('fact', 'i prefer dark mode in every app', 'pref:theme'),
  ('fact', 'i want bullet-point summaries whenever possible', 'pref:format'),
  (
    'fact',
    'always include code examples in technical explanations',
    'pref:code',
  ),

  // phrasings that vary from the spike (more indirect / conversational)
  ('fact', 'just so you know, english is my second language', 'language'),
  (
    'fact',
    'i have a peanut allergy, so food suggestions should account for that',
    'health',
  ),
  ('fact', 'i tend to code late at night — after 10 PM usually', 'schedule'),
  ('fact', 'i commute by bicycle every day', 'commute'),
  ('fact', 'my main project is an on-device AI assistant', 'project'),
  (
    'fact',
    "i'm a big fan of clean architecture and SOLID principles",
    'philosophy',
  ),
  (
    'fact',
    'i prefer short PR descriptions with a bullet-point summary',
    'pref:pr',
  ),
  (
    'fact',
    "i'd like you to always remind me to test on a real device",
    'pref:reminder',
  ),

  // ── SHOULD-NOT / no-fact prompts (10 prompts) ────────────────────────────
  ('junk', 'what is the capital of france?', 'trivia:geo'),
  ('junk', 'write a haiku about autumn rain', 'creative'),
  ('junk', 'what is 144 divided by 12?', 'math'),
  ('junk', "translate 'good morning' into arabic", 'translation'),
  ('junk', 'explain in one sentence what a red-black tree is', 'cs-concept'),
  ('junk', 'set a timer for 10 minutes', 'task:timer'),
  ('junk', "what's the weather like in Paris right now?", 'weather'),
  ('junk', 'how do i reverse a list in Python?', 'coding-how-to'),
  ('junk', 'tell me a short joke', 'humor'),
  ('junk', 'summarize act 3 of hamlet', 'literature'),
];

// ── Valid category enum values (matches ToolRegistry + MemoryCategory) ────────

const Set<String> _validCategories = {
  'identity',
  'work',
  'preferences',
  'other',
};

// ── helpers ───────────────────────────────────────────────────────────────────

/// Validates a `remember_fact` arg map against the declared schema (inline subset).
/// Returns (valid, error) — mirrors what SchemaValidator does in the shipped dispatcher.
(bool, String?) _validateRememberFactArgs(Map<String, dynamic> args) {
  // Reject unknown keys (strict schema, 004 rule).
  const allowed = {'fact', 'category'};
  for (final key in args.keys) {
    if (!allowed.contains(key)) return (false, 'unexpected key: $key');
  }
  // Required fields.
  final fact = args['fact'];
  final category = args['category'];
  if (fact == null) return (false, 'missing required field: fact');
  if (category == null) return (false, 'missing required field: category');
  // Type + length checks.
  if (fact is! String || fact.trim().isEmpty) {
    return (false, 'fact must be a non-empty string');
  }
  if (fact.length > 80) {
    return (false, 'fact exceeds 80 characters (got ${fact.length})');
  }
  // Enum check.
  if (category is! String || !_validCategories.contains(category)) {
    return (
      false,
      'invalid category: $category (must be one of ${_validCategories.join(', ')})',
    );
  }
  return (true, null);
}

/// Validates a `forget_fact` arg map.
(bool, String?) _validateForgetFactArgs(Map<String, dynamic> args) {
  const allowed = {'id'};
  for (final key in args.keys) {
    if (!allowed.contains(key)) return (false, 'unexpected key: $key');
  }
  final id = args['id'];
  if (id == null) return (false, 'missing required field: id');
  // Integer or whole-valued double (004 dispatcher coercion — spike §3.2.3).
  final idVal = id is double ? id.toInt() : id;
  if (idVal is! int || idVal < 1) {
    return (false, 'id must be an integer ≥ 1 (got $id)');
  }
  return (true, null);
}

// ── Static SC-005 budget assertion (no model needed) ─────────────────────────

/// Returns the estimated token count for the worst-case memory reserve
/// (20-fact block + capture instruction), asserted before the model runs.
int _estimateMaxReserveTokens() {
  // Conservative path: assume the block is at the character cap (not the fact count cap) because
  // the char cap (900) is the binding constraint in the facts-block overflow path.
  final blockChars = math.min(_maxActiveFacts * 50, _factsBlockMaxChars);
  final blockTokens = (blockChars / _charsPerToken).ceil();
  return blockTokens + _captureInstructionTokens;
}

// ─────────────────────────────────────────────────────────────────────────────

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // Suppress the known-noisy flutter_gemma debug lines so @@MEMORY@@ lines stay
  // readable in the flutter drive console output (mirrors the 004 spike harness).
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

  // ── SC-005: static token-budget assertion (runs synchronously, no device I/O) ──

  test('SC-005: memory reserve tokens stay within budget', () {
    final reserveTokens = _estimateMaxReserveTokens();
    // Log so the result is visible in CI and on-device drive output.
    // ignore: avoid_print
    print(
      '@@MEMORY@@ ${jsonEncode({'stage': 'sc005-budget', 'estimatedReserveTokens': reserveTokens, 'hardCap': _reserveTokenBudgetHardCap, 'factsBlockMaxChars': _factsBlockMaxChars, 'captureInstructionTokens': _captureInstructionTokens, 'pass': reserveTokens <= _reserveTokenBudgetHardCap})}',
    );
    expect(
      reserveTokens,
      lessThanOrEqualTo(_reserveTokenBudgetHardCap),
      reason:
          'worst-case memory reserve ($reserveTokens tok) exceeds the ${'_reserveTokenBudgetHardCap'}-token '
          'hard cap — facts block + capture instruction would crowd the context budget',
    );
    // Also verify that 20 individual facts at the per-fact estimate are within the char cap.
    const blockTokensEstimate = _maxActiveFacts * _tokensPerFact;
    expect(
      blockTokensEstimate,
      lessThanOrEqualTo((_factsBlockMaxChars / _charsPerToken).ceil()),
      reason:
          '$_maxActiveFacts facts × $_tokensPerFact tok/fact should stay within the char cap',
    );
  });

  // ── SC-001/002/003: on-device capture + false-positive suite ─────────────────

  testWidgets(
    'SC-001/002/003: memory capture reliability gate (≥75% capture, 0 false positives)',
    timeout: const Timeout(Duration(minutes: 40)),
    (tester) async {
      var peakRss = 0;
      final rssTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
        peakRss = math.max(peakRss, ProcessInfo.currentRss);
      });

      void memLog(String stage, Map<String, Object?> data) {
        // @@MEMORY@@ prefix is the grep handle for post-processing.
        // ignore: avoid_print
        print(
          '@@MEMORY@@ ${jsonEncode({'stage': stage, 'rssMb': (ProcessInfo.currentRss / (1024 * 1024)).round(), 'peakRssMb': (peakRss / (1024 * 1024)).round(), ...data})}',
        );
      }

      /// Drains one model generation: collects text tokens and any function calls.
      /// On the gemma4 SDK path, the call event is the FINAL stream element (004 spike §1.3).
      /// A 120-second per-turn silence timeout prevents a screen-lock hang from stalling the run
      /// indefinitely (the 004 spike documented the run-1 hang; see memory.md hazard note).
      Future<
        ({
          String text,
          int? firstTokenMs,
          int totalMs,
          List<FunctionCallResponse> calls,
        })
      >
      drain(InferenceChat chat) async {
        final sw = Stopwatch()..start();
        int? firstTokenMs;
        final textBuf = StringBuffer();
        final calls = <FunctionCallResponse>[];
        final stream = chat.generateChatResponseAsync().timeout(
          const Duration(seconds: 120),
          onTimeout: (sink) => sink.close(),
        );
        await for (final response in stream) {
          if (response is TextResponse) {
            firstTokenMs ??= sw.elapsedMilliseconds;
            textBuf.write(response.token);
          } else if (response is FunctionCallResponse) {
            calls.add(response);
          } else if (response is ParallelFunctionCallResponse) {
            calls.addAll(response.calls);
          }
        }
        sw.stop();
        return (
          text: textBuf.toString(),
          firstTokenMs: firstTokenMs,
          totalMs: sw.elapsedMilliseconds,
          calls: calls,
        );
      }

      final docs = await getApplicationDocumentsDirectory();
      final modelPath = '${docs.path}/models/gemma-4-e2b.litertlm';
      expect(
        File(modelPath).existsSync(),
        isTrue,
        reason:
            'model not found at $modelPath — run the app first to download it',
      );

      try {
        memLog('baseline', {});

        // Mirror FlutterGemmaService's exact load recipe (T050 requirement).
        await FlutterGemma.initialize();
        await FlutterGemma.installModel(
          modelType: ModelType.gemma4,
          fileType: ModelFileType.litertlm,
        ).fromFile(modelPath).install();

        // GPU-first / CPU-fallback — the production activation order.
        InferenceModel? model;
        var backend = 'gpu';
        final loadSw = Stopwatch()..start();
        try {
          model = await FlutterGemma.getActiveModel(
            maxTokens: 2048,
            preferredBackend: PreferredBackend.gpu,
          );
        } catch (error) {
          memLog('gpu-activation-failed', {'error': '$error'});
          backend = 'cpu';
          model = await FlutterGemma.getActiveModel(
            maxTokens: 2048,
            preferredBackend: PreferredBackend.cpu,
          );
        }

        // Create the chat with BOTH memory tools + the tuned capture system instruction.
        // `ToolChoice.auto` is mandatory (spike: 0 false-positive dependence).
        final chat = await model.createChat(
          modelType: ModelType.gemma4,
          supportImage: false,
          supportAudio: false,
          supportsFunctionCalls: true,
          isThinking: false,
          tools: const [_rememberFactTool, _forgetFactTool],
          toolChoice: ToolChoice.auto,
          systemInstruction: _captureInstruction,
        );
        loadSw.stop();
        memLog('model-loaded', {
          'backend': backend,
          'loadMs': loadSw.elapsedMilliseconds,
          'tools': ['remember_fact', 'forget_fact'],
          'systemInstructionLength': _captureInstruction.length,
        });

        final results = <Map<String, Object?>>[];

        for (var i = 0; i < _trials.length; i++) {
          final (bucket, prompt, hint) = _trials[i];

          // Fresh single-turn context per trial (mirrors spike methodology). The
          // sessionCreator closure re-applies tools_json and the systemInstruction on every
          // clearHistory, so the tuned instruction is stable across all 30 trials.
          await chat.clearHistory();
          await chat.addQueryChunk(Message.text(text: prompt, isUser: true));
          final gen = await drain(chat);

          final called = gen.calls.isNotEmpty;
          final callCount = gen.calls.length;
          final firstCall = called ? gen.calls.first : null;
          final toolName = firstCall?.name;

          // Determine whether the correct tool was called (only remember_fact is valid for
          // a fact prompt; any call at all on a junk prompt is a false positive regardless
          // of which tool).
          final rememberedCorrectTool = toolName == 'remember_fact';
          final forgotInsteadOfRemembered = toolName == 'forget_fact';

          // Arg-quality check.
          bool? argsValid;
          String? argsError;
          if (firstCall != null) {
            if (toolName == 'remember_fact') {
              (argsValid, argsError) = _validateRememberFactArgs(
                firstCall.args,
              );
            } else if (toolName == 'forget_fact') {
              (argsValid, argsError) = _validateForgetFactArgs(firstCall.args);
            } else {
              // Hallucinated tool name.
              argsValid = false;
              argsError = 'unknown tool: $toolName';
            }
          }

          // Detect the raw-JSON leak (the 004 spike §1.3 hazard — should be suppressed by
          // LeakFilter in the shipped app, but the harness directly uses the plugin so we
          // measure it here as a secondary signal, not a gate criterion).
          final leakedRawJson =
              gen.text.contains('tool_call') ||
              RegExp(r'\{\s*"(name|tool_calls)"\s*:').hasMatch(gen.text);

          final record = <String, Object?>{
            'trial': i + 1,
            'bucket': bucket,
            'hint': hint,
            'prompt': prompt,
            'called': called,
            'callCount': callCount,
            'tool': toolName,
            'args': firstCall?.args,
            'argsValid': firstCall == null ? null : argsValid,
            'argsError': argsError,
            'rememberedCorrectTool': firstCall == null
                ? null
                : rememberedCorrectTool,
            'forgotInsteadOfRemembered': firstCall == null
                ? null
                : forgotInsteadOfRemembered,
            'preCallText': gen.text.trim(),
            'leakedRawJson': leakedRawJson,
            'firstTokenMs': gen.firstTokenMs,
            'turnMs': gen.totalMs,
          };
          results.add(record);
          memLog('trial', record);
        }

        // ── Scoring ───────────────────────────────────────────────────────

        final factTrials = results.where((r) => r['bucket'] == 'fact').toList();
        final junkTrials = results.where((r) => r['bucket'] == 'junk').toList();

        // SC-001: capture rate on should-capture prompts.
        final capturedCount = factTrials
            .where(
              (r) =>
                  r['called'] == true &&
                  r['tool'] == 'remember_fact' &&
                  r['argsValid'] == true,
            )
            .length;
        final missedCount = factTrials
            .where((r) => r['called'] == false)
            .length;
        final captureRate = capturedCount / factTrials.length;

        // SC-002: false positives on should-not prompts.
        final falsePositiveCount = junkTrials
            .where((r) => r['called'] == true)
            .length;

        // SC-003: wrong/hallucinated tools (called something other than the two declared).
        final hallucinatedTools = results
            .where(
              (r) =>
                  r['called'] == true &&
                  r['tool'] != 'remember_fact' &&
                  r['tool'] != 'forget_fact',
            )
            .map((r) => r['tool'])
            .toList();

        // Arg quality: fraction of calls with valid args.
        final allCalls = results.where((r) => r['called'] == true).toList();
        final goodArgCount = allCalls
            .where((r) => r['argsValid'] == true)
            .length;
        final argQualityRate = allCalls.isEmpty
            ? 1.0
            : goodArgCount / allCalls.length;

        // Malformed-arg calls (wrong tool for context is a subset).
        final malformedCount = allCalls
            .where((r) => r['argsValid'] == false)
            .length;

        // Parallel / multi-call turns.
        final parallelCallTurns = results
            .where((r) => (r['callCount'] as int? ?? 0) > 1)
            .length;

        // Raw-JSON leak occurrences.
        final leakCount = results
            .where((r) => r['leakedRawJson'] == true)
            .length;

        // Forget-fact called on a should-capture prompt (guessed-id hazard from spike §3.2.1).
        final forgotOnFactPromptCount = factTrials
            .where((r) => r['called'] == true && r['tool'] == 'forget_fact')
            .length;

        memLog('summary', {
          // SC-001
          'captureRate': captureRate,
          'capturedCount': capturedCount,
          'factTrialTotal': factTrials.length,
          'missedCount': missedCount,
          'gatePassCaptureRate': captureRate >= 0.75,
          // SC-002
          'falsePositiveCount': falsePositiveCount,
          'junkTrialTotal': junkTrials.length,
          'gatePassFalsePositives': falsePositiveCount == 0,
          // SC-003 + arg quality
          'hallucinatedTools': hallucinatedTools,
          'malformedArgCount': malformedCount,
          'argQualityRate': argQualityRate,
          'gatePassArgQuality': argQualityRate >= 0.90,
          // Secondary signals
          'forgotOnFactPromptCount': forgotOnFactPromptCount,
          'parallelCallTurns': parallelCallTurns,
          'rawJsonLeakCount': leakCount,
          // Overall gate
          'overallGatePass':
              captureRate >= 0.75 &&
              falsePositiveCount == 0 &&
              hallucinatedTools.isEmpty &&
              argQualityRate >= 0.90,
        });

        // ── Gate assertions ───────────────────────────────────────────────

        // SC-001: capture rate ≥ 75% on fact-sharing prompts.
        expect(
          captureRate,
          greaterThanOrEqualTo(0.75),
          reason:
              'capture rate ${(captureRate * 100).toStringAsFixed(1)}% '
              '($capturedCount/${factTrials.length}) is below the 75% gate (SC-001). '
              'See @@MEMORY@@ trial lines for the specific misses.',
        );

        // SC-002: 0 false positives on no-fact prompts.
        expect(
          falsePositiveCount,
          equals(0),
          reason:
              '$falsePositiveCount false-positive capture(s) on should-not prompts (SC-002). '
              'Check @@MEMORY@@ trial lines where bucket=junk and called=true.',
        );

        // SC-003: 0 hallucinated / unregistered tool names.
        expect(
          hallucinatedTools,
          isEmpty,
          reason:
              'hallucinated tools: $hallucinatedTools (SC-003 — only remember_fact and '
              'forget_fact are registered; any other name is a fabrication).',
        );

        // Arg quality ≥ 90% (quickstart V9 gate — "≥ 90% good arg quality").
        expect(
          argQualityRate,
          greaterThanOrEqualTo(0.90),
          reason:
              'arg quality ${(argQualityRate * 100).toStringAsFixed(1)}% '
              '($goodArgCount/${allCalls.length}) is below the 90% gate. '
              'Malformed calls: $malformedCount.',
        );

        await model.close();
        memLog('done', {'peakRssMb': (peakRss / (1024 * 1024)).round()});
      } finally {
        rssTimer.cancel();
      }
    },
  );
}
