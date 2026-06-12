import 'dart:io';

import 'package:ai_assistant/data/db/app_database.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

/// US5 schema migration (003 R6, FR-019) — a shipped v2 database (002) upgrades to v3 with its
/// data intact (including image rows) and the new nullable audio columns added (defaulting to
/// NULL). The v2 seed is a REAL file DB built with raw SQL at `user_version = 2` **including the
/// `idx_messages_conversation` index** (002 audit I7 — the seed mirrors the schema drift actually
/// created, not a convenient subset), and foreign keys stay enforced after the upgrade.
void main() {
  late Directory tempDir;
  late File dbFile;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('mig_v2_v3_');
    dbFile = File('${tempDir.path}/app.sqlite');
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  /// The 002 v2 schema, faithfully: image columns present, audio columns absent, the
  /// conversation/sequence index in place (I7).
  void seedV2() {
    final raw = sqlite3.open(dbFile.path);
    raw.execute('''
      CREATE TABLE conversations (
        id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
        title TEXT NULL,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      );
      CREATE TABLE messages (
        id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
        conversation_id INTEGER NOT NULL REFERENCES conversations (id) ON DELETE CASCADE,
        role TEXT NOT NULL,
        content TEXT NOT NULL,
        sequence INTEGER NOT NULL,
        created_at TEXT NOT NULL,
        status TEXT NOT NULL,
        image_path TEXT NULL,
        image_mime_type TEXT NULL
      );
      CREATE INDEX idx_messages_conversation ON messages (conversation_id, sequence);
      CREATE TABLE app_settings_table (
        id INTEGER NOT NULL PRIMARY KEY,
        theme_mode TEXT NOT NULL,
        license_acknowledged_at TEXT NULL
      );
    ''');
    raw.execute('''
      INSERT INTO conversations (id, title, created_at, updated_at)
      VALUES (1, 'v2 chat', '2026-06-09T00:00:00.000Z', '2026-06-09T00:00:00.000Z');
    ''');
    raw.execute('''
      INSERT INTO messages
        (id, conversation_id, role, content, sequence, created_at, status, image_path, image_mime_type)
      VALUES
        (1, 1, 'user', 'hello from v2', 0, '2026-06-09T00:00:00.000Z', 'complete', NULL, NULL),
        (2, 1, 'user', 'look at this', 1, '2026-06-09T00:01:00.000Z', 'complete',
         '/images/pic.jpg', 'image/jpeg'),
        (3, 1, 'assistant', 'a cat', 2, '2026-06-09T00:02:00.000Z', 'complete', NULL, NULL);
    ''');
    raw.execute('PRAGMA user_version = 2;');
    raw.close();
  }

  test(
    'v2 → v3 adds nullable audio columns; v2 rows (incl. images) survive unchanged '
    '(R6, FR-019)',
    () async {
      seedV2();

      // Open at the current schema → drift runs onUpgrade(2, 5): the audio (v3), tool (v4), and
      // memory (v5) blocks fire.
      final db = AppDatabase(NativeDatabase(dbFile));
      addTearDown(db.close);

      final messages = await db.select(db.messages).get();
      expect(messages, hasLength(3));

      final text = messages.firstWhere((m) => m.id == 1);
      expect(text.content, 'hello from v2');
      expect(
        text.audioPath,
        isNull,
        reason: 'new columns default to NULL for v2 rows',
      );
      expect(text.audioMimeType, isNull);

      final image = messages.firstWhere((m) => m.id == 2);
      expect(
        image.imagePath,
        '/images/pic.jpg',
        reason: 'v2 image data survives untouched',
      );
      expect(image.imageMimeType, 'image/jpeg');
      expect(image.audioPath, isNull);

      final conversations = await db.select(db.conversations).get();
      expect(conversations.single.title, 'v2 chat');
      expect(db.schemaVersion, 5);
    },
  );

  test('foreign keys stay enforced after the upgrade (cascade intact)', () async {
    seedV2();
    final db = AppDatabase(NativeDatabase(dbFile));
    addTearDown(db.close);

    // Deleting the conversation cascades its messages (PRAGMA foreign_keys = ON in beforeOpen).
    await (db.delete(db.conversations)..where((c) => c.id.equals(1))).go();
    expect(await db.select(db.messages).get(), isEmpty);
  });

  test('a new audio row round-trips through the upgraded schema', () async {
    seedV2();
    final db = AppDatabase(NativeDatabase(dbFile));
    addTearDown(db.close);

    await db
        .into(db.messages)
        .insert(
          MessagesCompanion.insert(
            conversationId: 1,
            role: 'user',
            content: '',
            sequence: 3,
            createdAt: DateTime.utc(2026, 6, 10),
            status: 'complete',
            audioPath: const Value('/audio/clip.wav'),
            audioMimeType: const Value('audio/wav'),
          ),
        );

    final row = (await db.select(db.messages).get()).firstWhere(
      (m) => m.sequence == 3,
    );
    expect(row.audioPath, '/audio/clip.wav');
    expect(row.audioMimeType, 'audio/wav');
  });

  test(
    'fresh installs land on v3 directly with the audio columns (onCreate round-trip)',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);

      final convId = await db
          .into(db.conversations)
          .insert(
            ConversationsCompanion.insert(
              createdAt: DateTime.utc(2026, 6, 10),
              updatedAt: DateTime.utc(2026, 6, 10),
            ),
          );
      await db
          .into(db.messages)
          .insert(
            MessagesCompanion.insert(
              conversationId: convId,
              role: 'user',
              content: '',
              sequence: 0,
              createdAt: DateTime.utc(2026, 6, 10),
              status: 'complete',
              audioPath: const Value('/audio/x.wav'),
              audioMimeType: const Value('audio/wav'),
            ),
          );

      final row = (await db.select(db.messages).get()).single;
      expect(row.audioPath, '/audio/x.wav');
      expect(row.audioMimeType, 'audio/wav');
    },
  );
}
