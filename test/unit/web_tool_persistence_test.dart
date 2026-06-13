import 'package:ai_assistant/data/repositories/drift_conversation_repository.dart';
import 'package:ai_assistant/domain/entities/fetch_result.dart';
import 'package:ai_assistant/domain/entities/generation_event.dart';
import 'package:ai_assistant/domain/entities/message.dart';
import 'package:ai_assistant/domain/entities/model_capabilities.dart';
import 'package:ai_assistant/domain/entities/tool_outcome.dart';
import 'package:ai_assistant/domain/entities/web_search_result.dart';
import 'package:ai_assistant/domain/repositories/conversation_repository.dart';
import 'package:ai_assistant/features/chat/chat_controller.dart';
import 'package:ai_assistant/features/chat/chat_providers.dart';
import 'package:ai_assistant/infrastructure/gemma/flutter_gemma_service.dart';
import 'package:ai_assistant/infrastructure/network/research_errors.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/container_harness.dart';
import '../helpers/fake_gemma_service.dart';
import '../helpers/fake_network_research_service.dart';
import '../helpers/fake_secure_key_store.dart';

/// T049 (006 US6; data-model §3, FR-024, FR-025, SC-008, Decision 4) — web tool persistence shape.
///
/// Drives a REAL tool turn through [ChatController] (scripted FakeGemmaService + the real handler
/// map dispatching against [FakeNetworkResearchService]) and inspects the PERSISTED `role='tool'`
/// row. The invariant under test: the Tavily `content` snippet body (web_search) and the
/// `extractedText` (fetch_page) are computed transiently and fed to the model on resume, but are
/// NEVER written to the DB — only metadata + answer-grounding source URLs persist. Error rows hold
/// `{error:…}` only — never the key string.
void main() {
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
      secureKeyStore: FakeSecureKeyStore()..seed('secret-tavily-key'),
      overrides: [
        gemmaServiceProvider.overrideWithValue(gemma),
        modelSessionProvider.overrideWith((ref) => gemma),
        modelCapabilitiesProvider.overrideWith(
          (ref) => const ModelCapabilities(functionCalling: true),
        ),
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

  test(
    'web_search: tool_args holds only the query; tool_result holds {title,url}+sourceUrls — no content body',
    () async {
      network.stubSearch('latest dart version', [
        WebSearchResult(
          title: 'Dart 3.5',
          url: 'https://dart.dev/news',
          content: 'A LONG SNIPPET BODY that must never reach the DB ' * 5,
          score: 0.9,
        ),
        const WebSearchResult(
          title: 'Dart guide',
          url: 'https://dart.dev/guides',
          content: 'ANOTHER BODY SNIPPET kept only in-session',
          score: 0.7,
        ),
      ]);
      gemma.scriptedEvents = [
        const ToolCallRequested('web_search', {'query': 'latest dart version'}),
      ];
      gemma.resumeEvents = [const TextDelta('dart 3.5 is the latest.')];

      await controller().send('what is the latest dart version?');

      final rows = await turns();
      final toolRow = rows.firstWhere((m) => m.isTool);

      // tool_args: only the query.
      expect(toolRow.toolArgs, {'query': 'latest dart version'});

      // tool_result: per-result {title,url} metadata ONLY + sourceUrls — no content, no score.
      final result = toolRow.toolResult!;
      final results = result['results'] as List;
      expect(results, hasLength(2));
      for (final r in results.cast<Map<String, Object?>>()) {
        expect(r.keys, unorderedEquals(['title', 'url']));
        expect(r.containsKey('content'), isFalse);
        expect(r.containsKey('score'), isFalse);
      }
      expect(result['sourceUrls'], [
        'https://dart.dev/news',
        'https://dart.dev/guides',
      ]);

      // The body snippet never appears anywhere in the serialised row.
      expect(toolRow.toolResult.toString(), isNot(contains('SNIPPET BODY')));
      expect(toolRow.toolResult.toString(), isNot(contains('in-session')));

      // …but the MODEL did receive the full content on resume (grounding is preserved).
      final resumed = gemma.lastResumeResult!;
      final resumedResults = (resumed['results'] as List)
          .cast<Map<String, Object?>>();
      expect(resumedResults.first['content'], contains('SNIPPET BODY'));
    },
  );

  test(
    'fetch_page: tool_result holds {url,truncated,sourceUrls} only — extractedText never persisted',
    () async {
      network.stubFetch(
        'https://flutter.dev/docs',
        const FetchResult(
          url: 'https://flutter.dev/docs',
          extractedText:
              'THE FULL EXTRACTED PAGE BODY that stays in-session only',
          wasTruncated: true,
        ),
      );
      gemma.scriptedEvents = [
        const ToolCallRequested('fetch_page', {
          'url': 'https://flutter.dev/docs',
        }),
      ];
      gemma.resumeEvents = [const TextDelta('the page covers widgets.')];

      await controller().send('read flutter.dev/docs');

      final rows = await turns();
      final toolRow = rows.firstWhere((m) => m.isTool);

      expect(toolRow.toolArgs, {'url': 'https://flutter.dev/docs'});

      final result = toolRow.toolResult!;
      expect(result.keys, unorderedEquals(['url', 'truncated', 'sourceUrls']));
      expect(result['url'], 'https://flutter.dev/docs');
      expect(result['truncated'], true);
      expect(result['sourceUrls'], ['https://flutter.dev/docs']);
      // No body text in the DB.
      expect(result.containsKey('text'), isFalse);
      expect(result.containsKey('extractedText'), isFalse);
      expect(
        toolRow.toolResult.toString(),
        isNot(contains('EXTRACTED PAGE BODY')),
      );

      // The model still saw the extracted text on resume.
      expect(gemma.lastResumeResult!['text'], contains('EXTRACTED PAGE BODY'));
    },
  );

  test('error row persists {error:…} only — never the key string', () async {
    network.stubSearchError('q', const KeyInvalidError(httpStatusCode: 401));
    gemma.scriptedEvents = [
      const ToolCallRequested('web_search', {'query': 'q'}),
    ];
    gemma.resumeEvents = [const TextDelta('here is what i know.')];

    await controller().send('q');

    final rows = await turns();
    final toolRow = rows.firstWhere((m) => m.isTool);
    expect(toolRow.toolStatus, ToolCallStatus.error);
    expect(toolRow.toolResult, {
      'error': 'tavily key invalid — check Settings',
    });
    // The seeded key must never leak into the persisted row.
    expect(toolRow.toolResult.toString(), isNot(contains('secret-tavily-key')));
    expect(toolRow.toolArgs.toString(), isNot(contains('secret-tavily-key')));
  });

  test('zero-results web_search persists the note shape unchanged', () async {
    network.stubSearch('obscure', const []);
    gemma.scriptedEvents = [
      const ToolCallRequested('web_search', {'query': 'obscure'}),
    ];
    gemma.resumeEvents = [const TextDelta('nothing online.')];

    await controller().send('obscure');

    final rows = await turns();
    final toolRow = rows.firstWhere((m) => m.isTool);
    expect(toolRow.toolStatus, ToolCallStatus.success);
    expect((toolRow.toolResult!['results'] as List), isEmpty);
    expect(toolRow.toolResult!['note'], isNotNull);
  });
}
