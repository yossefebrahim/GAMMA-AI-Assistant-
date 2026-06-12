import 'dart:async';
import 'dart:io';

import 'package:ai_assistant/data/images/image_file_store.dart';
import 'package:ai_assistant/data/repositories/drift_conversation_repository.dart';
import 'package:ai_assistant/domain/entities/generation_event.dart';
import 'package:ai_assistant/domain/entities/image_attachment.dart';
import 'package:ai_assistant/domain/entities/message.dart';
import 'package:ai_assistant/domain/entities/model_capabilities.dart';
import 'package:ai_assistant/domain/entities/tool_outcome.dart';
import 'package:ai_assistant/domain/repositories/conversation_repository.dart';
import 'package:ai_assistant/domain/services/tool_dispatcher.dart';
import 'package:ai_assistant/features/chat/attachment_controller.dart';
import 'package:ai_assistant/features/chat/chat_controller.dart';
import 'package:ai_assistant/features/chat/chat_providers.dart';
import 'package:ai_assistant/features/chat/tool_handler_providers.dart';
import 'package:ai_assistant/infrastructure/gemma/flutter_gemma_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/container_harness.dart';
import '../../helpers/fake_gemma_service.dart';

/// 004 US1 / data-model §4 — the controller tool-turn state machine, over a scripted
/// [FakeGemmaService] + a controllable dispatcher. No native plugin, no device.
void main() {
  late FakeGemmaService gemma;
  late Map<String, ToolHandler> handlers;
  late Directory tempDir;
  late ProviderContainer container;

  setUp(() {
    // Function calling on, so the assembler reserves the instruction budget and the seam path is
    // the tool path.
    gemma = FakeGemmaService(
      capabilitiesData: const ModelCapabilities(
        image: true,
        functionCalling: true,
      ),
    );
    tempDir = Directory.systemTemp.createTempSync('chat_tool_');
    handlers = <String, ToolHandler>{
      'get_device_info': (args) async => {'batteryLevel': 83, 'model': 'A34'},
      'summarize_clipboard': (args) async => throw const _Boom(),
      'set_theme': (args) async => {'theme': args['theme']},
      'set_timer': (args) async => {'seconds': args['seconds']},
    };
    container = makeContainer(
      overrides: [
        gemmaServiceProvider.overrideWithValue(gemma),
        toolDispatcherProvider.overrideWith(
          (ref) => ToolDispatcher(handlers: handlers),
        ),
        imageFileStoreProvider.overrideWithValue(
          ImageFileStore(documentsDirectory: () async => tempDir),
        ),
        modelCapabilitiesProvider.overrideWith(
          (ref) => const ModelCapabilities(image: true, functionCalling: true),
        ),
      ],
    );
  });

  tearDown(() {
    container.dispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  ChatController controller() =>
      container.read(chatControllerProvider.notifier);
  ConversationRepository repo() =>
      container.read(conversationRepositoryProvider);
  Future<List<Message>> turns() async =>
      repo().loadTurns(container.read(chatControllerProvider).conversationId!);

  test(
    'happy path: rows read user → chip(success) → answer; empty assistant row deleted',
    () async {
      gemma.scriptedEvents = [const ToolCallRequested('get_device_info', {})];
      gemma.resumeEvents = [const TextDelta('your battery is at 83%')];

      await controller().send('what is my battery?');

      final rows = await turns();
      expect(rows.map((m) => m.role).toList(), [
        MessageRole.user,
        MessageRole.tool,
        MessageRole.assistant,
      ]);
      expect(rows[1].toolName, 'get_device_info');
      expect(rows[1].toolStatus, ToolCallStatus.success);
      expect(rows[1].toolResult, {'batteryLevel': 83, 'model': 'A34'});
      expect(rows[2].content, 'your battery is at 83%');
      expect(rows[2].status, MessageStatus.complete);
    },
  );

  test(
    'resume payload is the success result (round-trip correctness)',
    () async {
      gemma.scriptedEvents = [const ToolCallRequested('get_device_info', {})];
      gemma.resumeEvents = [const TextDelta('done')];

      await controller().send('battery?');

      expect(gemma.lastResumeToolName, 'get_device_info');
      expect(gemma.lastResumeResult, {'batteryLevel': 83, 'model': 'A34'});
    },
  );

  test(
    'text before the call: the assistant row is finalized, not deleted (ordering)',
    () async {
      gemma.scriptedEvents = [
        const TextDelta('let me check. '),
        const ToolCallRequested('get_device_info', {}),
      ];
      gemma.resumeEvents = [const TextDelta('83%')];

      await controller().send('battery?');

      final rows = await turns();
      // user → assistant('let me check. ') → chip → assistant('83%')
      expect(rows.map((m) => m.role).toList(), [
        MessageRole.user,
        MessageRole.assistant,
        MessageRole.tool,
        MessageRole.assistant,
      ]);
      expect(rows[1].content, 'let me check. ');
      expect(rows[1].status, MessageStatus.complete);
    },
  );

  test('handler failure → error chip + honest resume reply', () async {
    gemma.scriptedEvents = [const ToolCallRequested('summarize_clipboard', {})];
    gemma.resumeEvents = [
      const TextDelta('sorry, the clipboard could not be read'),
    ];

    await controller().send('summarize my clipboard');

    final rows = await turns();
    final chip = rows.firstWhere((m) => m.isTool);
    expect(chip.toolStatus, ToolCallStatus.error);
    expect(chip.toolResult!.containsKey('error'), isTrue);
    // The error payload is fed to the resume so the model can acknowledge it.
    expect(gemma.lastResumeResult!.containsKey('error'), isTrue);
  });

  test(
    'unknown (hallucinated) tool → Unknown error chip, handler untouched, model informed',
    () async {
      gemma.scriptedEvents = [const ToolCallRequested('set_alarm', {})];
      gemma.resumeEvents = [const TextDelta("i can't set alarms, but…")];

      await controller().send('set an alarm');

      final chip = (await turns()).firstWhere((m) => m.isTool);
      expect(chip.toolStatus, ToolCallStatus.error);
      expect(chip.toolResult!['error'], contains('set_alarm'));
      expect(gemma.lastResumeResult!['error'], contains('set_alarm'));
    },
  );

  test(
    'stop BEFORE dispatch → skipped chip, no resume, no execution (FR-026)',
    () async {
      var dispatched = false;
      handlers['get_device_info'] = (args) async {
        dispatched = true;
        return {'batteryLevel': 83};
      };
      gemma.scriptedEvents = [const ToolCallRequested('get_device_info', {})];
      // The instant the call is emitted, the user stops — before the dispatch check.
      gemma.onEmit = (event) {
        if (event is ToolCallRequested) unawaited(controller().stop());
      };

      await controller().send('battery?');

      final chip = (await turns()).firstWhere((m) => m.isTool);
      expect(chip.toolStatus, ToolCallStatus.skipped);
      expect(
        dispatched,
        isFalse,
        reason: 'handler must not run when stopped before dispatch',
      );
      expect(gemma.resumeCount, 0, reason: 'no resume after a skipped tool');
    },
  );

  test(
    'stop AFTER dispatch but before resume → chip finalized truthfully, no resume (FR-026)',
    () async {
      handlers['get_device_info'] = (args) async {
        unawaited(
          controller().stop(),
        ); // user stops while the (fast, local) handler runs
        return {'batteryLevel': 83};
      };
      gemma.scriptedEvents = [const ToolCallRequested('get_device_info', {})];
      gemma.resumeEvents = [const TextDelta('should not be streamed')];

      await controller().send('battery?');

      final chip = (await turns()).firstWhere((m) => m.isTool);
      expect(
        chip.toolStatus,
        ToolCallStatus.success,
        reason: 'handler completed truthfully',
      );
      expect(
        gemma.resumeCount,
        0,
        reason: 'no resume once stop ended the turn',
      );
    },
  );

  test(
    'second tool call on resume → its own error chip, turn ends as text (FR-006/FR-024)',
    () async {
      gemma.scriptedEvents = [const ToolCallRequested('get_device_info', {})];
      // The resume itself tries to call a tool again.
      gemma.resumeEvents = [
        const ToolCallRequested('set_theme', {'theme': 'dark'}),
      ];

      await controller().send('battery then theme');

      final toolRows = (await turns()).where((m) => m.isTool).toList();
      expect(toolRows, hasLength(2));
      expect(toolRows[0].toolStatus, ToolCallStatus.success);
      expect(toolRows[1].toolStatus, ToolCallStatus.error);
      expect(toolRows[1].toolResult!['error'], 'only one tool call per turn');
    },
  );

  test('parallel extras are noted on the executed chip (FR-024)', () async {
    gemma.scriptedEvents = [
      const ToolCallRequested('get_device_info', {}, extraCallCount: 2),
    ];
    gemma.resumeEvents = [const TextDelta('83%')];

    await controller().send('battery?');

    final chip = (await turns()).firstWhere((m) => m.isTool);
    expect(chip.toolStatus, ToolCallStatus.success);
    expect(chip.content, contains('parallel'));
  });

  test(
    'attachment edge case: an image-bearing user turn → tool turn keeps the attachment + order',
    () async {
      gemma.scriptedEvents = [const ToolCallRequested('get_device_info', {})];
      gemma.resumeEvents = [const TextDelta('83%')];

      final imageFile = File('${tempDir.path}/x.jpg')
        ..writeAsBytesSync(List.filled(64, 1));
      await controller().send(
        'what is this and my battery?',
        image: PendingAttachment(path: imageFile.path, mimeType: 'image/jpeg'),
      );

      final rows = await turns();
      expect(rows.first.role, MessageRole.user);
      expect(
        rows.first.image,
        isA<ImageAttachment>(),
        reason: 'attachment persists unchanged',
      );
      expect(rows.map((m) => m.role).toList(), [
        MessageRole.user,
        MessageRole.tool,
        MessageRole.assistant,
      ]);
    },
  );
}

class _Boom implements Exception {
  const _Boom();
  @override
  String toString() => 'clipboard empty or not text';
}
