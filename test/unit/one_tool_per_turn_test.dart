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
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/container_harness.dart';
import '../helpers/fake_gemma_service.dart';
import '../helpers/fake_network_research_service.dart';
import '../helpers/fake_secure_key_store.dart';

/// T053 (006 US8; FR-028; spike §4.3; contracts/web_research_tools.md §Dispatcher coercion/bounding
/// 3) — the one-tool-per-turn contract for the web tools.
///
/// When the model emits a SECOND `ToolCallRequested` on the resumed stream (after
/// `resumeWithToolResult` has already been called once in the same turn — the
/// `fetch_page`-after-`web_search` intra-turn chaining the contract architecturally blocks), the
/// controller MUST chip-and-skip it with the canonical message "call skipped — one tool per turn"
/// and NEVER execute it. Verified end-to-end over the REAL `ChatController` tool-turn state machine
/// + a scripted [FakeGemmaService], asserting both the persisted chip text AND that the second
/// tool's handler was never invoked (zero extra network calls on [FakeNetworkResearchService]).
void main() {
  late FakeGemmaService gemma;
  late FakeNetworkResearchService network;
  late ProviderContainer container;

  setUp(() {
    gemma = FakeGemmaService(
      capabilitiesData: const ModelCapabilities(functionCalling: true),
    );
    network = FakeNetworkResearchService()
      ..stubSearch('current events', const [
        WebSearchResult(
          title: 'Headline',
          url: 'https://example.com/a',
          content: 'a summary',
          score: 0.9,
        ),
      ])
      ..stubFetch(
        'https://example.com/a',
        // Stubbed so that IF (incorrectly) executed it would log a fetch call — the
        // `fetchCallLog` assertion below proves it is never reached.
        const FetchResult(
          url: 'https://example.com/a',
          extractedText: 'should never be fetched',
          wasTruncated: false,
        ),
      );
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

  test(
    'a second tool call on the resumed stream is chipped-and-skipped, not executed (FR-028)',
    () async {
      // Turn 1: the model calls web_search. On resume it tries to chain fetch_page (the exact
      // intra-turn chaining the contract blocks — spike §4.3).
      gemma.scriptedEvents = [
        const ToolCallRequested('web_search', {'query': 'current events'}),
      ];
      gemma.resumeEvents = [
        const ToolCallRequested('fetch_page', {'url': 'https://example.com/a'}),
      ];

      await controller().send('what is happening today?');

      final toolRows = (await turns()).where((m) => m.isTool).toList();

      // The first call executed (web_search → success); the second was chipped-and-skipped.
      expect(toolRows, hasLength(2));
      expect(toolRows[0].toolName, 'web_search');
      expect(toolRows[0].toolStatus, ToolCallStatus.success);

      expect(toolRows[1].toolName, 'fetch_page');
      expect(toolRows[1].toolStatus, ToolCallStatus.error);
      expect(
        toolRows[1].toolResult!['error'],
        'call skipped — one tool per turn',
        reason: 'canonical one-tool-per-turn message per the contract',
      );
      expect(
        toolRows[1].content,
        contains('call skipped — one tool per turn'),
        reason: 'the chip summary uses the canonical message',
      );

      // The second tool was NEVER executed: web_search ran once, fetch_page never reached the seam.
      expect(network.searchCallLog, ['current events']);
      expect(
        network.fetchCallLog,
        isEmpty,
        reason: 'the skipped fetch_page must never hit the network seam',
      );
      // The seam was resumed exactly once (the first tool's grounding); the second call did not
      // trigger another resume — the turn ends as text.
      expect(gemma.resumeCount, 1);
    },
  );
}
