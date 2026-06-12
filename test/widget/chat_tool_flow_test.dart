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
import 'package:ai_assistant/features/chat/widgets/message_bubble.dart';
import 'package:ai_assistant/features/chat/widgets/tool_chip.dart';
import 'package:ai_assistant/infrastructure/gemma/flutter_gemma_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/container_harness.dart';
import '../helpers/fake_gemma_service.dart';

/// 004 US1 — a completed tool turn renders a ToolChip BETWEEN the user message and the grounded
/// final answer. The async call→dispatch→resume machine is exercised by the controller-loop unit
/// tests (chat_controller_tool_test); this is a pure RENDERING test, so it seeds the persisted rows
/// via the repository and drives the reactive list with UI+pump — deliberately NOT bare-awaiting
/// fake streams in a widget test (the model-restore-recipe / hang hazard).
void main() {
  late FakeGemmaService gemma;
  late ProviderContainer container;

  setUp(() {
    gemma = FakeGemmaService(
      capabilitiesData: const ModelCapabilities(functionCalling: true),
    );
    container = makeContainer(
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

  /// Seed a user → tool(success) → assistant turn, the exact shape the controller produces.
  Future<int> seedToolTurn(ConversationRepository repo) async {
    final conv = await repo.createConversation();
    await repo.appendUserMessage(conv.id, 'what is my battery?');
    final toolId = await repo.appendToolInvocation(
      conversationId: conv.id,
      toolName: 'get_device_info',
      args: const {},
    );
    await repo.finalizeToolInvocation(
      toolId,
      status: ToolCallStatus.success,
      result: const {'batteryLevel': 83},
      summary: 'batterylevel 83',
    );
    final assistantId = await repo.beginAssistantMessage(conv.id);
    await repo.updateAssistantContent(assistantId, 'your battery is at 83%');
    await repo.finalizeAssistantMessage(assistantId, MessageStatus.complete);
    return conv.id;
  }

  testWidgets(
    'a tool turn renders a chip between the user message and the grounded answer',
    (tester) async {
      final repo = container.read(conversationRepositoryProvider);
      final conversationId = await seedToolTurn(repo);

      await tester.pumpWidget(app());
      await tester.pump(); // resolve the model session
      unawaited(
        container
            .read(chatControllerProvider.notifier)
            .openConversation(conversationId),
      );
      await tester.pump(); // rebuild the body for the conversation
      await tester.pump(); // drain the reactive watchMessages emission

      // Chip + user message + grounded answer all present.
      expect(find.byType(ToolChip), findsOneWidget);
      expect(find.text('TOOL · GET_DEVICE_INFO'), findsOneWidget);
      expect(find.text('what is my battery?'), findsOneWidget);
      expect(find.text('your battery is at 83%'), findsOneWidget);
      // No raw tool-call JSON ever reaches the rendered text (FR-004 / LeakFilter).
      expect(find.textContaining('tool_calls'), findsNothing);

      // Ordering: user bubble appears above the chip, which appears above the answer bubble.
      final userY = tester.getTopLeft(find.text('what is my battery?')).dy;
      final chipY = tester.getTopLeft(find.byType(ToolChip)).dy;
      final answerY = tester.getTopLeft(find.text('your battery is at 83%')).dy;
      expect(userY, lessThan(chipY));
      expect(chipY, lessThan(answerY));
      // The user + answer are bubbles; the chip is not.
      expect(find.byType(MessageBubble), findsNWidgets(2));
    },
  );
}
