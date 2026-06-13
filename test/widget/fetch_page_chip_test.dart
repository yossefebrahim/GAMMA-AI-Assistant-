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

/// T038 (006 US4 AS1–AS3; FR-016, FR-027) — the fetch_page chip.
///
/// Pure RENDERING tests (same pattern as T034): the persisted tool-row shapes the controller would
/// produce are seeded directly via the repository, and the reactive watchMessages emission drives
/// the chat list. The chip names the TRUE recipient — the target site's host (`FETCH_PAGE · <host>`),
/// NOT Tavily (Constitution Principle I; the request goes directly to the website).
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

  /// Seed a user → fetch_page(success) → assistant turn for [url].
  Future<int> seedFetchSuccess(
    ConversationRepository repo, {
    required String url,
    required String host,
    bool truncated = false,
    String reply = 'the page explains the flutter widget lifecycle.',
  }) async {
    final conv = await repo.createConversation();
    await repo.appendUserMessage(conv.id, 'read $url for me');
    final toolId = await repo.appendToolInvocation(
      conversationId: conv.id,
      toolName: 'fetch_page',
      args: {'url': url},
    );
    await repo.finalizeToolInvocation(
      toolId,
      status: ToolCallStatus.success,
      // Persisted result shape: url + truncation flag + the single source url (no body text in DB).
      result: {
        'url': url,
        'truncated': truncated,
        'sourceUrls': [url],
      },
      summary: 'fetched $host',
    );
    final assistantId = await repo.beginAssistantMessage(conv.id);
    await repo.updateAssistantContent(assistantId, reply);
    await repo.finalizeAssistantMessage(assistantId, MessageStatus.complete);
    return conv.id;
  }

  testWidgets('chip label shows the target domain (FETCH_PAGE · flutter.dev)', (
    tester,
  ) async {
    // The label is computed from the url arg at render time (Uri.parse(url).host) — render the chip
    // directly to keep the host-derivation the unit under test, independent of the screen.
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
                toolName: 'fetch_page',
                toolArgs: const {'url': 'https://flutter.dev/docs/get-started'},
                toolStatus: ToolCallStatus.running,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // The recipient named is the website host — NOT Tavily.
    expect(find.text('FETCH_PAGE · flutter.dev'), findsOneWidget);
    expect(find.textContaining('Tavily'), findsNothing);
    expect(find.byKey(ToolChip.runningKey), findsOneWidget);
  });

  testWidgets('success renders text reply + one source URL chip', (
    tester,
  ) async {
    final repo = container.read(conversationRepositoryProvider);
    final conversationId = await seedFetchSuccess(
      repo,
      url: 'https://flutter.dev/docs/lifecycle',
      host: 'flutter.dev',
    );

    await open(tester, conversationId);

    expect(find.byType(ToolChip), findsOneWidget);
    expect(find.text('FETCH_PAGE · flutter.dev'), findsOneWidget);
    expect(find.text('fetched flutter.dev'), findsOneWidget);
    expect(
      find.text('the page explains the flutter widget lifecycle.'),
      findsOneWidget,
    );

    // Exactly one tappable source chip for the fetched page.
    expect(find.byType(SourceUrlChips), findsOneWidget);
    expect(find.byKey(SourceUrlChips.chipKey), findsOneWidget);
  });

  testWidgets('truncation path (truncated:true) renders without crash', (
    tester,
  ) async {
    final repo = container.read(conversationRepositoryProvider);
    final conversationId = await seedFetchSuccess(
      repo,
      url: 'https://en.wikipedia.org/wiki/Dart_(programming_language)',
      host: 'en.wikipedia.org',
      truncated: true,
    );

    await open(tester, conversationId);

    expect(find.byType(ToolChip), findsOneWidget);
    expect(find.text('FETCH_PAGE · en.wikipedia.org'), findsOneWidget);
    expect(find.text('fetched en.wikipedia.org'), findsOneWidget);
    // One source chip; no crash on the truncated row.
    expect(find.byKey(SourceUrlChips.chipKey), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('FetchDomainError renders a red chip naming the domain', (
    tester,
  ) async {
    final repo = container.read(conversationRepositoryProvider);
    final conv = await repo.createConversation();
    await repo.appendUserMessage(conv.id, 'read flutter.dev');
    final toolId = await repo.appendToolInvocation(
      conversationId: conv.id,
      toolName: 'fetch_page',
      args: const {'url': 'https://flutter.dev/down'},
    );
    await repo.finalizeToolInvocation(
      toolId,
      status: ToolCallStatus.error,
      result: const {
        'error': 'could not reach flutter.dev — check the URL or try later',
      },
      summary: 'could not reach flutter.dev — check the URL or try later',
    );
    final assistantId = await repo.beginAssistantMessage(conv.id);
    await repo.updateAssistantContent(
      assistantId,
      "i couldn't open that page, but here's what i know.",
    );
    await repo.finalizeAssistantMessage(assistantId, MessageStatus.complete);

    await open(tester, conv.id);

    // The chip names the domain in the recipient tag AND in the red error reason.
    expect(find.text('FETCH_PAGE · flutter.dev'), findsOneWidget);
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
    expect(
      find.text('could not reach flutter.dev — check the URL or try later'),
      findsOneWidget,
    );
    // No source chip on an error turn; no raw tool-call JSON leaks (SC-012).
    expect(find.byType(SourceUrlChips), findsNothing);
    expect(find.textContaining('function_call'), findsNothing);
  });

  testWidgets('a malformed-URL arg renders a validation error chip', (
    tester,
  ) async {
    final repo = container.read(conversationRepositoryProvider);
    final conv = await repo.createConversation();
    await repo.appendUserMessage(conv.id, 'fetch this');
    // A malformed url never reaches the network seam — the dispatcher rejects it with a
    // ToolInvalidArgs reason, persisted as an error tool row. The host is empty, so the chip falls
    // back to the bare FETCH_PAGE tag (no ` · <host>`).
    final toolId = await repo.appendToolInvocation(
      conversationId: conv.id,
      toolName: 'fetch_page',
      args: const {'url': 'not a url'},
    );
    await repo.finalizeToolInvocation(
      toolId,
      status: ToolCallStatus.error,
      result: const {'error': 'argument url is not a valid URI'},
      summary: 'url is not a valid URI',
    );
    final assistantId = await repo.beginAssistantMessage(conv.id);
    await repo.updateAssistantContent(
      assistantId,
      "that doesn't look like a url.",
    );
    await repo.finalizeAssistantMessage(assistantId, MessageStatus.complete);

    await open(tester, conv.id);

    expect(find.text('FETCH_PAGE'), findsOneWidget);
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
    expect(find.textContaining('not a valid URI'), findsOneWidget);
    expect(find.byType(SourceUrlChips), findsNothing);
  });
}
