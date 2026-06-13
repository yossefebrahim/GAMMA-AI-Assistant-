import 'dart:async';

import 'package:ai_assistant/app/theme/app_theme.dart';
import 'package:ai_assistant/data/db/app_database.dart';
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
import '../helpers/fake_secure_key_store.dart';
import '../helpers/fake_web_url_launcher.dart';
import '../helpers/test_db.dart';

/// T050 (006 US6; FR-024, FR-025, SC-007, SC-008) — web tool chips survive a restart (history load).
///
/// Seeds a conversation containing a `web_search` success, a `fetch_page` success, and an error row
/// into a SHARED in-memory db, then opens a FRESH provider graph over that same db (simulated
/// restart). The chips must re-render with the right query/url + status, the source URL chips must be
/// present + tappable, NO full snippet/body must appear in the rendered content, the error chip must
/// re-render with its original reason, and all of this must hold regardless of the CURRENT web toggle
/// state (web globally OFF + no per-conversation override here — chips are persisted artefacts).
void main() {
  late FakeWebUrlLauncher launcher;
  late ProviderContainer restarted;

  /// Seed the conversation into [db] via a throwaway container, then return its id.
  Future<int> seedHistory(AppDatabase db) async {
    final seeder = makeContainer(database: db);
    final repo = seeder.read(conversationRepositoryProvider);
    final id = await _seed(repo);
    // NOTE: not disposing `seeder` would close the shared db; instead we keep it un-disposed so the
    // restarted container reads the same data. (The restarted container's dispose closes the db.)
    return id;
  }

  setUp(() {
    launcher = FakeWebUrlLauncher();
  });

  tearDown(() => restarted.dispose());

  Widget app() => UncontrolledProviderScope(
    container: restarted,
    child: MaterialApp(
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: ThemeMode.dark,
      home: const ChatScreen(),
    ),
  );

  Future<void> open(WidgetTester tester, int conversationId) async {
    // A tall viewport so the full 9-message ListView.builder builds every chip (the error chip is the
    // last row — below an 800×600 fold otherwise).
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(app());
    await tester.pump();
    unawaited(
      restarted
          .read(chatControllerProvider.notifier)
          .openConversation(conversationId),
    );
    await tester.pump();
    await tester.pump();
  }

  testWidgets(
    'web_search + fetch_page + error chips re-render after a restart with web toggle OFF',
    (tester) async {
      final db = newTestDatabase();
      final conversationId = await seedHistory(db);

      // Restart: a fresh graph over the same db, web globally OFF (default), model can call tools.
      restarted = makeContainer(
        database: db,
        secureKeyStore:
            FakeSecureKeyStore(), // no key → web tools cannot be declared now
        overrides: [
          gemmaServiceProvider.overrideWithValue(
            FakeGemmaService(
              capabilitiesData: const ModelCapabilities(functionCalling: true),
            ),
          ),
          modelSessionProvider.overrideWith(
            (ref) => FakeGemmaService(
              capabilitiesData: const ModelCapabilities(functionCalling: true),
            ),
          ),
          webUrlLauncherProvider.overrideWithValue(launcher),
        ],
      );

      await open(tester, conversationId);

      // Both web chips re-render with the right recipient tags + status summaries.
      expect(find.text('WEB_SEARCH · Tavily'), findsOneWidget);
      expect(find.text('3 results for "latest dart version"'), findsOneWidget);
      expect(find.text('FETCH_PAGE · flutter.dev'), findsOneWidget);
      expect(find.text('fetched flutter.dev'), findsOneWidget);

      // The error chip re-renders with its original reason + red glyph.
      expect(
        find.text(
          'could not reach down.example.com — check the URL or try later',
        ),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.error_outline), findsOneWidget);

      // Source URL chips present + tappable (one set under the search reply, one under the fetch).
      expect(find.byType(SourceUrlChips), findsNWidgets(2));
      final chips = find.byKey(SourceUrlChips.chipKey);
      expect(chips, findsNWidgets(4)); // 3 search urls + 1 fetch url
      await tester.tap(chips.first);
      await tester.pump();
      expect(launcher.opened, isNotEmpty);

      // No full snippet/body in rendered content — only metadata-derived summaries/hosts.
      expect(find.textContaining('SNIPPET BODY'), findsNothing);
      expect(find.textContaining('EXTRACTED PAGE BODY'), findsNothing);
      expect(find.textContaining('function_call'), findsNothing);
      expect(find.textContaining('"content"'), findsNothing);

      // All three tool chips render despite web being OFF now (persisted artefacts, FR-025).
      expect(find.byType(ToolChip), findsNWidgets(3));
      expect(tester.takeException(), isNull);
    },
  );
}

/// Seed user → web_search(success) → reply → user → fetch_page(success) → reply →
/// user → web_search(error) → reply. Persisted result shapes are metadata-only (T049 invariant).
Future<int> _seed(ConversationRepository repo) async {
  final conv = await repo.createConversation();

  // 1) web_search success (3 grounding urls; metadata-only result, NO content bodies).
  await repo.appendUserMessage(conv.id, 'what is the latest dart version?');
  final searchId = await repo.appendToolInvocation(
    conversationId: conv.id,
    toolName: 'web_search',
    args: const {'query': 'latest dart version'},
  );
  await repo.finalizeToolInvocation(
    searchId,
    status: ToolCallStatus.success,
    result: const {
      'results': [
        {'title': 'Dart 3.5', 'url': 'https://dart.dev/news'},
        {'title': 'Guides', 'url': 'https://dart.dev/guides'},
        {'title': 'Wikipedia', 'url': 'https://en.wikipedia.org/wiki/Dart'},
      ],
      'sourceUrls': [
        'https://dart.dev/news',
        'https://dart.dev/guides',
        'https://en.wikipedia.org/wiki/Dart',
      ],
    },
    summary: '3 results for "latest dart version"',
  );
  final reply1 = await repo.beginAssistantMessage(conv.id);
  await repo.updateAssistantContent(reply1, 'dart 3.5 is the latest stable.');
  await repo.finalizeAssistantMessage(reply1, MessageStatus.complete);

  // 2) fetch_page success (metadata-only; NO extractedText body).
  await repo.appendUserMessage(conv.id, 'read flutter.dev for me');
  final fetchId = await repo.appendToolInvocation(
    conversationId: conv.id,
    toolName: 'fetch_page',
    args: const {'url': 'https://flutter.dev/docs'},
  );
  await repo.finalizeToolInvocation(
    fetchId,
    status: ToolCallStatus.success,
    result: const {
      'url': 'https://flutter.dev/docs',
      'truncated': false,
      'sourceUrls': ['https://flutter.dev/docs'],
    },
    summary: 'fetched flutter.dev',
  );
  final reply2 = await repo.beginAssistantMessage(conv.id);
  await repo.updateAssistantContent(reply2, 'the page covers widgets.');
  await repo.finalizeAssistantMessage(reply2, MessageStatus.complete);

  // 3) web_search error (original reason preserved).
  await repo.appendUserMessage(conv.id, 'check down.example.com');
  final errId = await repo.appendToolInvocation(
    conversationId: conv.id,
    toolName: 'fetch_page',
    args: const {'url': 'https://down.example.com'},
  );
  await repo.finalizeToolInvocation(
    errId,
    status: ToolCallStatus.error,
    result: const {
      'error': 'could not reach down.example.com — check the URL or try later',
    },
    summary: 'could not reach down.example.com — check the URL or try later',
  );
  final reply3 = await repo.beginAssistantMessage(conv.id);
  await repo.updateAssistantContent(reply3, "i couldn't open that one.");
  await repo.finalizeAssistantMessage(reply3, MessageStatus.complete);

  return conv.id;
}
