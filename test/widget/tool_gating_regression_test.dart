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

/// 004 US3 (SC-007, FR-010) — flag-off is regression-locked: a fresh chat turn under a text-only
/// model produces ZERO chips (byte-parity with 003), and persisted tool chips from history STILL
/// render even when the active model can't call tools (the 002/003 history-outlives-capability
/// rule).
void main() {
  late FakeGemmaService gemma;
  late ProviderContainer container;

  setUp(() {
    // A text-only model — function calling OFF.
    gemma = FakeGemmaService(capabilitiesData: ModelCapabilities.textOnly);
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

  testWidgets(
    'flag-off: a fresh chat turn produces zero chips (text-only parity)',
    (tester) async {
      gemma
        ..scriptedDeltas = ['plain ', 'reply']
        ..deltaInterval = const Duration(milliseconds: 20);

      await tester.pumpWidget(app());
      await tester.pump();

      await tester.enterText(find.byKey(Composer.fieldKey), 'hello');
      await tester.pump();
      await tester.tap(find.byKey(Composer.sendKey));
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 25));
      }

      expect(find.textContaining('plain reply'), findsOneWidget);
      expect(
        find.byType(ToolChip),
        findsNothing,
        reason: 'no chips when function calling is off',
      );
    },
  );

  testWidgets(
    'flag-off: a persisted tool chip from history STILL renders (FR-010)',
    (tester) async {
      final repo = container.read(conversationRepositoryProvider);
      final conversationId = await _seedToolChip(repo);

      await tester.pumpWidget(app());
      await tester.pump();
      unawaited(
        container
            .read(chatControllerProvider.notifier)
            .openConversation(conversationId),
      );
      await tester.pump();
      await tester.pump();

      // The chip outlives the capability that produced it.
      expect(find.byType(ToolChip), findsOneWidget);
      expect(find.text('TOOL · GET_DEVICE_INFO'), findsOneWidget);
    },
  );
}

Future<int> _seedToolChip(ConversationRepository repo) async {
  final conv = await repo.createConversation();
  await repo.appendUserMessage(conv.id, 'battery?');
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
  await repo.updateAssistantContent(assistantId, '83%');
  await repo.finalizeAssistantMessage(assistantId, MessageStatus.complete);
  return conv.id;
}
