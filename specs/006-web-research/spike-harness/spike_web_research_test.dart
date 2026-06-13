// SPIKE HARNESS — 006-web-research (DO NOT SHIP — throwaway artifact)
//
// Phase 0 device spike for the web-research feature.  Measures three things
// against the REAL Gemma 4 E2B model via the existing flutter_gemma 0.15.3
// path (same load recipe as the 004/005 spikes):
//
//   (A) Multi-step tool-chain reliability
//       ~20 prompts that SHOULD trigger search → fetch → answer.
//       Records per trial: did it emit the 1st tool call (search)?  Did it
//       chain to a 2nd call (fetch)?  Did it stall/loop after the 2nd call?
//       Did it produce a final grounded answer?
//
//   (B) On-device summarization latency
//       Feed the model a canned ~2 kB extracted page text and ask it to
//       summarize.  Timed from the first addQueryChunk to the last token.
//       This feeds the "snippets-only vs fetch+summarize" budget decision.
//
//   (C) End-to-end latency (simulated pipeline)
//       query → search tool call → fetch tool call → grounded answer.
//       Total wall-clock time: model inference + stub tool overhead only
//       (no real network).
//
// NETWORK: all tool calls are answered with FAKE/STUB canned data (defined in
// the _CannedTools section below) so the harness measures MODEL behavior, not
// live network latency.  The stub returns the same search results and page
// text on every call.
//
// HOW TO RUN (see README.md for the full command):
//   flutter drive \
//     --driver=test_driver/integration_test.dart \
//     --target=integration_test/spike_web_research_test.dart \
//     -d <device-id>
//
// DO NOT run as:
//   flutter test integration_test/spike_web_research_test.dart
// — flutter test uninstalls the app and wipes the 2.4 GB model + DB.
//
// PLACEMENT: this file lives in specs/006-web-research/spike-harness/ and is
// NOT wired into the app's integration_test/ directory.  To run it, copy (or
// symlink) it to integration_test/spike_web_research_test.dart, run the drive
// command, then remove it.  It is a spike artifact — it does NOT belong in the
// shipped test suite.
//
// LOG FORMAT: every measurement emits a `@@WEB@@` JSON line to stdout so the
// results can be grepped after the run.
//
//   grep '@@WEB@@' flutter_drive_output.txt | python3 -c \
//     "import sys,json; [print(json.dumps(json.loads(l.split('@@WEB@@')[1]),indent=2)) for l in sys.stdin if '@@WEB@@' in l]"
//
// See README.md for RESULT TABLES to fill from the real run.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show DebugPrintCallback, debugPrint;
import 'package:flutter_gemma/flutter_gemma.dart' hide ImageProcessingException;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

// ── Tool schemas (self-contained; NOT imported from lib/) ────────────────────
//
// These mirror the two tool signatures proposed for the 006 feature.
// They are declared here so the harness is fully self-contained and doesn't
// depend on any shipped code that has not been written yet.
//
// web_search: submit a search query, get back a list of result snippets.
// fetch_page: fetch a URL, get back extracted plain-text content.

const Tool _webSearchTool = Tool(
  name: 'web_search',
  description:
      'Search the web for current information on a topic. '
      'Returns a list of search result snippets (title + URL + snippet text). '
      'Use this when the user asks about something that may have changed recently '
      'or that is outside your training data.',
  parameters: {
    'type': 'object',
    'properties': {
      'query': {
        'type': 'string',
        'description':
            'The search query string. Keep it short and specific (≤ 100 characters).',
        'maxLength': 100,
      },
    },
    'required': ['query'],
  },
);

const Tool _fetchPageTool = Tool(
  name: 'fetch_page',
  description:
      'Fetch the text content of a web page at the given URL. '
      'Returns the extracted plain-text body of the page (HTML stripped). '
      'Use this to read the full content of a search result you want to summarize '
      'or cite in detail.',
  parameters: {
    'type': 'object',
    'properties': {
      'url': {
        'type': 'string',
        'description': 'The full URL (https://...) of the page to fetch.',
      },
    },
    'required': ['url'],
  },
);

// ── System instruction ───────────────────────────────────────────────────────
//
// A short, precise instruction that directs the model to use the two tools
// for questions about current events / recent information.  Deliberately kept
// to one paragraph so token cost is negligible.
const String _systemInstruction =
    'You have access to two tools: web_search and fetch_page. '
    'Use web_search when the user asks about current events, recent news, '
    'or anything that may have changed after your training data. '
    'If a search result snippet is not detailed enough, call fetch_page on the '
    'most relevant URL to read the full text. '
    'Always ground your final answer in the tool results you received, and '
    'cite the source URL when possible. '
    'Do not make up information that was not in the tool results.';

// ── Canned stub tool responses ───────────────────────────────────────────────
//
// ALL tool calls are answered with this static data.  The harness measures
// MODEL behavior (does it chain calls correctly?  does it produce grounded
// answers?) not live network round-trip times.
//
// Stub design principles:
//   * The search result contains a plausible URL that fetch_page can be
//     called on — so a 2-step chain (search then fetch) is coherent.
//   * The page text (~2 kB) is long enough to stress the summarization path
//     but short enough to fit in the context budget (≤ 512 tokens ≈ ≤ 2 kB at
//     4 chars/token — the 006 budget decision feeds directly from this).
//   * A "grounding sentinel" phrase ("42 confirmed cases") appears ONLY in the
//     page text, so the harness can verify the model echoed stub content.

/// Stub response for any web_search call.
const Map<String, Object?> _cannedSearchResult = {
  'query': '(stub)',
  'results': [
    {
      'title': 'Stub News: Example Event Coverage — Example Times',
      'url': 'https://example-times.invalid/stub-article-2026',
      'snippet':
          'Researchers confirmed 42 cases of the phenomenon in a new study. '
          'The study was conducted across 10 countries between January and April 2026. '
          'Full details are available in the article.',
    },
    {
      'title': 'Overview: What Is the Phenomenon? — Stub Encyclopedia',
      'url': 'https://stub-encyclopedia.invalid/phenomenon',
      'snippet':
          'The phenomenon was first described in 1992. Recent studies have expanded '
          'the understanding of its causes and effects.',
    },
    {
      'title': 'Expert Commentary — Stub Science Weekly',
      'url': 'https://stub-science.invalid/expert-commentary-2026',
      'snippet':
          'Leading experts weigh in on the 2026 findings. "This changes our entire '
          'model," said one researcher.',
    },
  ],
};

/// Stub page text (~2 kB) for any fetch_page call.
/// Injected as the `content` field in the tool response.
///
/// The sentinel phrase "42 confirmed cases" appears only here (not in the
/// search snippet above) so a grounded answer that references it proves the
/// model read the fetch result, not just the search snippet.
const String _cannedPageText =
    'Example Times — Stub Article (2026-04-15)\n'
    '\n'
    'STUB CITY — A new study published last week in the Journal of Stub Research '
    'has confirmed 42 confirmed cases of the phenomenon in a cross-national cohort '
    'spanning 10 countries.  The study, led by Dr. Ada Lovelace of Stub University, '
    'followed 1,200 participants over a 16-week period from January to April 2026.\n'
    '\n'
    'Key findings:\n'
    '• 42 confirmed cases were identified, representing a 14% prevalence rate.\n'
    '• Cases were distributed across all age groups, with a slight skew toward the '
    '  35–50 demographic (31% of confirmed cases).\n'
    '• Early intervention was associated with a 60% reduction in severity.\n'
    '• Three previously unknown risk factors were identified: factor A, factor B, '
    '  and factor C.\n'
    '\n'
    '"This is the most comprehensive dataset we have seen on this topic," said '
    'Dr. Lovelace in a press conference on Tuesday.  "The 42 confirmed cases give '
    'us strong statistical power to draw conclusions that previous smaller studies '
    'could not support."\n'
    '\n'
    'The study was funded by the Stub Foundation for Research (grant #SFR-2025-0042) '
    'and conducted in partnership with institutions in the United States, Germany, '
    'Japan, Brazil, Australia, India, France, Canada, Kenya, and South Korea.\n'
    '\n'
    'Critics of the study note that the 16-week window may be too short to capture '
    'long-term effects.  A follow-up study is planned for 2027.  Full methodology '
    'is available in the supplementary materials linked from the journal article.\n'
    '\n'
    'For media inquiries: press@example-times.invalid\n'
    'Published: 2026-04-15 | Last updated: 2026-04-16 | Word count: ~320\n';

const Map<String, Object?> _cannedFetchResult = {
  'url': 'https://example-times.invalid/stub-article-2026',
  'content': _cannedPageText,
  'contentLength': 1843, // approximate
  'fetchedAt': '2026-06-12T00:00:00Z',
};

/// Sentinel phrase that only appears in _cannedPageText (not in any snippet).
const String _groundingSentinel = '42 confirmed cases';

// ── Tool-chain trial table ───────────────────────────────────────────────────
//
// ~20 prompts spanning several search-worthy categories.  Every prompt SHOULD
// trigger at least a web_search call; ideally it chains to fetch_page for the
// first URL.  The "expect_chain" hint is informational — the gate criterion is
// "1st tool call emitted", not "chain completed" (the chain rate is the
// measurement we are trying to learn).
//
// bucket:
//   'search'  — SHOULD call web_search; may or may not chain to fetch_page
//   'junk'    — SHOULD answer from training data only (no tool call expected)
//
// Fields: (bucket, prompt, hint)
const List<(String, String, String)> _toolChainTrials = [
  // ── SHOULD-SEARCH prompts (20) ────────────────────────────────────────────

  // News / current events
  ('search', 'what are the latest developments in the Gaza ceasefire talks?',
      'news:ceasefire'),
  ('search', 'what happened in the US stock market yesterday?', 'news:markets'),
  ('search', 'what is the current status of the OpenAI GPT-5 release?',
      'news:ai'),
  ('search', 'who won the most recent Champions League final?', 'news:sports'),
  ('search',
      'what are the new features in the latest Android release?',
      'news:android'),

  // Research / factual recency
  ('search',
      'what does the latest research say about the effects of microplastics on human health?',
      'research:health'),
  ('search',
      'what are the most recent climate change projections from the IPCC?',
      'research:climate'),
  ('search', 'what is the current inflation rate in Egypt?', 'research:econ'),
  ('search',
      'are there any new Dart language features announced for 2026?',
      'research:dart'),
  ('search',
      'what is the latest stable version of Flutter and what changed?',
      'research:flutter'),

  // Price / availability (clearly time-sensitive)
  ('search', 'what is the current price of a Samsung Galaxy S25?',
      'price:phone'),
  ('search', 'how much does a one-bedroom flat cost in Cairo right now?',
      'price:realestate'),

  // "Who is" / recent appointments
  ('search', 'who is the current CEO of OpenAI?', 'whois:ceo'),
  ('search',
      'who won the 2026 Academy Award for Best Picture?',
      'whois:awards'),

  // Local / "near me" that requires search to be useful
  ('search', 'what are the visiting hours at the Cairo Museum this week?',
      'local:museum'),
  ('search', 'is the Suez Canal fully operational right now?', 'local:canal'),

  // Developer / tooling currency
  ('search', 'what are the known breaking changes in flutter_gemma 0.16.x?',
      'dev:flutter_gemma'),
  ('search',
      'what is the latest LTS release of Node.js and when does it expire?',
      'dev:nodejs'),
  ('search',
      'has Google released any new Gemma models since Gemma 3?',
      'dev:gemma'),
  ('search', 'what were the highlights of Google I/O 2026?', 'dev:google-io'),

  // ── SHOULD-NOT prompts (5) — expect NO tool call ──────────────────────────
  // These are answered from training data / general knowledge.
  ('junk', 'what is the capital of France?', 'trivia:geo'),
  ('junk', 'explain in one sentence what a binary search tree is',
      'cs-concept'),
  ('junk', 'write a haiku about autumn rain', 'creative'),
  ('junk', 'what is 2 to the power of 10?', 'math'),
  ('junk', 'translate "good morning" into Arabic', 'translation'),
];

// ── Summarization latency probe texts ────────────────────────────────────────
//
// Three text samples of increasing length.  Each is fed to the model with the
// prompt "Summarize this article in 3 bullet points:" and the full text inline.
// The turn is timed from addQueryChunk to last TextResponse token.
//
// Lengths are approximate; the exact token count is context-budget relevant
// (the 006 budget decision: snippets-only ≈ short text, fetch+summarize ≈ long
// text).

/// ~500 chars / ~125 tokens — typical search-result snippet.
const String _summaryTextShort =
    'Researchers at Stub University confirmed 42 cases of the phenomenon in a new '
    'cross-national study spanning 10 countries.  The 16-week study, conducted from '
    'January to April 2026, identified three new risk factors and found that early '
    'intervention reduced severity by 60%.  "This is the most comprehensive dataset '
    'we have seen," said lead researcher Dr. Ada Lovelace.  A follow-up study is '
    'planned for 2027.';

/// ~1 kB / ~250 tokens — medium fetch extract.
const String _summaryTextMedium =
    'STUB CITY — A new study published in the Journal of Stub Research has confirmed '
    '42 confirmed cases of the phenomenon across 10 countries.  The study followed '
    '1,200 participants over 16 weeks (January–April 2026).\n'
    '\n'
    'Key findings: (1) 42 confirmed cases, 14% prevalence.  (2) Slight skew toward '
    'ages 35–50.  (3) Early intervention cut severity by 60%.  (4) Three new risk '
    'factors identified.\n'
    '\n'
    '"This changes our entire model," said Dr. Lovelace.  Critics note the 16-week '
    'window may miss long-term effects.  A 2027 follow-up is planned.\n'
    '\n'
    'The study was funded by the Stub Foundation (grant SFR-2025-0042) and conducted '
    'in partnership with institutions in the US, Germany, Japan, Brazil, Australia, '
    'India, France, Canada, Kenya, and South Korea.  Full methodology is in the '
    'supplementary materials.  Media: press@example-times.invalid.';

/// ~2 kB / ~500 tokens — the full canned page text (same as _cannedPageText).
/// This is the realistic worst case for fetch+summarize in the first version.
const String _summaryTextLong = _cannedPageText;

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Drains a model generation stream.  Returns text content, timing, and all
/// tool-call events.  The 120-second silence timeout guards against a
/// screen-lock hang (the 004 spike documented this hazard; memory.md).
///
/// On the gemma4 SDK path the FunctionCallResponse is the LAST stream element
/// (004 spike §1.3), so we collect all events and return them all.
Future<
  ({
    String text,
    int? firstTokenMs,
    int totalMs,
    List<FunctionCallResponse> calls,
  })
>
_drain(InferenceChat chat) async {
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

/// Answer a tool call with the appropriate stub response and drain the resumed
/// generation.  Returns the full resume result.
///
/// Uses Message.toolResponse (the `<tool_response>` wrapper path on Android
/// .litertlm — 004 spike §1.4) followed by a fresh generateChatResponseAsync
/// call.  This is the same manual loop documented in the spike findings.
Future<
  ({
    String text,
    int? firstTokenMs,
    int totalMs,
    List<FunctionCallResponse> calls,
  })
>
_answerToolAndResume(
  InferenceChat chat,
  FunctionCallResponse call,
) async {
  // Pick the canned response based on tool name.  Unknown tool names get an
  // error response so the model sees a valid but empty result (never a crash).
  final Map<String, Object?> stubResponse;
  switch (call.name) {
    case 'web_search':
      stubResponse = Map<String, Object?>.from(_cannedSearchResult);
    case 'fetch_page':
      stubResponse = Map<String, Object?>.from(_cannedFetchResult);
    default:
      stubResponse = {'error': 'unknown tool: ${call.name}'};
  }

  await chat.addQuery(
    Message.toolResponse(toolName: call.name, response: stubResponse),
  );
  return _drain(chat);
}

/// Log a structured @@WEB@@ line (grep handle for post-processing).
void _webLog(String stage, Map<String, Object?> data) {
  print(
    '@@WEB@@ ${jsonEncode({
      'stage': stage,
      'rssMb': (ProcessInfo.currentRss / (1024 * 1024)).round(),
      ...data,
    })}',
  );
}

// ── Main ─────────────────────────────────────────────────────────────────────

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // Suppress flutter_gemma's hot-path log spam (mirrors 004/005 spikes).
  // The plugin debugPrints several lines PER TOKEN including the full history,
  // which makes @@WEB@@ lines unreadable.
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

  // ── (B) Summarization-latency probe — no tool calls, pure text ──────────
  //
  // Measured BEFORE the tool-chain suite so it runs on a fresh session with no
  // accumulated history.  A separate createChat is used (no tools declared) to
  // isolate the text-only generation path.

  testWidgets(
    '(B) summarization latency: short / medium / long text',
    timeout: const Timeout(Duration(minutes: 15)),
    (tester) async {
      var peakRss = 0;
      final rssTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
        peakRss = math.max(peakRss, ProcessInfo.currentRss);
      });

      try {
        final docs = await getApplicationDocumentsDirectory();
        final modelPath = '${docs.path}/models/gemma-4-e2b.litertlm';
        expect(
          File(modelPath).existsSync(),
          isTrue,
          reason:
              'model not found at $modelPath — run the app first to download it',
        );

        _webLog('B-baseline', {});

        // Mirror FlutterGemmaService's load recipe exactly (same as 004/005 spikes).
        await FlutterGemma.initialize();
        await FlutterGemma.installModel(
          modelType: ModelType.gemma4,
          fileType: ModelFileType.litertlm,
        ).fromFile(modelPath).install();

        InferenceModel? model;
        var backend = 'gpu';
        final loadSw = Stopwatch()..start();
        try {
          model = await FlutterGemma.getActiveModel(
            maxTokens: 2048,
            preferredBackend: PreferredBackend.gpu,
          );
        } catch (error) {
          _webLog('B-gpu-activation-failed', {'error': '$error'});
          backend = 'cpu';
          model = await FlutterGemma.getActiveModel(
            maxTokens: 2048,
            preferredBackend: PreferredBackend.cpu,
          );
        }
        loadSw.stop();
        _webLog('B-model-loaded', {
          'backend': backend,
          'loadMs': loadSw.elapsedMilliseconds,
        });

        // Text-only chat — no tools declared.
        final chat = await model.createChat(
          modelType: ModelType.gemma4,
          supportImage: false,
          supportAudio: false,
          supportsFunctionCalls: false,
          isThinking: false,
        );

        // Run three text lengths in sequence.
        for (final (label, text) in [
          ('short-~125tok', _summaryTextShort),
          ('medium-~250tok', _summaryTextMedium),
          ('long-~500tok', _summaryTextLong),
        ]) {
          await chat.clearHistory();
          final prompt =
              'Summarize the following article in 3 concise bullet points:\n\n$text';
          final promptChars = prompt.length;

          await chat.addQueryChunk(Message.text(text: prompt, isUser: true));
          final gen = await _drain(chat);

          _webLog('B-summary-result', {
            'label': label,
            'promptChars': promptChars,
            'summaryChars': gen.text.length,
            'firstTokenMs': gen.firstTokenMs,
            'totalMs': gen.totalMs,
            'outputTokensEstimate': (gen.text.length / 4).ceil(),
          });
        }

        await model.close();
        _webLog('B-done', {'peakRssMb': (peakRss / (1024 * 1024)).round()});
      } finally {
        rssTimer.cancel();
      }
    },
  );

  // ── (A) + (C) Tool-chain reliability and end-to-end latency ─────────────
  //
  // Runs after (B).  Uses a separate model load with BOTH web tools registered.
  // Each trial:
  //   1. Fresh context (clearHistory).
  //   2. Emit the prompt.
  //   3. Drain generation — record whether the 1st call was web_search.
  //   4. If a search call was made, answer with _cannedSearchResult and drain
  //      the resumed generation — record whether it then called fetch_page.
  //   5. If a fetch call was made, answer with _cannedFetchResult and drain
  //      again — record whether the model produced a grounded final answer.
  //   6. If the resumed generation makes ANOTHER tool call (loop), record stall.
  //
  // The harness performs at most MAX_CHAIN_DEPTH rounds per trial to prevent
  // infinite loops.  Any call beyond depth 2 is recorded as a "loop".

  testWidgets(
    '(A)+(C) tool-chain reliability and end-to-end latency',
    timeout: const Timeout(Duration(minutes: 40)),
    (tester) async {
      var peakRss = 0;
      final rssTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
        peakRss = math.max(peakRss, ProcessInfo.currentRss);
      });

      try {
        final docs = await getApplicationDocumentsDirectory();
        final modelPath = '${docs.path}/models/gemma-4-e2b.litertlm';
        expect(
          File(modelPath).existsSync(),
          isTrue,
          reason:
              'model not found at $modelPath — run the app first to download it',
        );

        _webLog('AC-baseline', {});

        await FlutterGemma.initialize();
        await FlutterGemma.installModel(
          modelType: ModelType.gemma4,
          fileType: ModelFileType.litertlm,
        ).fromFile(modelPath).install();

        InferenceModel? model;
        var backend = 'gpu';
        final loadSw = Stopwatch()..start();
        try {
          model = await FlutterGemma.getActiveModel(
            maxTokens: 2048,
            preferredBackend: PreferredBackend.gpu,
          );
        } catch (error) {
          _webLog('AC-gpu-activation-failed', {'error': '$error'});
          backend = 'cpu';
          model = await FlutterGemma.getActiveModel(
            maxTokens: 2048,
            preferredBackend: PreferredBackend.cpu,
          );
        }
        loadSw.stop();

        // Chat with BOTH web tools + the system instruction.
        // ToolChoice.auto — same as 004/005; the model decides when to call.
        final chat = await model.createChat(
          modelType: ModelType.gemma4,
          supportImage: false,
          supportAudio: false,
          supportsFunctionCalls: true,
          isThinking: false,
          tools: const [_webSearchTool, _fetchPageTool],
          toolChoice: ToolChoice.auto,
          systemInstruction: _systemInstruction,
        );
        _webLog('AC-model-loaded', {
          'backend': backend,
          'loadMs': loadSw.elapsedMilliseconds,
          'tools': ['web_search', 'fetch_page'],
          'systemInstructionLength': _systemInstruction.length,
        });

        final results = <Map<String, Object?>>[];

        for (var i = 0; i < _toolChainTrials.length; i++) {
          final (bucket, prompt, hint) = _toolChainTrials[i];

          await chat.clearHistory();
          final e2eSw = Stopwatch()..start();

          // ── Step 1: initial generation ──────────────────────────────────
          await chat.addQueryChunk(Message.text(text: prompt, isUser: true));
          final step1 = await _drain(chat);

          final emitted1stCall = step1.calls.isNotEmpty;
          final firstCallName =
              step1.calls.isNotEmpty ? step1.calls.first.name : null;
          final firstCallArgs =
              step1.calls.isNotEmpty ? step1.calls.first.args : null;

          // For junk prompts: we only care that no tool was called.
          if (bucket == 'junk') {
            e2eSw.stop();
            final record = <String, Object?>{
              'trial': i + 1,
              'bucket': bucket,
              'hint': hint,
              'prompt': prompt,
              'emitted1stCall': emitted1stCall,
              'firstCallName': firstCallName,
              'falsePositive': emitted1stCall,
              'e2eMs': e2eSw.elapsedMilliseconds,
              'answerPresent': step1.text.trim().isNotEmpty,
            };
            results.add(record);
            _webLog('AC-trial', record);
            continue;
          }

          // ── Step 2: if a search call was emitted, answer it ─────────────
          bool chainedToFetch = false;
          bool stalled = false;
          bool looped = false;
          bool finalAnswerPresent = false;
          bool answerGrounded = false;
          int? step2TotalMs;
          int? step3TotalMs;
          String? fetchCallUrl;
          int depth = 1;

          var currentCalls = step1.calls;
          var currentText = step1.text;

          while (currentCalls.isNotEmpty && depth <= 3) {
            final call = currentCalls.first;

            if (depth == 1 && call.name != 'web_search') {
              // Model called something other than web_search first — unexpected.
              // Record and break; it's treated as a stall (didn't follow the
              // search-first convention).
              stalled = true;
              break;
            }

            if (depth == 2) {
              // Second call should be fetch_page.
              if (call.name == 'fetch_page') {
                chainedToFetch = true;
                fetchCallUrl = call.args['url'] as String?;
              } else if (call.name == 'web_search') {
                // Model searched again instead of fetching — unexpected loop.
                looped = true;
              } else {
                stalled = true;
              }
            }

            if (depth == 3) {
              // Any call at depth 3 is a loop — the model should have produced
              // a final text answer after at most 2 tool calls.
              looped = true;
              break;
            }

            // Answer the call and drain the resumed generation.
            final resume = await _answerToolAndResume(chat, call);
            if (depth == 1) step2TotalMs = resume.totalMs;
            if (depth == 2) step3TotalMs = resume.totalMs;

            currentCalls = resume.calls;
            currentText = resume.text;
            depth++;
          }

          // Final answer is whatever text we have after the last tool round.
          finalAnswerPresent = currentText.trim().isNotEmpty;

          // Grounding check: the sentinel phrase from the canned page text must
          // appear in the final answer if the model fetched the page.
          if (chainedToFetch) {
            answerGrounded = currentText.contains(_groundingSentinel);
          }

          // Stall: the chain stopped without a final text answer.
          if (!finalAnswerPresent && !looped) stalled = true;

          e2eSw.stop();

          final record = <String, Object?>{
            'trial': i + 1,
            'bucket': bucket,
            'hint': hint,
            'prompt': prompt,
            // Tool-chain metrics (measurement A):
            'emitted1stCall': emitted1stCall,
            'firstCallName': firstCallName,
            'firstCallArgs': firstCallArgs,
            'chainedToFetch': chainedToFetch,
            'fetchCallUrl': fetchCallUrl,
            'stalled': stalled,
            'looped': looped,
            'chainDepth': depth - 1,
            // Answer quality:
            'finalAnswerPresent': finalAnswerPresent,
            'answerGrounded': answerGrounded,
            // Latency breakdown (measurement C):
            'step1Ms': step1.totalMs,
            'step2Ms': step2TotalMs,
            'step3Ms': step3TotalMs,
            'e2eMs': e2eSw.elapsedMilliseconds,
            // Raw-JSON leak (secondary signal; should be suppressed by LeakFilter
            // in the shipped app but measured here since the harness is direct):
            'leakedRawJson':
                step1.text.contains('tool_call') ||
                RegExp(r'\{\s*"(name|tool_calls)"\s*:').hasMatch(step1.text),
          };
          results.add(record);
          _webLog('AC-trial', record);
        }

        // ── Scoring ─────────────────────────────────────────────────────────

        final searchTrials = results
            .where((r) => r['bucket'] == 'search')
            .toList();
        final junkTrials = results
            .where((r) => r['bucket'] == 'junk')
            .toList();

        // Measurement A: tool-chain rates.
        final emitted1stCallCount = searchTrials
            .where((r) => r['emitted1stCall'] == true)
            .length;
        final chainedToFetchCount = searchTrials
            .where((r) => r['chainedToFetch'] == true)
            .length;
        final stalledCount = searchTrials
            .where((r) => r['stalled'] == true)
            .length;
        final loopedCount = searchTrials
            .where((r) => r['looped'] == true)
            .length;
        final finalAnswerPresentCount = searchTrials
            .where((r) => r['finalAnswerPresent'] == true)
            .length;
        final groundedCount = searchTrials
            .where((r) => r['answerGrounded'] == true)
            .length;

        // Junk: false positives.
        final falsePositiveCount = junkTrials
            .where((r) => r['falsePositive'] == true)
            .length;

        // Measurement C: latency stats for search trials that completed the full chain.
        final e2eTimes = searchTrials
            .where(
              (r) =>
                  r['finalAnswerPresent'] == true &&
                  r['e2eMs'] is int,
            )
            .map((r) => r['e2eMs'] as int)
            .toList()
          ..sort();
        final medianE2eMs = e2eTimes.isNotEmpty
            ? e2eTimes[e2eTimes.length ~/ 2]
            : null;
        final p90E2eMs = e2eTimes.isNotEmpty
            ? e2eTimes[(e2eTimes.length * 0.9).floor().clamp(
                0,
                e2eTimes.length - 1,
              )]
            : null;

        _webLog('AC-summary', {
          // Measurement A: tool-chain reliability
          'searchTrialTotal': searchTrials.length,
          'emitted1stCallCount': emitted1stCallCount,
          '1stCallRate':
              searchTrials.isEmpty
                  ? null
                  : emitted1stCallCount / searchTrials.length,
          'chainedToFetchCount': chainedToFetchCount,
          'chainRate':
              emitted1stCallCount == 0
                  ? null
                  : chainedToFetchCount / emitted1stCallCount,
          'stalledCount': stalledCount,
          'loopedCount': loopedCount,
          'finalAnswerPresentCount': finalAnswerPresentCount,
          'groundedCount': groundedCount,
          // False positives (junk)
          'junkTrialTotal': junkTrials.length,
          'falsePositiveCount': falsePositiveCount,
          // Measurement C: latency
          'medianE2eMs': medianE2eMs,
          'p90E2eMs': p90E2eMs,
          'e2eTimesMs': e2eTimes,
          // Overall gate indicators (no hard assertions — this is a spike)
          'peakRssMb': (peakRss / (1024 * 1024)).round(),
        });

        // Spike does NOT enforce hard pass/fail assertions — the numbers feed
        // the /specify and /plan decisions.  A single soft assertion guards
        // against a completely broken run (model never called any tool at all).
        //
        // If this fires, check:
        //   1. The model path is correct and the model is loaded.
        //   2. supportsFunctionCalls: true was passed to createChat.
        //   3. The system instruction is coherent.
        expect(
          emitted1stCallCount,
          greaterThanOrEqualTo(1),
          reason:
              'The model never emitted a single tool call across '
              '${searchTrials.length} search-worthy prompts. '
              'The spike harness is likely misconfigured '
              '(check model path, supportsFunctionCalls flag, tool declarations).',
        );

        await model.close();
        _webLog('AC-done', {'peakRssMb': (peakRss / (1024 * 1024)).round()});
      } finally {
        rssTimer.cancel();
      }
    },
  );
}
