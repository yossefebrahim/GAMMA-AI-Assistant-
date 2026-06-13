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
import 'package:ai_assistant/features/chat/tool_handler_providers.dart';
import 'package:ai_assistant/features/chat/widgets/source_url_chips.dart';
import 'package:ai_assistant/features/chat/widgets/tool_chip.dart';
import 'package:ai_assistant/infrastructure/gemma/flutter_gemma_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/container_harness.dart';
import '../helpers/fake_gemma_service.dart';
import '../helpers/fake_network_research_service.dart';
import '../helpers/fake_secure_key_store.dart';
import '../helpers/fake_web_url_launcher.dart';

/// T034 (006 US1 AS1–AS4; SC-007, SC-012) — the web_search chip + source URL chips.
///
/// Pure RENDERING tests: the persisted row shapes the controller produces are seeded via the
/// repository, and the reactive watchMessages emission drives the list — deliberately NOT
/// bare-awaiting fake Gemma streams in a widget test (the model-restore-recipe / hang hazard, see
/// CLAUDE.md). The running → success transition is driven by finalising the seeded tool row and
/// pumping the reactive update.
void main() {
  late FakeGemmaService gemma;
  late FakeNetworkResearchService network;
  late FakeWebUrlLauncher launcher;
  late ProviderContainer container;

  setUp(() {
    gemma = FakeGemmaService(
      capabilitiesData: const ModelCapabilities(functionCalling: true),
    );
    network = FakeNetworkResearchService();
    launcher = FakeWebUrlLauncher();
    container = makeContainer(
      networkResearch: network,
      secureKeyStore: FakeSecureKeyStore()..seed('k'),
      overrides: [
        gemmaServiceProvider.overrideWithValue(gemma),
        modelSessionProvider.overrideWith((ref) => gemma),
        webUrlLauncherProvider.overrideWithValue(launcher),
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
    await tester.pump(); // resolve the model session
    unawaited(
      container
          .read(chatControllerProvider.notifier)
          .openConversation(conversationId),
    );
    await tester.pump(); // rebuild the body
    await tester.pump(); // drain the reactive watchMessages emission
  }

  /// Seed a user → web_search(success) → assistant turn with the given grounding [urls].
  Future<int> seedWebSearchSuccess(
    ConversationRepository repo, {
    required List<String> urls,
    String query = 'latest dart version',
    String summary = '3 results for "latest dart version"',
    String reply = 'the latest stable dart release is 3.x.',
  }) async {
    final conv = await repo.createConversation();
    await repo.appendUserMessage(conv.id, 'what is the $query?');
    final toolId = await repo.appendToolInvocation(
      conversationId: conv.id,
      toolName: 'web_search',
      args: {'query': query},
    );
    await repo.finalizeToolInvocation(
      toolId,
      status: ToolCallStatus.success,
      result: {'sourceUrls': urls},
      summary: summary,
    );
    final assistantId = await repo.beginAssistantMessage(conv.id);
    await repo.updateAssistantContent(assistantId, reply);
    await repo.finalizeAssistantMessage(assistantId, MessageStatus.complete);
    return conv.id;
  }

  testWidgets('running chip: named-recipient tag + dot-pulse, no result line', (
    tester,
  ) async {
    // The running state is rendered directly (the ChatController's startup sweep finalises any
    // persisted `running` row to error('interrupted') on open, so a screen-level running chip is
    // not a stable fixture — the chip widget itself is the unit under test for this state).
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.dark,
          home: Scaffold(
            body: ToolChip(
              message: Message(
                id: 1,
                conversationId: 1,
                role: MessageRole.tool,
                content: '',
                sequence: 0,
                createdAt: DateTime.utc(2026, 6, 12),
                status: MessageStatus.complete,
                toolName: 'web_search',
                toolArgs: const {'query': 'latest dart version'},
                toolStatus: ToolCallStatus.running,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('WEB_SEARCH · Tavily'), findsOneWidget);
    expect(find.byKey(ToolChip.runningKey), findsOneWidget);
    expect(find.byKey(ToolChip.contentKey), findsNothing);
  });

  testWidgets('success chip with source URL chips beneath the reply', (
    tester,
  ) async {
    final repo = container.read(conversationRepositoryProvider);
    final conversationId = await seedWebSearchSuccess(
      repo,
      urls: const [
        'https://dart.dev/guides',
        'https://dart.dev/news',
        'https://en.wikipedia.org/wiki/Dart',
      ],
    );

    await open(tester, conversationId);

    // Success chip: named-recipient tag + the result-count summary (no running pulse).
    expect(find.byType(ToolChip), findsOneWidget);
    expect(find.text('WEB_SEARCH · Tavily'), findsOneWidget);
    expect(find.byKey(ToolChip.runningKey), findsNothing);
    expect(find.text('3 results for "latest dart version"'), findsOneWidget);
    expect(find.text('the latest stable dart release is 3.x.'), findsOneWidget);

    // One tappable source URL chip per result URL, beneath the reply.
    expect(find.byType(SourceUrlChips), findsOneWidget);
    expect(find.byKey(SourceUrlChips.chipKey), findsNWidgets(3));

    // The source chips render BELOW the grounded reply bubble.
    final replyY = tester
        .getTopLeft(find.text('the latest stable dart release is 3.x.'))
        .dy;
    final chipsY = tester.getTopLeft(find.byType(SourceUrlChips)).dy;
    expect(replyY, lessThan(chipsY));
  });

  testWidgets(
    'tapping a source chip opens the browser via the WebUrlLauncher seam',
    (tester) async {
      final repo = container.read(conversationRepositoryProvider);
      final conv = await repo.createConversation();
      await repo.appendUserMessage(conv.id, 'dart version?');
      final toolId = await repo.appendToolInvocation(
        conversationId: conv.id,
        toolName: 'web_search',
        args: const {'query': 'dart version'},
      );
      await repo.finalizeToolInvocation(
        toolId,
        status: ToolCallStatus.success,
        result: const {
          'sourceUrls': ['https://dart.dev/guides'],
        },
        summary: '1 results for "dart version"',
      );
      final assistantId = await repo.beginAssistantMessage(conv.id);
      await repo.updateAssistantContent(assistantId, 'see dart.dev.');
      await repo.finalizeAssistantMessage(assistantId, MessageStatus.complete);

      await open(tester, conv.id);

      expect(find.byKey(SourceUrlChips.chipKey), findsOneWidget);
      await tester.tap(find.byKey(SourceUrlChips.chipKey));
      await tester.pump();

      expect(launcher.opened, ['https://dart.dev/guides']);
    },
  );

  testWidgets(
    'zero results renders a "0 results" success chip with no source chips',
    (tester) async {
      final repo = container.read(conversationRepositoryProvider);
      final conv = await repo.createConversation();
      await repo.appendUserMessage(conv.id, 'asdkjhqwe obscure');
      final toolId = await repo.appendToolInvocation(
        conversationId: conv.id,
        toolName: 'web_search',
        args: const {'query': 'asdkjhqwe obscure'},
      );
      await repo.finalizeToolInvocation(
        toolId,
        status: ToolCallStatus.success,
        // Zero-results: no sourceUrls persisted (FR-033).
        result: const {'results': <Object?>[]},
        summary: '0 results',
      );
      final assistantId = await repo.beginAssistantMessage(conv.id);
      await repo.updateAssistantContent(
        assistantId,
        'i could not find anything online.',
      );
      await repo.finalizeAssistantMessage(assistantId, MessageStatus.complete);

      await open(tester, conv.id);

      expect(find.text('WEB_SEARCH · Tavily'), findsOneWidget);
      expect(find.text('0 results'), findsOneWidget);
      // No source chips on a zero-results turn.
      expect(find.byType(SourceUrlChips), findsNothing);
      expect(find.byKey(SourceUrlChips.chipKey), findsNothing);
    },
  );

  testWidgets('an error renders a red chip + the honest text reply', (
    tester,
  ) async {
    final repo = container.read(conversationRepositoryProvider);
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
      result: const {'error': 'offline — no connection'},
      summary: 'offline — no connection',
    );
    final assistantId = await repo.beginAssistantMessage(conv.id);
    await repo.updateAssistantContent(
      assistantId,
      "i'm offline, so here's what i already know.",
    );
    await repo.finalizeAssistantMessage(assistantId, MessageStatus.complete);

    await open(tester, conv.id);

    // The error chip uses the sanctioned red glyph + the plain-language reason.
    expect(find.text('WEB_SEARCH · Tavily'), findsOneWidget);
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
    expect(find.text('offline — no connection'), findsOneWidget);
    // The honest text reply is shown; no source chips on an error.
    expect(find.textContaining("i'm offline"), findsOneWidget);
    expect(find.byType(SourceUrlChips), findsNothing);
    // No raw tool-call JSON leaks into the rendered text (SC-012).
    expect(find.textContaining('function_call'), findsNothing);
  });
}
