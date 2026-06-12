import 'dart:io';

import 'package:ai_assistant/data/db/app_database.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

/// 004 schema migration (R7, FR-013/FR-019) — a shipped v3 database (003) upgrades to v4 with its
/// data intact (text, image AND audio rows) and the four new nullable tool columns added
/// (defaulting to NULL). The v3 seed is a REAL file DB built with raw SQL at `user_version = 3`
/// **including the `idx_messages_conversation` index** (002 audit I7 — the seed mirrors the schema
/// drift actually created), and foreign keys stay enforced after the upgrade.
void main() {
  late Directory tempDir;
  late File dbFile;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('mig_v3_v4_');
    dbFile = File('${tempDir.path}/app.sqlite');
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  /// The 003 v3 schema, faithfully: image + audio columns present, tool columns absent, the
  /// conversation/sequence index in place (I7).
  void seedV3() {
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
        image_mime_type TEXT NULL,
        audio_path TEXT NULL,
        audio_mime_type TEXT NULL
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
      VALUES (1, 'v3 chat', '2026-06-09T00:00:00.000Z', '2026-06-09T00:00:00.000Z');
    ''');
    raw.execute('''
      INSERT INTO messages
        (id, conversation_id, role, content, sequence, created_at, status,
         image_path, image_mime_type, audio_path, audio_mime_type)
      VALUES
        (1, 1, 'user', 'hello from v3', 0, '2026-06-09T00:00:00.000Z', 'complete',
         NULL, NULL, NULL, NULL),
        (2, 1, 'user', 'look', 1, '2026-06-09T00:01:00.000Z', 'complete',
         '/images/pic.jpg', 'image/jpeg', NULL, NULL),
        (3, 1, 'user', '', 2, '2026-06-09T00:02:00.000Z', 'complete',
         NULL, NULL, '/audio/clip.wav', 'audio/wav'),
        (4, 1, 'assistant', 'a cat', 3, '2026-06-09T00:03:00.000Z', 'complete',
         NULL, NULL, NULL, NULL);
    ''');
    raw.execute('PRAGMA user_version = 3;');
    raw.close();
  }

  test(
    'v3 → v4 adds nullable tool columns; v3 rows survive unchanged with NULL tool fields '
    '(R7, FR-019)',
    () async {
      seedV3();

      // Open at the current schema → drift runs onUpgrade(3, 5): the tool (v4) and memory (v5)
      // blocks fire.
      final db = AppDatabase(NativeDatabase(dbFile));
      addTearDown(db.close);

      final messages = await db.select(db.messages).get();
      expect(messages, hasLength(4));

      final text = messages.firstWhere((m) => m.id == 1);
      expect(text.content, 'hello from v3');
      expect(
        text.toolName,
        isNull,
        reason: 'new tool columns default to NULL for v3 rows',
      );
      expect(text.toolArgs, isNull);
      expect(text.toolStatus, isNull);
      expect(text.toolResult, isNull);

      final image = messages.firstWhere((m) => m.id == 2);
      expect(
        image.imagePath,
        '/images/pic.jpg',
        reason: 'v3 image data survives untouched',
      );
      final audio = messages.firstWhere((m) => m.id == 3);
      expect(
        audio.audioPath,
        '/audio/clip.wav',
        reason: 'v3 audio data survives untouched',
      );

      expect((await db.select(db.conversations).get()).single.title, 'v3 chat');
      expect(db.schemaVersion, 5);
    },
  );

  test('the conversation/sequence index survives the upgrade', () async {
    seedV3();
    final db = AppDatabase(NativeDatabase(dbFile));
    addTearDown(db.close);
    // Touch the DB so it opens + migrates, then inspect the index list via a raw query.
    await db.select(db.messages).get();
    final indexes = await db
        .customSelect("SELECT name FROM sqlite_master WHERE type = 'index'")
        .get();
    final names = indexes.map((r) => r.data['name'] as String).toList();
    expect(names, contains('idx_messages_conversation'));
  });

  test(
    'foreign keys stay enforced after the upgrade (cascade intact)',
    () async {
      seedV3();
      final db = AppDatabase(NativeDatabase(dbFile));
      addTearDown(db.close);
      await (db.delete(db.conversations)..where((c) => c.id.equals(1))).go();
      expect(await db.select(db.messages).get(), isEmpty);
    },
  );

  test('a new tool row round-trips through the upgraded schema', () async {
    seedV3();
    final db = AppDatabase(NativeDatabase(dbFile));
    addTearDown(db.close);

    await db
        .into(db.messages)
        .insert(
          MessagesCompanion.insert(
            conversationId: 1,
            role: 'tool',
            content: 'battery 83%',
            sequence: 4,
            createdAt: DateTime.utc(2026, 6, 10),
            status: 'complete',
            toolName: const Value('get_device_info'),
            toolArgs: const Value('{"section":"battery"}'),
            toolStatus: const Value('success'),
            toolResult: const Value('{"battery":83}'),
          ),
        );

    final row = (await db.select(db.messages).get()).firstWhere(
      (m) => m.sequence == 4,
    );
    expect(row.role, 'tool');
    expect(row.toolName, 'get_device_info');
    expect(row.toolArgs, '{"section":"battery"}');
    expect(row.toolStatus, 'success');
    expect(row.toolResult, '{"battery":83}');
  });

  test(
    'fresh installs land on v4 directly with the tool columns (onCreate round-trip)',
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
              role: 'tool',
              content: 'light theme on',
              sequence: 0,
              createdAt: DateTime.utc(2026, 6, 10),
              status: 'complete',
              toolName: const Value('set_theme'),
              toolArgs: const Value('{"theme":"light"}'),
              toolStatus: const Value('success'),
              toolResult: const Value(
                '{"theme":"light","alreadyActive":false}',
              ),
            ),
          );

      final row = (await db.select(db.messages).get()).single;
      expect(row.toolName, 'set_theme');
      expect(row.toolStatus, 'success');
    },
  );
}
