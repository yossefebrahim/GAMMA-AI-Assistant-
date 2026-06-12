import 'dart:async';

import 'package:ai_assistant/app/theme/app_theme.dart';
import 'package:ai_assistant/app/widgets/dot_pulse.dart';
import 'package:ai_assistant/data/repositories/drift_conversation_repository.dart';
import 'package:ai_assistant/domain/entities/model_capabilities.dart';
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

/// 004 US7 (data-model §4) — a `running` tool row left by a killed process is swept to
/// `error('interrupted')` on startup, so reopened history NEVER shows an in-flight chip (no
/// dot-pulse). The startup sweep runs in ChatController.build().
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

  testWidgets(
    'a stale running tool row is swept and renders as a terminal chip, no dot-pulse',
    (tester) async {
      final repo = container.read(conversationRepositoryProvider);
      final conversationId = await _seedRunningTool(repo);

      await tester.pumpWidget(app());
      await tester
          .pump(); // resolve model session + trigger ChatController.build (the sweep)
      unawaited(
        container
            .read(chatControllerProvider.notifier)
            .openConversation(conversationId),
      );
      // Pump through the fire-and-forget sweep + the reactive re-emit.
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }

      // The chip renders, but NOT in the running state (no dot-pulse) — it was finalized.
      expect(find.byType(ToolChip), findsOneWidget);
      expect(find.byKey(ToolChip.runningKey), findsNothing);
      expect(find.byType(DotPulse), findsNothing);

      // The persisted row is now error('interrupted').
      final rows = await repo.loadTurns(conversationId);
      final chip = rows.firstWhere((m) => m.isTool);
      expect(chip.toolResult, {'error': 'interrupted'});
    },
  );
}

Future<int> _seedRunningTool(ConversationRepository repo) async {
  final conv = await repo.createConversation();
  await repo.appendUserMessage(conv.id, 'battery?');
  // A tool row appended but never finalized — the killed-process scenario.
  await repo.appendToolInvocation(
    conversationId: conv.id,
    toolName: 'get_device_info',
    args: const {},
  );
  return conv.id;
}
