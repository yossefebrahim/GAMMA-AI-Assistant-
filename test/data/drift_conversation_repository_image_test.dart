import 'dart:io';

import 'package:ai_assistant/data/db/app_database.dart';
import 'package:ai_assistant/data/images/image_file_store.dart';
import 'package:ai_assistant/data/repositories/drift_conversation_repository.dart';
import 'package:ai_assistant/domain/entities/image_attachment.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_db.dart';

/// US5 repository image persistence + cleanup (FR-018/FR-019, SC-005) — REAL in-memory drift plus a
/// temp-dir [ImageFileStore]. Persist a user message with an image, read it back with `image`
/// populated, then delete the conversation and assert the file is gone and rows cascade.
void main() {
  late AppDatabase db;
  late Directory imagesDir;
  late ImageFileStore store;
  late DriftConversationRepository repo;

  /// A temp picker file to "persist" into the store.
  late File pickerTemp;

  setUp(() {
    db = newTestDatabase();
    imagesDir = Directory.systemTemp.createTempSync('repo_img_docs_');
    store = ImageFileStore(documentsDirectory: () async => imagesDir);
    repo = DriftConversationRepository(db, store);
    pickerTemp = File('${imagesDir.path}/picked.jpg')..writeAsBytesSync([1, 2, 3, 4]);
  });

  tearDown(() async {
    await db.close();
    if (imagesDir.existsSync()) imagesDir.deleteSync(recursive: true);
  });

  test('persists a message with an image and reads it back with the image populated '
      '(FR-018, SC-005)', () async {
    final conversation = await repo.createConversation();
    final storedPath = await store.persist(pickerTemp.path);

    await repo.appendUserMessage(
      conversation.id,
      'what is this',
      image: ImageAttachment(path: storedPath, mimeType: 'image/jpeg'),
    );

    final turns = await repo.loadTurns(conversation.id);
    final user = turns.single;
    expect(user.image, isNotNull);
    expect(user.image!.path, storedPath);
    expect(user.image!.mimeType, 'image/jpeg');
    expect(File(storedPath).existsSync(), isTrue);
  });

  test('an image-only first message derives the fallback title (FR-021)', () async {
    final conversation = await repo.createConversation();
    final storedPath = await store.persist(pickerTemp.path);

    await repo.appendUserMessage(
      conversation.id,
      '',
      image: ImageAttachment(path: storedPath),
    );

    final conversations = await repo.watchConversations().first;
    expect(conversations.single.title, DriftConversationRepository.imageOnlyTitle);
  });

  test('appendUserMessage rejects an empty message with no image (FR-004)', () async {
    final conversation = await repo.createConversation();
    expect(
      () => repo.appendUserMessage(conversation.id, '   '),
      throwsA(isA<ArgumentError>()),
    );
  });

  test('deleteConversation deletes the image files and cascades the rows (FR-019)', () async {
    final conversation = await repo.createConversation();
    final storedPath = await store.persist(pickerTemp.path);
    await repo.appendUserMessage(
      conversation.id,
      'look',
      image: ImageAttachment(path: storedPath),
    );
    expect(File(storedPath).existsSync(), isTrue);

    await repo.deleteConversation(conversation.id);

    expect(File(storedPath).existsSync(), isFalse, reason: 'image file removed (FR-019)');
    expect(await db.select(db.messages).get(), isEmpty, reason: 'messages cascade');
    expect(await repo.loadTurns(conversation.id), isEmpty);
  });
}
