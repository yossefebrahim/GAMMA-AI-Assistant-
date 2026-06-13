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
import 'package:ai_assistant/features/chat/widgets/source_url_chips.dart';
import 'package:ai_assistant/infrastructure/gemma/flutter_gemma_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/container_harness.dart';
import '../helpers/fake_gemma_service.dart';
import '../helpers/fake_network_research_service.dart';
import '../helpers/fake_secure_key_store.dart';

/// T048 (006 US5 AS1–AS4; FR-019, FR-020, FR-027, SC-004, SC-005, SC-012) — the web error chip.
///
/// Pure RENDERING tests (same seeded-row pattern as T034/T038): the persisted error tool-row the
/// controller would produce for each [ResearchError] is seeded via the repository, and the reactive
/// list is driven with UI+pump. The chip must show the sanctioned red glyph, name the TRUE recipient
/// (`WEB_SEARCH · Tavily`), surface the plain-language reason, render the honest text reply, and
/// never leak raw tool-call JSON — with no crash.
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
      secureKeyStore: FakeSecureKeyStore()..seed('k'),
      overrides: [
        gemmaServiceProvider.overrideWithValue(gemma),
        modelSessionProvider.overrideWith((ref) => gemma),
      ],
    );
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

  Future<void> open(WidgetTester tester, int conversationId) async {
    await tester.pumpWidget(app());
    await tester.pump();
    unawaited(
      container
          .read(chatControllerProvider.notifier)
          .openConversation(conversationId),
    );
    await tester.pump();
    await tester.pump();
  }

  /// Seed a user → web_search(error) → assistant turn with the given error [reason] + [reply].
  Future<int> seedWebSearchError(
    ConversationRepository repo, {
    required String reason,
    required String reply,
  }) async {
    final conv = await repo.createConversation();
    await repo.appendUserMessage(conv.id, 'search the web');
    final toolId = await repo.appendToolInvocation(
      conversationId: conv.id,
      toolName: 'web_search',
      args: const {'query': 'search the web'},
    );
    await repo.finalizeToolInvocation(
      toolId,
      status: ToolCallStatus.error,
      result: {'error': reason},
      summary: reason,
    );
    final assistantId = await repo.beginAssistantMessage(conv.id);
    await repo.updateAssistantContent(assistantId, reply);
    await repo.finalizeAssistantMessage(assistantId, MessageStatus.complete);
    return conv.id;
  }

  testWidgets(
    'OfflineError → red WEB_SEARCH · Tavily chip + "offline" reason; text reply; no raw JSON; no crash',
    (tester) async {
      final repo = container.read(conversationRepositoryProvider);
      final conv = await seedWebSearchError(
        repo,
        reason: 'offline — no connection',
        reply: "i'm offline, so here's what i already know.",
      );

      await open(tester, conv);

      // Recipient tag names Tavily; the red glyph + plain-language reason render.
      expect(find.text('WEB_SEARCH · Tavily'), findsOneWidget);
      expect(find.byIcon(Icons.error_outline), findsOneWidget);
      expect(find.text('offline — no connection'), findsOneWidget);
      // The model still produced a text reply (SC-005).
      expect(find.textContaining("i'm offline"), findsOneWidget);
      // No source chips on an error; no raw tool-call JSON leaks (SC-012).
      expect(find.byType(SourceUrlChips), findsNothing);
      expect(find.textContaining('function_call'), findsNothing);
      expect(find.textContaining('"error"'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'KeyInvalidError → a DISTINCT red chip message naming the key problem',
    (tester) async {
      final repo = container.read(conversationRepositoryProvider);
      final conv = await seedWebSearchError(
        repo,
        reason: 'tavily key invalid — check Settings',
        reply: 'your search key needs attention; here is what i know.',
      );

      await open(tester, conv);

      expect(find.text('WEB_SEARCH · Tavily'), findsOneWidget);
      expect(find.byIcon(Icons.error_outline), findsOneWidget);
      expect(find.text('tavily key invalid — check Settings'), findsOneWidget);
      // Distinct from the offline message.
      expect(find.text('offline — no connection'), findsNothing);
      expect(find.textContaining('here is what i know'), findsOneWidget);
      expect(find.byType(SourceUrlChips), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
