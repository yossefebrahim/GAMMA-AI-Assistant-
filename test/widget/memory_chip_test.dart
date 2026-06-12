import 'dart:async';

import 'package:ai_assistant/app/theme/app_theme.dart';
import 'package:ai_assistant/data/repositories/drift_conversation_repository.dart';
import 'package:ai_assistant/data/repositories/drift_memory_repository.dart';
import 'package:ai_assistant/domain/entities/memory.dart';
import 'package:ai_assistant/domain/entities/message.dart';
import 'package:ai_assistant/domain/entities/model_capabilities.dart';
import 'package:ai_assistant/domain/entities/tool_outcome.dart';
import 'package:ai_assistant/domain/repositories/conversation_repository.dart';
import 'package:ai_assistant/features/chat/chat_controller.dart';
import 'package:ai_assistant/features/chat/chat_providers.dart';
import 'package:ai_assistant/features/chat/chat_screen.dart';
import 'package:ai_assistant/features/chat/widgets/tool_chip.dart';
import 'package:ai_assistant/infrastructure/gemma/flutter_gemma_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/container_harness.dart';
import '../helpers/fake_gemma_service.dart';
import '../helpers/fake_memory_repository.dart';

/// T018 (US1 AS1–AS3) + T034 (US5 AS1–AS3) — memory tool chips.
///
/// Pure RENDERING tests: conversations are seeded via the repository (rows already persisted with
/// the correct status/summary), then the reactive watchMessages emission drives the list widget.
/// This is deliberately NOT bare-awaiting fake Gemma streams in a widget test (the model-restore-
/// recipe / hang hazard documented in the widget-test async pattern memory note).
///
/// US1 AS1: a `remember_fact` success chip renders with "TOOL · REMEMBER_FACT" + "remembered: …".
/// US1 AS2: a no-fact prompt that never calls the tool renders NO ToolChip.
/// US1 AS3: an invalid-args capture renders an error chip + an honest reply bubble.
///
/// US5 AS1: a `forget_fact` success chip renders with "TOOL · FORGET_FACT" + "forgot #`<id>`".
/// US5 AS2: an unknown-id forget chip renders with the error state + an honest reply bubble.
/// US5 AS3: an unknown-id forget does NOT soft-delete any active fact (no deletion side-effect).
void main() {
  late FakeGemmaService gemma;
  late FakeMemoryRepository memRepo;
  late ProviderContainer container;

  setUp(() {
    gemma = FakeGemmaService(
      capabilitiesData: const ModelCapabilities(functionCalling: true),
    );
    memRepo = FakeMemoryRepository();
    container = makeContainer(
      overrides: [
        gemmaServiceProvider.overrideWithValue(gemma),
        modelSessionProvider.overrideWith((ref) => gemma),
        memoryRepositoryProvider.overrideWithValue(memRepo),
      ],
    );
  });

  tearDown(() async {
    container.dispose();
    await memRepo.dispose();
  });

  Widget app() => UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: ThemeMode.dark,
      home: const ChatScreen(),
    ),
  );

  // ---------------------------------------------------------------------------
  // Helpers: seed the three row shapes the controller produces for each outcome.
  // ---------------------------------------------------------------------------

  /// Seeds: user message → remember_fact success chip → assistant reply.
  Future<int> seedRememberFactSuccess(
    ConversationRepository repo, {
    String fact = 'prefers dark mode',
    String summary = 'remembered: prefers dark mode',
  }) async {
    final conv = await repo.createConversation();
    await repo.appendUserMessage(conv.id, 'i prefer dark mode');
    final toolId = await repo.appendToolInvocation(
      conversationId: conv.id,
      toolName: 'remember_fact',
      args: const {'fact': 'prefers dark mode', 'category': 'preferences'},
    );
    await repo.finalizeToolInvocation(
      toolId,
      status: ToolCallStatus.success,
      result: const {
        'remembered': 'prefers dark mode',
        'category': 'preferences',
      },
      summary: summary,
    );
    final assistantId = await repo.beginAssistantMessage(conv.id);
    await repo.updateAssistantContent(
      assistantId,
      'got it, i will remember that',
    );
    await repo.finalizeAssistantMessage(assistantId, MessageStatus.complete);
    return conv.id;
  }

  /// Seeds: user message → assistant reply only (no tool chip).
  Future<int> seedNoToolTurn(ConversationRepository repo) async {
    final conv = await repo.createConversation();
    await repo.appendUserMessage(conv.id, 'what is the weather?');
    final assistantId = await repo.beginAssistantMessage(conv.id);
    await repo.updateAssistantContent(
      assistantId,
      "i can't check the weather, but here's what i know…",
    );
    await repo.finalizeAssistantMessage(assistantId, MessageStatus.complete);
    return conv.id;
  }

  /// Seeds: user message → remember_fact error chip (invalid args) → assistant reply.
  Future<int> seedRememberFactError(ConversationRepository repo) async {
    final conv = await repo.createConversation();
    await repo.appendUserMessage(
      conv.id,
      'remember something very very long please',
    );
    final toolId = await repo.appendToolInvocation(
      conversationId: conv.id,
      toolName: 'remember_fact',
      args: const {
        'fact':
            'this is a fact that is deliberately way too long exceeding the eighty character limit that the schema enforces',
        'category': 'other',
      },
    );
    await repo.finalizeToolInvocation(
      toolId,
      status: ToolCallStatus.error,
      result: const {'error': 'fact exceeds 80 characters'},
      summary: 'fact exceeds 80 characters',
    );
    final assistantId = await repo.beginAssistantMessage(conv.id);
    await repo.updateAssistantContent(
      assistantId,
      "sorry, i couldn't save that — it's too long",
    );
    await repo.finalizeAssistantMessage(assistantId, MessageStatus.complete);
    return conv.id;
  }

  /// Seeds: user message → forget_fact success chip → assistant reply.
  Future<int> seedForgetFactSuccess(
    ConversationRepository repo, {
    int id = 3,
  }) async {
    final conv = await repo.createConversation();
    await repo.appendUserMessage(conv.id, 'forget fact number $id');
    final toolId = await repo.appendToolInvocation(
      conversationId: conv.id,
      toolName: 'forget_fact',
      args: {'id': id},
    );
    await repo.finalizeToolInvocation(
      toolId,
      status: ToolCallStatus.success,
      result: {'forgot': id},
      summary: 'forgot #$id',
    );
    final assistantId = await repo.beginAssistantMessage(conv.id);
    await repo.updateAssistantContent(
      assistantId,
      'done, fact $id has been removed',
    );
    await repo.finalizeAssistantMessage(assistantId, MessageStatus.complete);
    return conv.id;
  }

  /// Seeds: user message → forget_fact error chip (unknown id) → assistant reply.
  Future<int> seedForgetFactUnknownId(
    ConversationRepository repo, {
    int id = 99,
  }) async {
    final conv = await repo.createConversation();
    await repo.appendUserMessage(conv.id, 'forget fact $id');
    final toolId = await repo.appendToolInvocation(
      conversationId: conv.id,
      toolName: 'forget_fact',
      args: {'id': id},
    );
    await repo.finalizeToolInvocation(
      toolId,
      status: ToolCallStatus.error,
      result: {'error': 'no such fact: $id'},
      summary: 'no such fact: $id',
    );
    final assistantId = await repo.beginAssistantMessage(conv.id);
    await repo.updateAssistantContent(
      assistantId,
      "i couldn't find a fact with that id",
    );
    await repo.finalizeAssistantMessage(assistantId, MessageStatus.complete);
    return conv.id;
  }

  // ---------------------------------------------------------------------------
  // T018 — US1: capture a fact (AS1–AS3)
  // ---------------------------------------------------------------------------

  group('T018 US1 — remember_fact chip', () {
    testWidgets(
      'AS1: a remember_fact success chip renders with correct tag and "remembered: …" summary',
      (tester) async {
        final repo = container.read(conversationRepositoryProvider);
        final conversationId = await seedRememberFactSuccess(repo);

        await tester.pumpWidget(app());
        await tester.pump(); // resolve model session
        unawaited(
          container
              .read(chatControllerProvider.notifier)
              .openConversation(conversationId),
        );
        await tester.pump(); // rebuild body for the conversation
        await tester.pump(); // drain the reactive watchMessages emission

        // One chip with the correct tool name tag.
        expect(find.byType(ToolChip), findsOneWidget);
        expect(find.text('TOOL · REMEMBER_FACT'), findsOneWidget);

        // The chip carries the "remembered: …" summary (data-model §5).
        expect(find.text('remembered: prefers dark mode'), findsOneWidget);

        // User message and grounded answer are both visible.
        expect(find.text('i prefer dark mode'), findsOneWidget);
        expect(find.text('got it, i will remember that'), findsOneWidget);

        // Ordering: user prompt → chip → grounded reply (data-model §4 ordering rule).
        final userY = tester.getTopLeft(find.text('i prefer dark mode')).dy;
        final chipY = tester.getTopLeft(find.byType(ToolChip)).dy;
        final replyY = tester
            .getTopLeft(find.text('got it, i will remember that'))
            .dy;
        expect(userY, lessThan(chipY));
        expect(chipY, lessThan(replyY));

        // No raw tool-call JSON must reach the rendered text (LeakFilter guarantee).
        expect(find.textContaining('tool_calls'), findsNothing);
      },
    );

    testWidgets(
      'AS1: "updated: …" summary renders on a superseded capture (chip wording for supersede)',
      (tester) async {
        final repo = container.read(conversationRepositoryProvider);
        // Seed a supersede outcome (the handler would return `updated` key).
        final conv = await repo.createConversation();
        await repo.appendUserMessage(conv.id, 'i use dark mode actually');
        final toolId = await repo.appendToolInvocation(
          conversationId: conv.id,
          toolName: 'remember_fact',
          args: const {'fact': 'prefers dark mode', 'category': 'preferences'},
        );
        await repo.finalizeToolInvocation(
          toolId,
          status: ToolCallStatus.success,
          result: const {
            'updated': 'prefers dark mode',
            'category': 'preferences',
          },
          summary: 'updated: prefers dark mode',
        );
        final assistantId = await repo.beginAssistantMessage(conv.id);
        await repo.updateAssistantContent(
          assistantId,
          'noted, updated that for you',
        );
        await repo.finalizeAssistantMessage(
          assistantId,
          MessageStatus.complete,
        );

        await tester.pumpWidget(app());
        await tester.pump();
        unawaited(
          container
              .read(chatControllerProvider.notifier)
              .openConversation(conv.id),
        );
        await tester.pump();
        await tester.pump();

        expect(find.byType(ToolChip), findsOneWidget);
        expect(find.text('TOOL · REMEMBER_FACT'), findsOneWidget);
        expect(find.text('updated: prefers dark mode'), findsOneWidget);
      },
    );

    testWidgets('AS2: a no-fact prompt (text-only turn) produces NO ToolChip', (
      tester,
    ) async {
      final repo = container.read(conversationRepositoryProvider);
      final conversationId = await seedNoToolTurn(repo);

      await tester.pumpWidget(app());
      await tester.pump();
      unawaited(
        container
            .read(chatControllerProvider.notifier)
            .openConversation(conversationId),
      );
      await tester.pump();
      await tester.pump();

      // Exactly zero chips — the turn was text-only.
      expect(find.byType(ToolChip), findsNothing);

      // The user message and assistant reply are both shown.
      expect(find.text('what is the weather?'), findsOneWidget);
      expect(find.textContaining("i can't check the weather"), findsOneWidget);
    });

    testWidgets(
      'AS3: an invalid-args capture renders an error chip with red border + an honest reply',
      (tester) async {
        final repo = container.read(conversationRepositoryProvider);
        final conversationId = await seedRememberFactError(repo);

        await tester.pumpWidget(app());
        await tester.pump();
        unawaited(
          container
              .read(chatControllerProvider.notifier)
              .openConversation(conversationId),
        );
        await tester.pump();
        await tester.pump();

        // One error chip present.
        expect(find.byType(ToolChip), findsOneWidget);
        expect(find.text('TOOL · REMEMBER_FACT'), findsOneWidget);

        // The error summary is shown.
        expect(find.text('fact exceeds 80 characters'), findsOneWidget);

        // The error icon is present — error state uses the sanctioned red glyph.
        expect(find.byIcon(Icons.error_outline), findsOneWidget);

        // The honest assistant reply is also shown (the model was told about the failure).
        expect(
          find.textContaining("sorry, i couldn't save that"),
          findsOneWidget,
        );
      },
    );
  });

  // ---------------------------------------------------------------------------
  // T034 — US5: forget by asking (AS1–AS3)
  // ---------------------------------------------------------------------------

  group('T034 US5 — forget_fact chip', () {
    testWidgets(
      'AS1: a forget_fact success chip renders with correct tag and "forgot #<id>" summary',
      (tester) async {
        final repo = container.read(conversationRepositoryProvider);
        final conversationId = await seedForgetFactSuccess(repo, id: 3);

        await tester.pumpWidget(app());
        await tester.pump();
        unawaited(
          container
              .read(chatControllerProvider.notifier)
              .openConversation(conversationId),
        );
        await tester.pump();
        await tester.pump();

        expect(find.byType(ToolChip), findsOneWidget);
        expect(find.text('TOOL · FORGET_FACT'), findsOneWidget);

        // The chip carries "forgot #<id>" (data-model §5 chip table).
        expect(find.text('forgot #3'), findsOneWidget);

        // User message and grounded answer are present.
        expect(find.text('forget fact number 3'), findsOneWidget);
        expect(find.text('done, fact 3 has been removed'), findsOneWidget);

        // Ordering: user → chip → reply.
        final userY = tester.getTopLeft(find.text('forget fact number 3')).dy;
        final chipY = tester.getTopLeft(find.byType(ToolChip)).dy;
        final replyY = tester
            .getTopLeft(find.text('done, fact 3 has been removed'))
            .dy;
        expect(userY, lessThan(chipY));
        expect(chipY, lessThan(replyY));

        // No raw JSON leak.
        expect(find.textContaining('tool_calls'), findsNothing);
      },
    );

    testWidgets(
      'AS2: an unknown-id forget renders an honest error chip + an honest reply bubble',
      (tester) async {
        final repo = container.read(conversationRepositoryProvider);
        final conversationId = await seedForgetFactUnknownId(repo, id: 99);

        await tester.pumpWidget(app());
        await tester.pump();
        unawaited(
          container
              .read(chatControllerProvider.notifier)
              .openConversation(conversationId),
        );
        await tester.pump();
        await tester.pump();

        // One error chip.
        expect(find.byType(ToolChip), findsOneWidget);
        expect(find.text('TOOL · FORGET_FACT'), findsOneWidget);

        // The error summary shows the structured failure message (no fuzzy delete).
        expect(find.text('no such fact: 99'), findsOneWidget);

        // The error icon is present.
        expect(find.byIcon(Icons.error_outline), findsOneWidget);

        // The honest assistant reply is shown.
        expect(
          find.textContaining("i couldn't find a fact with that id"),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'AS3: an unknown-id forget does NOT soft-delete any active fact in the repository',
      (tester) async {
        // Pre-seed the fake repo with a real active fact so we can verify it survives.
        final before = await memRepo.activeCount();
        // The fake repo starts empty; any upsert below is our canary.
        await memRepo.upsert(
          fact: 'name is Joe',
          category: MemoryCategory.identity,
        );
        expect(await memRepo.activeCount(), before + 1);

        // Attempt to soft-delete a non-existent id.
        final deleted = await memRepo.softDeleteById(99);
        expect(deleted, isFalse);

        // The existing active fact was NOT touched.
        expect(await memRepo.activeCount(), before + 1);
        final facts = await memRepo.listActive();
        expect(facts.any((m) => m.fact == 'name is Joe'), isTrue);

        // Render the error chip for the unknown-id scenario.
        final repo = container.read(conversationRepositoryProvider);
        final conversationId = await seedForgetFactUnknownId(repo, id: 99);

        await tester.pumpWidget(app());
        await tester.pump();
        unawaited(
          container
              .read(chatControllerProvider.notifier)
              .openConversation(conversationId),
        );
        await tester.pump();
        await tester.pump();

        // Error chip is shown (no deletion happened).
        expect(find.byType(ToolChip), findsOneWidget);
        expect(find.text('TOOL · FORGET_FACT'), findsOneWidget);
        expect(find.text('no such fact: 99'), findsOneWidget);

        // The active count is still the same — no phantom delete.
        expect(await memRepo.activeCount(), before + 1);
      },
    );

    testWidgets(
      'a remember_fact chip and a forget_fact chip both render correctly in the same conversation',
      (tester) async {
        // Two tool turns in one conversation.
        final repo = container.read(conversationRepositoryProvider);
        final conv = await repo.createConversation();

        // First turn: remember.
        await repo.appendUserMessage(conv.id, 'my name is Joe');
        final remToolId = await repo.appendToolInvocation(
          conversationId: conv.id,
          toolName: 'remember_fact',
          args: const {'fact': 'name is Joe', 'category': 'identity'},
        );
        await repo.finalizeToolInvocation(
          remToolId,
          status: ToolCallStatus.success,
          result: const {'remembered': 'name is Joe', 'category': 'identity'},
          summary: 'remembered: name is joe',
        );
        final remAssistantId = await repo.beginAssistantMessage(conv.id);
        await repo.updateAssistantContent(remAssistantId, 'got it, joe');
        await repo.finalizeAssistantMessage(
          remAssistantId,
          MessageStatus.complete,
        );

        // Second turn: forget.
        await repo.appendUserMessage(conv.id, 'forget that');
        final forgetToolId = await repo.appendToolInvocation(
          conversationId: conv.id,
          toolName: 'forget_fact',
          args: const {'id': 1},
        );
        await repo.finalizeToolInvocation(
          forgetToolId,
          status: ToolCallStatus.success,
          result: const {'forgot': 1},
          summary: 'forgot #1',
        );
        final forgetAssistantId = await repo.beginAssistantMessage(conv.id);
        await repo.updateAssistantContent(
          forgetAssistantId,
          'done, removed that',
        );
        await repo.finalizeAssistantMessage(
          forgetAssistantId,
          MessageStatus.complete,
        );

        await tester.pumpWidget(app());
        await tester.pump();
        unawaited(
          container
              .read(chatControllerProvider.notifier)
              .openConversation(conv.id),
        );
        await tester.pump();
        await tester.pump();

        // Both chips must be present.
        expect(find.byType(ToolChip), findsNWidgets(2));
        expect(find.text('TOOL · REMEMBER_FACT'), findsOneWidget);
        expect(find.text('TOOL · FORGET_FACT'), findsOneWidget);
        expect(find.text('remembered: name is joe'), findsOneWidget);
        expect(find.text('forgot #1'), findsOneWidget);
      },
    );
  });
}
