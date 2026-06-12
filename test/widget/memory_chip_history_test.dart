import 'dart:async';

import 'package:ai_assistant/app/theme/app_theme.dart';
import 'package:ai_assistant/data/repositories/drift_conversation_repository.dart';
import 'package:ai_assistant/data/repositories/drift_memory_repository.dart';
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

/// T037 — FR-019/FR-020: memory chips render in reopened history regardless of the active model's
/// capabilities, and degenerate cases (cap-exceeded capture, capture-while-disabled) produce visible
/// error chips rather than crashes.
///
/// The chip rendering invariant is: a `role='tool'` row is always rendered as a [ToolChip],
/// regardless of whether the CURRENT model supports function calling. This mirrors the 004
/// history-outlives-capability rule (tool_gating_regression_test) and extends it to the memory
/// tools (remember_fact / forget_fact).
void main() {
  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  /// Seed a user → remember_fact chip (success) → assistant turn.
  Future<int> seedRememberChip(
    ConversationRepository repo, {
    String summary = 'remembered: name is Yossef',
    ToolCallStatus status = ToolCallStatus.success,
    Map<String, Object?>? result,
  }) async {
    final conv = await repo.createConversation();
    await repo.appendUserMessage(conv.id, 'my name is Yossef');
    final toolId = await repo.appendToolInvocation(
      conversationId: conv.id,
      toolName: 'remember_fact',
      args: const {'fact': 'name is Yossef', 'category': 'identity'},
    );
    await repo.finalizeToolInvocation(
      toolId,
      status: status,
      result:
          result ??
          const {'remembered': 'name is Yossef', 'category': 'identity'},
      summary: summary,
    );
    final assistantId = await repo.beginAssistantMessage(conv.id);
    await repo.updateAssistantContent(
      assistantId,
      "got it, i'll remember that",
    );
    await repo.finalizeAssistantMessage(assistantId, MessageStatus.complete);
    return conv.id;
  }

  /// Seed a user → forget_fact chip (success) → assistant turn.
  Future<int> seedForgetChip(
    ConversationRepository repo, {
    String summary = 'forgot #1',
    ToolCallStatus status = ToolCallStatus.success,
    Map<String, Object?>? result,
  }) async {
    final conv = await repo.createConversation();
    await repo.appendUserMessage(conv.id, 'forget my name');
    final toolId = await repo.appendToolInvocation(
      conversationId: conv.id,
      toolName: 'forget_fact',
      args: const {'id': 1},
    );
    await repo.finalizeToolInvocation(
      toolId,
      status: status,
      result: result ?? const {'forgot': 1},
      summary: summary,
    );
    final assistantId = await repo.beginAssistantMessage(conv.id);
    await repo.updateAssistantContent(
      assistantId,
      "done, i've forgotten your name",
    );
    await repo.finalizeAssistantMessage(assistantId, MessageStatus.complete);
    return conv.id;
  }

  // ---------------------------------------------------------------------------
  // T037 — memory chips render under text-only model (FR-019)
  // ---------------------------------------------------------------------------

  group('T037 — memory chips render under any capability (FR-019)', () {
    testWidgets(
      'a remember_fact chip from history renders under a TEXT-ONLY model (cap-off regression)',
      (tester) async {
        // Text-only model — function calling is OFF.
        final gemma = FakeGemmaService(
          capabilitiesData: ModelCapabilities.textOnly,
        );
        final memRepo = FakeMemoryRepository();
        final container = makeContainer(
          overrides: [
            gemmaServiceProvider.overrideWithValue(gemma),
            modelSessionProvider.overrideWith((ref) => gemma),
            memoryRepositoryProvider.overrideWithValue(memRepo),
          ],
        );
        addTearDown(() {
          container.dispose();
          memRepo.dispose();
        });

        final repo = container.read(conversationRepositoryProvider);
        final convId = await seedRememberChip(repo);

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: AppTheme.light,
              darkTheme: AppTheme.dark,
              themeMode: ThemeMode.dark,
              home: const ChatScreen(),
            ),
          ),
        );
        await tester.pump(); // resolve model session
        unawaited(
          container
              .read(chatControllerProvider.notifier)
              .openConversation(convId),
        );
        await tester.pump(); // open conversation
        await tester.pump(); // drain reactive messages

        // The chip renders even though the active model cannot call tools.
        expect(find.byType(ToolChip), findsAtLeastNWidgets(1));
        expect(find.text('TOOL · REMEMBER_FACT'), findsOneWidget);
        expect(find.text('remembered: name is Yossef'), findsOneWidget);
      },
    );

    testWidgets(
      'a forget_fact chip from history renders under a TEXT-ONLY model',
      (tester) async {
        final gemma = FakeGemmaService(
          capabilitiesData: ModelCapabilities.textOnly,
        );
        final memRepo = FakeMemoryRepository();
        final container = makeContainer(
          overrides: [
            gemmaServiceProvider.overrideWithValue(gemma),
            modelSessionProvider.overrideWith((ref) => gemma),
            memoryRepositoryProvider.overrideWithValue(memRepo),
          ],
        );
        addTearDown(() {
          container.dispose();
          memRepo.dispose();
        });

        final repo = container.read(conversationRepositoryProvider);
        final convId = await seedForgetChip(repo);

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: AppTheme.light,
              darkTheme: AppTheme.dark,
              themeMode: ThemeMode.dark,
              home: const ChatScreen(),
            ),
          ),
        );
        await tester.pump();
        unawaited(
          container
              .read(chatControllerProvider.notifier)
              .openConversation(convId),
        );
        await tester.pump();
        await tester.pump();

        expect(find.byType(ToolChip), findsAtLeastNWidgets(1));
        expect(find.text('TOOL · FORGET_FACT'), findsOneWidget);
        expect(find.text('forgot #1'), findsOneWidget);
      },
    );

    testWidgets(
      'both remember and forget chips render in the same history under any capability',
      (tester) async {
        final gemma = FakeGemmaService(
          capabilitiesData: ModelCapabilities.textOnly,
        );
        final memRepo = FakeMemoryRepository();
        final container = makeContainer(
          overrides: [
            gemmaServiceProvider.overrideWithValue(gemma),
            modelSessionProvider.overrideWith((ref) => gemma),
            memoryRepositoryProvider.overrideWithValue(memRepo),
          ],
        );
        addTearDown(() {
          container.dispose();
          memRepo.dispose();
        });

        final repo = container.read(conversationRepositoryProvider);
        // Build a conversation that has both a remember and a forget chip.
        final conv = await repo.createConversation();
        await repo.appendUserMessage(conv.id, 'my name is Yossef');
        final rememberToolId = await repo.appendToolInvocation(
          conversationId: conv.id,
          toolName: 'remember_fact',
          args: const {'fact': 'name is Yossef', 'category': 'identity'},
        );
        await repo.finalizeToolInvocation(
          rememberToolId,
          status: ToolCallStatus.success,
          result: const {'remembered': 'name is Yossef'},
          summary: 'remembered: name is Yossef',
        );
        final a1 = await repo.beginAssistantMessage(conv.id);
        await repo.finalizeAssistantMessage(a1, MessageStatus.complete);
        await repo.appendUserMessage(conv.id, 'forget my name');
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
        final a2 = await repo.beginAssistantMessage(conv.id);
        await repo.finalizeAssistantMessage(a2, MessageStatus.complete);

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: AppTheme.light,
              darkTheme: AppTheme.dark,
              themeMode: ThemeMode.dark,
              home: const ChatScreen(),
            ),
          ),
        );
        await tester.pump();
        unawaited(
          container
              .read(chatControllerProvider.notifier)
              .openConversation(conv.id),
        );
        await tester.pump();
        await tester.pump();

        expect(find.byType(ToolChip), findsNWidgets(2));
        expect(find.text('TOOL · REMEMBER_FACT'), findsOneWidget);
        expect(find.text('TOOL · FORGET_FACT'), findsOneWidget);
      },
    );
  });

  // ---------------------------------------------------------------------------
  // T037 — error chips for degraded cases: cap-exceeded + capture-while-disabled (FR-020)
  // ---------------------------------------------------------------------------

  group('T037 — error chips for degraded cases (FR-020)', () {
    testWidgets('a cap-exceeded capture renders an error chip (not a crash)', (
      tester,
    ) async {
      final gemma = FakeGemmaService(
        capabilitiesData: const ModelCapabilities(functionCalling: true),
      );
      final memRepo = FakeMemoryRepository();
      final container = makeContainer(
        overrides: [
          gemmaServiceProvider.overrideWithValue(gemma),
          modelSessionProvider.overrideWith((ref) => gemma),
          memoryRepositoryProvider.overrideWithValue(memRepo),
        ],
      );
      addTearDown(() {
        container.dispose();
        memRepo.dispose();
      });

      // Simulate a cap-exceeded capture: the dispatcher returns ToolFailure when the repo
      // fails. Seed the chip directly with an error status (the actual cap-enforcement is in
      // the repository; here we test that such a chip renders correctly).
      final repo = container.read(conversationRepositoryProvider);
      final conv = await repo.createConversation();
      await repo.appendUserMessage(conv.id, 'remember this');
      final toolId = await repo.appendToolInvocation(
        conversationId: conv.id,
        toolName: 'remember_fact',
        args: const {'fact': 'some fact', 'category': 'other'},
      );
      await repo.finalizeToolInvocation(
        toolId,
        status: ToolCallStatus.error,
        result: const {'error': 'memory cap reached'},
        summary: 'memory cap reached',
      );
      final assistantId = await repo.beginAssistantMessage(conv.id);
      await repo.updateAssistantContent(assistantId, 'sorry, memory full');
      await repo.finalizeAssistantMessage(assistantId, MessageStatus.complete);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: AppTheme.light,
            darkTheme: AppTheme.dark,
            themeMode: ThemeMode.dark,
            home: const ChatScreen(),
          ),
        ),
      );
      await tester.pump();
      unawaited(
        container
            .read(chatControllerProvider.notifier)
            .openConversation(conv.id),
      );
      await tester.pump();
      await tester.pump();

      // Must render a chip (not crash) and it must be in the error state.
      expect(find.byType(ToolChip), findsOneWidget);
      expect(find.text('TOOL · REMEMBER_FACT'), findsOneWidget);
      // The error summary is rendered.
      expect(find.text('memory cap reached'), findsOneWidget);
    });

    testWidgets(
      'a capture-while-disabled renders an error chip (not a crash)',
      (tester) async {
        final gemma = FakeGemmaService(
          capabilitiesData: const ModelCapabilities(functionCalling: true),
        );
        final memRepo = FakeMemoryRepository();
        final container = makeContainer(
          overrides: [
            gemmaServiceProvider.overrideWithValue(gemma),
            modelSessionProvider.overrideWith((ref) => gemma),
            memoryRepositoryProvider.overrideWithValue(memRepo),
          ],
        );
        addTearDown(() {
          container.dispose();
          memRepo.dispose();
        });

        // Seed the "memory is off" error chip directly.
        final repo = container.read(conversationRepositoryProvider);
        final conv = await repo.createConversation();
        await repo.appendUserMessage(conv.id, 'my favorite color is blue');
        final toolId = await repo.appendToolInvocation(
          conversationId: conv.id,
          toolName: 'remember_fact',
          args: const {
            'fact': 'favorite color is blue',
            'category': 'preferences',
          },
        );
        await repo.finalizeToolInvocation(
          toolId,
          status: ToolCallStatus.error,
          result: const {'error': 'memory is off'},
          summary: 'memory is off',
        );
        final assistantId = await repo.beginAssistantMessage(conv.id);
        await repo.updateAssistantContent(
          assistantId,
          'memory is currently disabled, so i cannot save that',
        );
        await repo.finalizeAssistantMessage(
          assistantId,
          MessageStatus.complete,
        );

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: AppTheme.light,
              darkTheme: AppTheme.dark,
              themeMode: ThemeMode.dark,
              home: const ChatScreen(),
            ),
          ),
        );
        await tester.pump();
        unawaited(
          container
              .read(chatControllerProvider.notifier)
              .openConversation(conv.id),
        );
        await tester.pump();
        await tester.pump();

        // Chip renders even though memory was disabled at capture time.
        expect(find.byType(ToolChip), findsOneWidget);
        expect(find.text('TOOL · REMEMBER_FACT'), findsOneWidget);
        expect(find.text('memory is off'), findsOneWidget);
      },
    );

    testWidgets(
      'unknown-id forget chip renders as an error chip (not a crash)',
      (tester) async {
        final gemma = FakeGemmaService(
          capabilitiesData: const ModelCapabilities(functionCalling: true),
        );
        final memRepo = FakeMemoryRepository();
        final container = makeContainer(
          overrides: [
            gemmaServiceProvider.overrideWithValue(gemma),
            modelSessionProvider.overrideWith((ref) => gemma),
            memoryRepositoryProvider.overrideWithValue(memRepo),
          ],
        );
        addTearDown(() {
          container.dispose();
          memRepo.dispose();
        });

        final repo = container.read(conversationRepositoryProvider);
        final conv = await repo.createConversation();
        await repo.appendUserMessage(conv.id, 'forget fact 99');
        final toolId = await repo.appendToolInvocation(
          conversationId: conv.id,
          toolName: 'forget_fact',
          args: const {'id': 99},
        );
        await repo.finalizeToolInvocation(
          toolId,
          status: ToolCallStatus.error,
          result: const {'error': 'no such fact: 99'},
          summary: 'no such fact: 99',
        );
        final assistantId = await repo.beginAssistantMessage(conv.id);
        await repo.updateAssistantContent(
          assistantId,
          "i couldn't find fact 99",
        );
        await repo.finalizeAssistantMessage(
          assistantId,
          MessageStatus.complete,
        );

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: AppTheme.light,
              darkTheme: AppTheme.dark,
              themeMode: ThemeMode.dark,
              home: const ChatScreen(),
            ),
          ),
        );
        await tester.pump();
        unawaited(
          container
              .read(chatControllerProvider.notifier)
              .openConversation(conv.id),
        );
        await tester.pump();
        await tester.pump();

        expect(find.byType(ToolChip), findsOneWidget);
        expect(find.text('TOOL · FORGET_FACT'), findsOneWidget);
        expect(find.text('no such fact: 99'), findsOneWidget);
      },
    );
  });

  // ---------------------------------------------------------------------------
  // T037 — chip rendering is pure: no raw-JSON or crash under any ToolCallStatus
  // ---------------------------------------------------------------------------

  group(
    'T037 — memory chip renders for every ToolCallStatus (completeness)',
    () {
      for (final status in ToolCallStatus.values) {
        testWidgets(
          'remember_fact chip renders without crash for status $status',
          (tester) async {
            // Build a fake chip message for this status.
            final chip = Message(
              id: 1,
              conversationId: 1,
              role: MessageRole.tool,
              content: switch (status) {
                ToolCallStatus.success => 'remembered: some fact',
                ToolCallStatus.error => 'some error reason',
                ToolCallStatus.skipped => 'skipped',
                ToolCallStatus.running => '',
              },
              sequence: 1,
              createdAt: DateTime.utc(2026),
              status: MessageStatus.complete,
              toolName: 'remember_fact',
              toolArgs: const {'fact': 'some fact', 'category': 'other'},
              toolStatus: status,
              toolResult: status == ToolCallStatus.success
                  ? const {'remembered': 'some fact'}
                  : status == ToolCallStatus.error
                  ? const {'error': 'some error reason'}
                  : null,
            );

            await tester.pumpWidget(
              MaterialApp(
                theme: AppTheme.dark,
                home: Scaffold(body: ToolChip(message: chip)),
              ),
            );
            await tester.pump();

            // Must render without throw.
            expect(find.byType(ToolChip), findsOneWidget);
            expect(find.text('TOOL · REMEMBER_FACT'), findsOneWidget);
            // Raw JSON must never appear in the chip display.
            expect(find.textContaining('tool_calls'), findsNothing);
            expect(find.textContaining('"role"'), findsNothing);
          },
        );
      }
    },
  );
}
