import 'dart:async';

import 'package:ai_assistant/app/theme/app_theme.dart';
import 'package:ai_assistant/data/repositories/drift_conversation_repository.dart';
import 'package:ai_assistant/domain/entities/message.dart';
import 'package:ai_assistant/domain/entities/model_capabilities.dart';
import 'package:ai_assistant/domain/entities/tool_outcome.dart';
import 'package:ai_assistant/domain/repositories/conversation_repository.dart';
import 'package:ai_assistant/features/chat/chat_controller.dart';
import 'package:ai_assistant/features/chat/chat_providers.dart';
import 'package:ai_assistant/features/chat/chat_screen.dart';
import 'package:ai_assistant/features/chat/widgets/composer.dart';
import 'package:ai_assistant/features/chat/widgets/tool_chip.dart';
import 'package:ai_assistant/infrastructure/gemma/flutter_gemma_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/container_harness.dart';
import '../helpers/fake_gemma_service.dart';
import '../helpers/fake_network_research_service.dart';
import '../helpers/fake_secure_key_store.dart';
import '../helpers/test_db.dart';

/// T051 (006 US7 AS4; FR-006, FR-021, FR-025; SC-009) — widget-level gating regression.
///
/// Two guarantees at the UI layer:
///   • A fresh chat turn under a NON-tool-capable model (web globally ON + a valid key) declares NO
///     web tools through the REAL [modelSessionProvider] and NEVER touches the network seam — the
///     chat behaves byte-for-byte like pre-006 (plain reply, zero chips).
///   • A persisted `web_search` chip from a prior session STILL renders in place under that same
///     text-only model (history outlives the capability that produced it — FR-025, US7 AS4).
void main() {
  late FakeGemmaService gemma;
  late FakeNetworkResearchService network;
  late ProviderContainer container;

  setUp(() {
    // Text-only model → function calling OFF. Web global ON + a key are present too, proving the
    // capability gate (not the toggles) is what removes the web tools.
    gemma = FakeGemmaService(capabilitiesData: ModelCapabilities.textOnly);
    network = FakeNetworkResearchService();
  });

  tearDown(() => container.dispose());

  Widget app() => UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: ThemeMode.dark,
      home: const ChatScreen(),
    ),
  );

  testWidgets(
    'functionCalling=false: fresh turn declares zero web tools, zero network, plain reply (SC-009)',
    (tester) async {
      gemma
        ..scriptedDeltas = ['plain ', 'reply']
        ..deltaInterval = const Duration(milliseconds: 20);
      container = makeContainer(
        networkResearch: network,
        secureKeyStore: FakeSecureKeyStore()..seed('tavily-key'),
        overrides: [
          gemmaServiceProvider.overrideWithValue(gemma),
          installedModelPathProvider.overrideWith((ref) async => '/fake/model'),
          catalogCapabilitiesProvider.overrideWithValue(
            ModelCapabilities.textOnly,
          ),
        ],
      );

      await tester.pumpWidget(app());
      await tester.pump();
      // Materialise the session (loads the model) so loadedTools is populated.
      await container.read(modelSessionProvider.future);

      await tester.enterText(find.byKey(Composer.fieldKey), 'hello');
      await tester.pump();
      await tester.tap(find.byKey(Composer.sendKey));
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 25));
      }

      expect(find.textContaining('plain reply'), findsOneWidget);
      expect(find.byType(ToolChip), findsNothing);

      final declaredNames = (gemma.loadedTools ?? const [])
          .map((t) => t.name)
          .toList();
      expect(declaredNames, isNot(contains('web_search')));
      expect(declaredNames, isNot(contains('fetch_page')));
      expect(
        gemma.loadedTools,
        isEmpty,
        reason: 'no tools under a text-only model',
      );
      expect(network.searchCallLog, isEmpty);
      expect(network.fetchCallLog, isEmpty);
    },
  );

  testWidgets(
    'a persisted web_search chip from history STILL renders under a text-only model (FR-025)',
    (tester) async {
      final db = newTestDatabase();
      // Seed via a throwaway container sharing the same in-memory db.
      final seeder = makeContainer(database: db);
      final conversationId = await _seedWebSearchChip(
        seeder.read(conversationRepositoryProvider),
      );

      container = makeContainer(
        database: db,
        networkResearch: network,
        secureKeyStore: FakeSecureKeyStore(), // no key now
        overrides: [
          gemmaServiceProvider.overrideWithValue(gemma),
          modelSessionProvider.overrideWith((ref) => gemma),
        ],
      );

      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(app());
      await tester.pump();
      unawaited(
        container
            .read(chatControllerProvider.notifier)
            .openConversation(conversationId),
      );
      await tester.pump();
      await tester.pump();

      // The chip outlives the capability that produced it; no network call to re-render it.
      expect(find.byType(ToolChip), findsOneWidget);
      expect(find.text('WEB_SEARCH · Tavily'), findsOneWidget);
      expect(network.searchCallLog, isEmpty);
    },
  );
}

Future<int> _seedWebSearchChip(ConversationRepository repo) async {
  final conv = await repo.createConversation();
  await repo.appendUserMessage(conv.id, 'what is new?');
  final toolId = await repo.appendToolInvocation(
    conversationId: conv.id,
    toolName: 'web_search',
    args: const {'query': 'what is new'},
  );
  await repo.finalizeToolInvocation(
    toolId,
    status: ToolCallStatus.success,
    result: const {
      'results': [
        {'title': 'News', 'url': 'https://example.com/news'},
      ],
      'sourceUrls': ['https://example.com/news'],
    },
    summary: '1 results for "what is new"',
  );
  final assistantId = await repo.beginAssistantMessage(conv.id);
  await repo.updateAssistantContent(assistantId, 'here is what is new');
  await repo.finalizeAssistantMessage(assistantId, MessageStatus.complete);
  return conv.id;
}
