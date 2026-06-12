import 'dart:io';

import 'package:ai_assistant/data/audio/audio_file_store.dart';
import 'package:ai_assistant/data/db/app_database.dart';
import 'package:ai_assistant/data/images/image_file_store.dart';
import 'package:ai_assistant/data/repositories/drift_conversation_repository.dart';
import 'package:ai_assistant/domain/entities/message.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/test_db.dart';

/// Repository tests over a REAL in-memory drift database (R3) — exercises actual SQL, the FK
/// cascade, ordering, and `watch` emissions off-device. Covers FR-018/FR-020/FR-021/FR-022 and
/// the stopped-partial retention behind SC-005/FR-014.
void main() {
  late AppDatabase db;
  late Directory tempDir;
  late DriftConversationRepository repo;

  setUp(() {
    db = newTestDatabase();
    tempDir = Directory.systemTemp.createTempSync('repo_test_');
    repo = DriftConversationRepository(
      db,
      ImageFileStore(documentsDirectory: () async => tempDir),
      AudioFileStore(documentsDirectory: () async => tempDir),
    );
  });

  tearDown(() async {
    await db.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('createConversation starts untitled and empty', () async {
    final conversation = await repo.createConversation();
    expect(conversation.id, greaterThan(0));
    expect(conversation.title, isNull);
    expect(await repo.loadTurns(conversation.id), isEmpty);
  });

  test(
    'appendUserMessage trims, persists, sequences, and derives the title (FR-021)',
    () async {
      final conversation = await repo.createConversation();
      final message = await repo.appendUserMessage(
        conversation.id,
        '  hello there  ',
      );

      expect(message.role, MessageRole.user);
      expect(message.content, 'hello there'); // trimmed
      expect(message.status, MessageStatus.complete);
      expect(message.sequence, 0);

      final conversations = await repo.watchConversations().first;
      expect(conversations.single.title, 'hello there');
    },
  );

  test(
    'appendUserMessage rejects empty / whitespace-only text (edge case)',
    () async {
      final conversation = await repo.createConversation();
      expect(
        () => repo.appendUserMessage(conversation.id, '   '),
        throwsA(isA<ArgumentError>()),
      );
    },
  );

  test('title is truncated to 40 chars (FR-021)', () async {
    final conversation = await repo.createConversation();
    await repo.appendUserMessage(conversation.id, 'x' * 50);
    final conversations = await repo.watchConversations().first;
    expect(conversations.single.title, hasLength(40));
  });

  test(
    'history orders by updatedAt desc; new activity bumps a conversation up (FR-020)',
    () async {
      final a = await repo.createConversation();
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final b = await repo.createConversation();

      var conversations = await repo.watchConversations().first;
      expect(conversations.map((c) => c.id).toList(), <int>[b.id, a.id]);

      await Future<void>.delayed(const Duration(milliseconds: 5));
      await repo.appendUserMessage(a.id, 'bump a to the top');

      conversations = await repo.watchConversations().first;
      expect(conversations.first.id, a.id);
    },
  );

  test(
    'assistant turn: streaming → stoppedPartial retains all text (FR-014/SC-005)',
    () async {
      final conversation = await repo.createConversation();
      await repo.appendUserMessage(conversation.id, 'hi');

      final assistantId = await repo.beginAssistantMessage(conversation.id);
      await repo.updateAssistantContent(assistantId, 'partial ');
      await repo.updateAssistantContent(assistantId, 'partial answer');
      await repo.finalizeAssistantMessage(
        assistantId,
        MessageStatus.stoppedPartial,
      );

      final turns = await repo.loadTurns(conversation.id);
      final assistant = turns.firstWhere(
        (m) => m.role == MessageRole.assistant,
      );
      expect(assistant.content, 'partial answer');
      expect(assistant.status, MessageStatus.stoppedPartial);
      // Ordered: user turn first, assistant second.
      expect(turns.map((m) => m.role).toList(), <MessageRole>[
        MessageRole.user,
        MessageRole.assistant,
      ]);
    },
  );

  test('watchConversations emits reactively on create and delete', () async {
    final lengths = <int>[];
    final sub = repo.watchConversations().listen(
      (list) => lengths.add(list.length),
    );

    await pumpEventQueue();
    final conversation = await repo.createConversation();
    await pumpEventQueue();
    await repo.deleteConversation(conversation.id);
    await pumpEventQueue();
    await sub.cancel();

    // Lenient on extra emissions, strict on the observed progression empty → 1 → empty.
    expect(lengths, containsAllInOrder(<int>[0, 1, 0]));
  });

  test('deleteConversation cascades to its messages (FR-022)', () async {
    final conversation = await repo.createConversation();
    await repo.appendUserMessage(conversation.id, 'hello');
    await repo.beginAssistantMessage(conversation.id);

    expect(await db.select(db.messages).get(), isNotEmpty);

    await repo.deleteConversation(conversation.id);

    expect(
      await db.select(db.messages).get(),
      isEmpty,
      reason: 'FK cascade should remove messages',
    );
    expect(await repo.loadTurns(conversation.id), isEmpty);
  });
}
