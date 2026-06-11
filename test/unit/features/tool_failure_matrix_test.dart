import 'package:ai_assistant/data/repositories/drift_conversation_repository.dart';
import 'package:ai_assistant/domain/entities/generation_event.dart';
import 'package:ai_assistant/domain/entities/message.dart';
import 'package:ai_assistant/domain/entities/model_capabilities.dart';
import 'package:ai_assistant/domain/entities/tool_outcome.dart';
import 'package:ai_assistant/domain/repositories/conversation_repository.dart';
import 'package:ai_assistant/domain/services/tool_dispatcher.dart';
import 'package:ai_assistant/features/chat/chat_controller.dart';
import 'package:ai_assistant/features/chat/tool_handler_providers.dart';
import 'package:ai_assistant/infrastructure/gemma/flutter_gemma_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/container_harness.dart';
import '../../helpers/fake_gemma_service.dart';

/// 004 US7 (SC-004) — the graceful-degradation matrix: every bad call ends in a visible chip state
/// + an honest, model-informed text completion, and never a crash. Scripted fakes, no device.
void main() {
  late FakeGemmaService gemma;
  late Map<String, ToolHandler> handlers;
  late ProviderContainer container;

  setUp(() {
    gemma = FakeGemmaService(
        capabilitiesData: const ModelCapabilities(functionCalling: true));
    handlers = <String, ToolHandler>{
      'get_device_info': (args) async => {'batteryLevel': 83},
      'summarize_clipboard': (args) async => throw const _ClipboardEmpty(),
      'set_theme': (args) async => {'theme': args['theme']},
      'set_timer': (args) async => {'seconds': args['seconds']},
    };
    container = makeContainer(overrides: [
      gemmaServiceProvider.overrideWithValue(gemma),
      toolDispatcherProvider.overrideWith((ref) => ToolDispatcher(handlers: handlers)),
    ]);
  });

  tearDown(() => container.dispose());

  ChatController controller() => container.read(chatControllerProvider.notifier);
  ConversationRepository repo() => container.read(conversationRepositoryProvider);
  Future<List<Message>> turns() async =>
      repo().loadTurns(container.read(chatControllerProvider).conversationId!);

  test('hallucinated tool → Unknown error chip + model informed + text completion', () async {
    gemma.scriptedEvents = [const ToolCallRequested('set_alarm', {})];
    gemma.resumeEvents = [const TextDelta("i can't set alarms here.")];

    await controller().send('set an alarm for 7am');

    final rows = await turns();
    final chip = rows.firstWhere((m) => m.isTool);
    expect(chip.toolStatus, ToolCallStatus.error);
    expect(chip.toolResult!['error'], contains('set_alarm'));
    // Model informed via the resume payload, and a final text bubble completes the turn.
    expect(gemma.lastResumeResult!['error'], contains('set_alarm'));
    expect(rows.last.role, MessageRole.assistant);
    expect(rows.last.content, "i can't set alarms here.");
  });

  test('invalid args → InvalidArgs chip, handler untouched', () async {
    var ran = false;
    handlers['set_timer'] = (args) async {
      ran = true;
      return {'set': true};
    };
    gemma.scriptedEvents = [const ToolCallRequested('set_timer', {'seconds': 0})];
    gemma.resumeEvents = [const TextDelta('that duration is not valid.')];

    await controller().send('set a timer for zero seconds');

    final chip = (await turns()).firstWhere((m) => m.isTool);
    expect(chip.toolStatus, ToolCallStatus.error);
    expect(chip.toolResult!['error'], contains('seconds'));
    expect(ran, isFalse, reason: 'the handler never runs on schema-invalid args');
  });

  test('handler failure → error chip + honest resume', () async {
    gemma.scriptedEvents = [const ToolCallRequested('summarize_clipboard', {})];
    gemma.resumeEvents = [const TextDelta('your clipboard appears to be empty.')];

    await controller().send('summarize my clipboard');

    final chip = (await turns()).firstWhere((m) => m.isTool);
    expect(chip.toolStatus, ToolCallStatus.error);
    expect(chip.toolResult!['error'], 'clipboard empty or not text');
    expect(gemma.lastResumeResult!['error'], 'clipboard empty or not text');
  });

  test('extraCallCount > 0 → one chip noting the skipped extras', () async {
    gemma.scriptedEvents = [
      const ToolCallRequested('get_device_info', {}, extraCallCount: 1),
    ];
    gemma.resumeEvents = [const TextDelta('83%')];

    await controller().send('battery and theme at once');

    final toolRows = (await turns()).where((m) => m.isTool).toList();
    expect(toolRows, hasLength(1), reason: 'parallel calls collapse to ONE chip');
    expect(toolRows.single.content, contains('parallel'));
  });

  test('set_timer with whole-valued double seconds → success chip + grounded resume', () async {
    gemma.scriptedEvents = [const ToolCallRequested('set_timer', {'seconds': 300.0})];
    gemma.resumeEvents = [const TextDelta('your 5 minute timer is set.')];

    await controller().send('set a 5 minute timer');

    final rows = await turns();
    final chip = rows.firstWhere((m) => m.isTool);
    expect(chip.toolStatus, ToolCallStatus.success);
    expect(chip.toolResult!['seconds'], 300);
    expect(rows.last.role, MessageRole.assistant);
    expect(rows.last.content, 'your 5 minute timer is set.');
  });

  test('no rendered message content ever contains raw tool-call JSON (FR-004)', () async {
    gemma.scriptedEvents = [const ToolCallRequested('get_device_info', {})];
    gemma.resumeEvents = [const TextDelta('your battery is at 83%')];

    await controller().send('battery?');

    for (final row in await turns()) {
      expect(row.content.contains('tool_calls'), isFalse);
      expect(row.content.contains('"function"'), isFalse);
    }
  });
}

class _ClipboardEmpty implements Exception {
  const _ClipboardEmpty();
  @override
  String toString() => 'clipboard empty or not text';
}
