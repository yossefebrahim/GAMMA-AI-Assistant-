import 'dart:io';

import 'package:ai_assistant/data/audio/audio_file_store.dart';
import 'package:ai_assistant/data/db/app_database.dart';
import 'package:ai_assistant/data/images/image_file_store.dart';
import 'package:ai_assistant/data/repositories/drift_conversation_repository.dart';
import 'package:ai_assistant/domain/entities/message.dart';
import 'package:ai_assistant/domain/entities/tool_outcome.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_db.dart';

/// 004 contract conversation_repository.md — tool-row persistence over REAL in-memory drift:
/// append→finalize round-trip, terminal-state-only finalize, invariant violations, sequence
/// ordering, conversation-delete cascade, and the stale-`running` sweep (data-model §4).
void main() {
  late AppDatabase db;
  late Directory docsDir;
  late DriftConversationRepository repo;

  setUp(() {
    db = newTestDatabase();
    docsDir = Directory.systemTemp.createTempSync('repo_tool_docs_');
    repo = DriftConversationRepository(
      db,
      ImageFileStore(documentsDirectory: () async => docsDir),
      AudioFileStore(documentsDirectory: () async => docsDir),
    );
  });

  tearDown(() async {
    await db.close();
    if (docsDir.existsSync()) docsDir.deleteSync(recursive: true);
  });

  test(
    'append → finalize round-trips a tool row (running → success)',
    () async {
      final conv = await repo.createConversation();
      final id = await repo.appendToolInvocation(
        conversationId: conv.id,
        toolName: 'get_device_info',
        args: const {'section': 'battery'},
      );

      var rows = await repo.loadTurns(conv.id);
      expect(rows.single.role, MessageRole.tool);
      expect(rows.single.toolName, 'get_device_info');
      expect(rows.single.toolArgs, {'section': 'battery'});
      expect(rows.single.toolStatus, ToolCallStatus.running);

      await repo.finalizeToolInvocation(
        id,
        status: ToolCallStatus.success,
        result: const {'battery': 83},
        summary: 'battery 83%',
      );

      rows = await repo.loadTurns(conv.id);
      expect(rows.single.toolStatus, ToolCallStatus.success);
      expect(rows.single.toolResult, {'battery': 83});
      expect(rows.single.content, 'battery 83%');
    },
  );

  test(
    'finalize rejects the running state (terminal states only — guarantee 2)',
    () async {
      final conv = await repo.createConversation();
      final id = await repo.appendToolInvocation(
        conversationId: conv.id,
        toolName: 'set_timer',
        args: const {'seconds': 60},
      );
      expect(
        () => repo.finalizeToolInvocation(
          id,
          status: ToolCallStatus.running,
          summary: 'x',
        ),
        throwsArgumentError,
      );
    },
  );

  test(
    'appendToolInvocation rejects an empty tool name (field invariant)',
    () async {
      final conv = await repo.createConversation();
      expect(
        () => repo.appendToolInvocation(
          conversationId: conv.id,
          toolName: '  ',
          args: const {},
        ),
        throwsArgumentError,
      );
    },
  );

  test(
    'finalize rejects a result over the 4,400-char ceiling (guarantee 4)',
    () async {
      final conv = await repo.createConversation();
      final id = await repo.appendToolInvocation(
        conversationId: conv.id,
        toolName: 'summarize_clipboard',
        args: const {},
      );
      final huge = {'text': 'x' * 5000};
      expect(
        () => repo.finalizeToolInvocation(
          id,
          status: ToolCallStatus.success,
          result: huge,
          summary: 'clip',
        ),
        throwsArgumentError,
      );
    },
  );

  test('sequence ordering is preserved: user → tool → assistant', () async {
    final conv = await repo.createConversation();
    await repo.appendUserMessage(conv.id, 'battery?');
    await repo.appendToolInvocation(
      conversationId: conv.id,
      toolName: 'get_device_info',
      args: const {},
    );
    await repo.beginAssistantMessage(conv.id);

    final rows = await repo.loadTurns(conv.id);
    expect(rows.map((m) => m.role).toList(), [
      MessageRole.user,
      MessageRole.tool,
      MessageRole.assistant,
    ]);
    expect(rows.map((m) => m.sequence).toList(), [0, 1, 2]);
  });

  test('conversation delete cascades tool rows away', () async {
    final conv = await repo.createConversation();
    await repo.appendToolInvocation(
      conversationId: conv.id,
      toolName: 'set_theme',
      args: const {'theme': 'light'},
    );
    await repo.deleteConversation(conv.id);
    expect(await repo.loadTurns(conv.id), isEmpty);
  });

  test('sweep finalizes a stale running row to error(interrupted)', () async {
    final conv = await repo.createConversation();
    await repo.appendToolInvocation(
      conversationId: conv.id,
      toolName: 'get_device_info',
      args: const {},
    );

    final swept = await repo.sweepStaleToolInvocations();
    expect(swept, 1);

    final rows = await repo.loadTurns(conv.id);
    expect(rows.single.toolStatus, ToolCallStatus.error);
    expect(rows.single.toolResult, {'error': 'interrupted'});
    expect(rows.single.content, 'interrupted');

    // Idempotent: a second sweep finds nothing.
    expect(await repo.sweepStaleToolInvocations(), 0);
  });

  test('sweep leaves already-finalized tool rows untouched', () async {
    final conv = await repo.createConversation();
    final id = await repo.appendToolInvocation(
      conversationId: conv.id,
      toolName: 'set_theme',
      args: const {'theme': 'dark'},
    );
    await repo.finalizeToolInvocation(
      id,
      status: ToolCallStatus.success,
      result: const {'theme': 'dark'},
      summary: 'dark theme',
    );
    expect(await repo.sweepStaleToolInvocations(), 0);
  });
}
