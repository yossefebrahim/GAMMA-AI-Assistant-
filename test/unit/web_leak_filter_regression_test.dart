import 'package:ai_assistant/data/repositories/drift_conversation_repository.dart';
import 'package:ai_assistant/domain/entities/generation_event.dart';
import 'package:ai_assistant/domain/entities/message.dart';
import 'package:ai_assistant/domain/entities/model_capabilities.dart';
import 'package:ai_assistant/domain/entities/tool_outcome.dart';
import 'package:ai_assistant/domain/repositories/conversation_repository.dart';
import 'package:ai_assistant/features/chat/chat_controller.dart';
import 'package:ai_assistant/features/chat/chat_providers.dart';
import 'package:ai_assistant/infrastructure/gemma/flutter_gemma_service.dart';
import 'package:ai_assistant/infrastructure/gemma/leak_filter.dart';
import 'package:ai_assistant/infrastructure/network/research_errors.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/container_harness.dart';
import '../helpers/fake_gemma_service.dart';
import '../helpers/fake_network_research_service.dart';
import '../helpers/fake_secure_key_store.dart';

/// T052 (006 US8 AS1–AS4; FR-026, FR-027, FR-028; SC-012) — LeakFilter regression for the web tools.
///
/// Two layers:
///   1. The 004 [LeakFilter] (UNCHANGED) already suppresses the raw `web_search` / `fetch_page`
///      call JSON that flutter_gemma 0.15.3 spills into the text channel (guarantee 20 extended to
///      the 006 web tools). Asserted against the exact runtime chunk shapes.
///   2. End-to-end over the REAL [ChatController]: each invalid-call path (missing query, malformed
///      url, handler exception) produces a RED error chip + an honest text reply, and NO raw
///      `{"function_call":...}` / `'"error"'` JSON renders in the streamed assistant content.
void main() {
  // ── Layer 1: filter-level suppression of the web tool leak shapes ──────────

  const webSearchLeak =
      '{"role":"assistant","tool_calls":[{"type":"function","function":'
      '{"name":"web_search","arguments":{"query":"current events"}}}]}';

  const fetchPageLeak =
      '{"role":"assistant","tool_calls":[{"type":"function","function":'
      '{"name":"fetch_page","arguments":{"url":"https://example.com"}}}]}';

  String emit(LeakFilter f, Iterable<String> chunks) {
    final out = StringBuffer();
    for (final c in chunks) {
      out.write(f.process(c));
    }
    return out.toString();
  }

  group(
    'web tool call JSON is suppressed by the 004 LeakFilter (guarantee 20)',
    () {
      test(
        'bare web_search call JSON: nothing emitted to the text channel',
        () {
          final f = LeakFilter();
          expect(emit(f, [webSearchLeak]), isEmpty);
          f.discardOnToolCall();
        },
      );

      test(
        'bare fetch_page call JSON: nothing emitted to the text channel',
        () {
          final f = LeakFilter();
          expect(emit(f, [fetchPageLeak]), isEmpty);
          f.discardOnToolCall();
        },
      );

      test(
        'prose then web_search leak: prose passes, leak withheld then discarded',
        () {
          final f = LeakFilter();
          expect(
            emit(f, ['let me search. ', webSearchLeak]),
            'let me search. ',
          );
          f.discardOnToolCall();
        },
      );

      test(
        'split-chunk fetch_page leak: all chunks withheld and discarded',
        () {
          final f = LeakFilter();
          const part1 = '{"role":"assistant","tool_calls":[';
          const part2 = '{"type":"function","function":{"name":"fetch_page",';
          const part3 = '"arguments":{"url":"https://example.com"}}}]}';
          expect(emit(f, [part1, part2, part3]), isEmpty);
          f.discardOnToolCall();
        },
      );

      test(
        'inactive filter (flag off) emits web_search leak verbatim (byte-parity)',
        () {
          final f = LeakFilter(active: false);
          expect(emit(f, [webSearchLeak]), webSearchLeak);
          expect(f.isWithholding, isFalse);
        },
      );
    },
  );

  // ── Layer 2: end-to-end — each invalid-call path → red chip + text reply, no raw JSON ──

  late FakeGemmaService gemma;
  late FakeNetworkResearchService network;
  late ProviderContainer container;

  setUp(() {
    gemma = FakeGemmaService(
      capabilitiesData: const ModelCapabilities(functionCalling: true),
    );
    network = FakeNetworkResearchService();
    container = makeContainer(
      networkResearch: network,
      secureKeyStore: FakeSecureKeyStore()..seed('tavily-key'),
      overrides: [
        gemmaServiceProvider.overrideWithValue(gemma),
        modelSessionProvider.overrideWith((ref) => gemma),
      ],
    );
  });

  tearDown(() => container.dispose());

  ChatController controller() =>
      container.read(chatControllerProvider.notifier);
  ConversationRepository repo() =>
      container.read(conversationRepositoryProvider);
  Future<List<Message>> turns() async =>
      repo().loadTurns(container.read(chatControllerProvider).conversationId!);

  void assertNoRawJson(List<Message> rows) {
    for (final m in rows.where((m) => m.role == MessageRole.assistant)) {
      final content = m.content;
      expect(
        content,
        isNot(contains('"function_call"')),
        reason: 'no raw function-call JSON in the assistant text',
      );
      expect(
        content,
        isNot(contains('tool_calls')),
        reason: 'no raw tool-call envelope in the assistant text',
      );
      expect(
        content,
        isNot(contains('"error"')),
        reason: 'the error payload is a chip, never raw assistant text',
      );
    }
  }

  test(
    'missing query (invalid args) → error chip + text reply, no raw JSON (FR-027)',
    () async {
      // The model emits web_search with NO query key — the strict validator rejects it before the
      // handler runs (no network call), the dispatcher returns a ToolInvalidArgs failure, and the
      // resume produces an honest text reply.
      gemma.scriptedEvents = [const ToolCallRequested('web_search', {})];
      gemma.resumeEvents = [
        const TextDelta('i could not search — answering directly.'),
      ];

      await controller().send('search please');

      final rows = await turns();
      final chip = rows.firstWhere((m) => m.isTool);
      expect(chip.toolStatus, ToolCallStatus.error);
      expect(textReplyOf(rows), isNotEmpty);
      expect(
        network.searchCallLog,
        isEmpty,
        reason: 'invalid args never reach the seam',
      );
      assertNoRawJson(rows);
    },
  );

  test(
    'malformed url (invalid args) → error chip + text reply, no raw JSON (FR-027)',
    () async {
      gemma.scriptedEvents = [
        const ToolCallRequested('fetch_page', {'url': 'not a url'}),
      ];
      gemma.resumeEvents = [const TextDelta('that link was invalid.')];

      await controller().send('read not a url');

      final rows = await turns();
      final chip = rows.firstWhere((m) => m.isTool);
      expect(chip.toolStatus, ToolCallStatus.error);
      expect(textReplyOf(rows), isNotEmpty);
      expect(
        network.fetchCallLog,
        isEmpty,
        reason: 'invalid url never reaches the seam',
      );
      assertNoRawJson(rows);
    },
  );

  test(
    'handler exception (OfflineError) → error chip + text reply, no raw JSON (FR-027)',
    () async {
      network.stubSearchError('news', const OfflineError());
      gemma.scriptedEvents = [
        const ToolCallRequested('web_search', {'query': 'news'}),
      ];
      gemma.resumeEvents = [
        const TextDelta('i am offline, answering from memory.'),
      ];

      await controller().send('latest news');

      final rows = await turns();
      final chip = rows.firstWhere((m) => m.isTool);
      expect(chip.toolStatus, ToolCallStatus.error);
      expect(chip.content.toLowerCase(), contains('offline'));
      expect(textReplyOf(rows), isNotEmpty);
      assertNoRawJson(rows);
    },
  );
}

/// The concatenated content of all assistant rows — the honest text reply that follows the chip.
String textReplyOf(List<Message> rows) => rows
    .where((m) => m.role == MessageRole.assistant)
    .map((m) => m.content)
    .join();
