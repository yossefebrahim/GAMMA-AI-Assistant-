import 'package:ai_assistant/app/router.dart';
import 'package:ai_assistant/app/theme/app_theme.dart';
import 'package:ai_assistant/data/model/background_model_downloader.dart';
import 'package:ai_assistant/data/repositories/drift_conversation_repository.dart';
import 'package:ai_assistant/domain/repositories/conversation_repository.dart';
import 'package:ai_assistant/features/chat/chat_controller.dart';
import 'package:ai_assistant/features/chat/chat_providers.dart';
import 'package:ai_assistant/features/history/history_screen.dart';
import 'package:ai_assistant/infrastructure/gemma/flutter_gemma_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/container_harness.dart';
import '../helpers/fake_gemma_service.dart';
import '../helpers/fake_model_downloader.dart';

/// US4 history widget tests (FR-019–FR-022) over an in-memory drift DB.
void main() {
  late ProviderContainer container;
  late FakeGemmaService gemma;

  setUp(() {
    gemma = FakeGemmaService();
    container = makeContainer(
      overrides: [
        // Keep chat navigation (on row tap) safe in tests — no native model / path_provider, and
        // a ready model session so chat renders its body (no infinite loading-pulse timer).
        modelDownloaderProvider.overrideWithValue(FakeModelDownloader()..completedPath = null),
        gemmaServiceProvider.overrideWithValue(gemma),
        modelSessionProvider.overrideWith((ref) => gemma),
      ],
    );
  });

  tearDown(() => container.dispose());

  ConversationRepository repo() => container.read(conversationRepositoryProvider);

  Widget app() => UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light,
          darkTheme: AppTheme.dark,
          themeMode: ThemeMode.dark,
          home: const HistoryScreen(),
          onGenerateRoute: AppRouter.onGenerateRoute,
        ),
      );

  testWidgets('reactively shows labels + timestamps and updates on create (FR-020/FR-021)',
      (tester) async {
    await tester.pumpWidget(app());
    await tester.pump();
    expect(find.text('no conversations yet.'), findsOneWidget);

    final conversation = await repo().createConversation();
    await repo().appendUserMessage(conversation.id, 'first message here');
    await tester.pump(); // receive the reactive emission
    await tester.pump();

    expect(find.text('first message here'), findsOneWidget); // derived label (FR-021)
    expect(find.textContaining('·'), findsWidgets); // timestamp spec line
  });

  testWidgets('tapping a row opens that conversation in chat (FR-020)', (tester) async {
    final conversation = await repo().createConversation();
    await repo().appendUserMessage(conversation.id, 'open me');

    await tester.pumpWidget(app());
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byKey(HistoryScreen.rowKey(conversation.id)));
    await tester.pumpAndSettle(); // openConversation, then navigate into chat

    expect(container.read(chatControllerProvider).conversationId, conversation.id);
  });

  testWidgets('deleting a conversation removes it after confirmation (FR-022)', (tester) async {
    final keep = await repo().createConversation();
    await repo().appendUserMessage(keep.id, 'keep me');
    final remove = await repo().createConversation();
    await repo().appendUserMessage(remove.id, 'delete me');

    await tester.pumpWidget(app());
    await tester.pump();
    await tester.pump();
    expect(find.byKey(HistoryScreen.rowKey(remove.id)), findsOneWidget);

    await tester.tap(find.byKey(HistoryScreen.deleteKey(remove.id)));
    await tester.pumpAndSettle(); // open the confirm dialog
    expect(find.text('delete conversation?'), findsOneWidget);

    await tester.tap(find.text('delete'));
    await tester.pump(); // run the delete
    await tester.pump(); // receive the reactive emission

    expect(find.byKey(HistoryScreen.rowKey(remove.id)), findsNothing);
    expect(find.byKey(HistoryScreen.rowKey(keep.id)), findsOneWidget);
  });
}
