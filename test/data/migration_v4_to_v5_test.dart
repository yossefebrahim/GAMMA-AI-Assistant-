import 'dart:io';

import 'package:ai_assistant/data/db/app_database.dart';
import 'package:ai_assistant/domain/entities/memory.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

/// 005 schema migration (R7, data-model §2) — a shipped v4 database (004) upgrades to v5 with its
/// data intact (text + tool rows), the new `memories` table + its `(active, category, updated_at)`
/// index created, and `app_settings_table.memory_enabled` added defaulting to true. The v4 seed is
/// a REAL file DB built with raw SQL at `user_version = 4` **including the four tool columns and the
/// `idx_messages_conversation` index** (the seed mirrors the schema drift actually created), and the
/// `memories` FK uses `ON DELETE SET NULL` so facts outlive the conversation they were captured in
/// (the durable-fact guarantee, Clarifications Q1 — contrast with messages, which cascade).
void main() {
  late Directory tempDir;
  late File dbFile;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('mig_v4_v5_');
    dbFile = File('${tempDir.path}/app.sqlite');
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  /// The 004 v4 schema, faithfully: messages with the image/audio/tool columns + the
  /// conversation/sequence index, and the single-row `app_settings_table` WITHOUT `memory_enabled`.
  void seedV4() {
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
        audio_mime_type TEXT NULL,
        tool_name TEXT NULL,
        tool_args TEXT NULL,
        tool_status TEXT NULL,
        tool_result TEXT NULL
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
      VALUES (1, 'v4 chat', '2026-06-10T00:00:00.000Z', '2026-06-10T00:00:00.000Z');
    ''');
    raw.execute('''
      INSERT INTO messages
        (id, conversation_id, role, content, sequence, created_at, status,
         image_path, image_mime_type, audio_path, audio_mime_type,
         tool_name, tool_args, tool_status, tool_result)
      VALUES
        (1, 1, 'user', 'hello from v4', 0, '2026-06-10T00:00:00.000Z', 'complete',
         NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL),
        (2, 1, 'tool', 'battery 83%', 1, '2026-06-10T00:01:00.000Z', 'complete',
         NULL, NULL, NULL, NULL,
         'get_device_info', '{"section":"battery"}', 'success', '{"battery":83}');
    ''');
    raw.execute('''
      INSERT INTO app_settings_table (id, theme_mode, license_acknowledged_at)
      VALUES (1, 'dark', NULL);
    ''');
    raw.execute('PRAGMA user_version = 4;');
    raw.close();
  }

  test('v4 → v5 adds memories + memory_enabled; v4 rows (incl. tool rows) survive unchanged '
      '(R7, data-model §2)', () async {
    seedV4();

    // Open at v5 → drift runs onUpgrade(4, 5): only the `from < 5` block fires.
    final db = AppDatabase(NativeDatabase(dbFile));
    addTearDown(db.close);

    final messages = await db.select(db.messages).get();
    expect(messages, hasLength(2));

    final text = messages.firstWhere((m) => m.id == 1);
    expect(
      text.content,
      'hello from v4',
      reason: 'v4 text rows survive untouched',
    );

    final tool = messages.firstWhere((m) => m.id == 2);
    expect(tool.role, 'tool', reason: 'v4 tool rows survive untouched');
    expect(tool.toolName, 'get_device_info');
    expect(tool.toolResult, '{"battery":83}');

    expect((await db.select(db.conversations).get()).single.title, 'v4 chat');

    // The existing single app_settings row gets memory_enabled defaulted true (Clarifications Q3).
    final settings = await db.select(db.appSettingsTable).getSingle();
    expect(
      settings.memoryEnabled,
      isTrue,
      reason: 'the v4→v5 migration defaults the existing row to memory on',
    );

    expect(db.schemaVersion, 5);
  });

  test(
    'a memory row round-trips through the upgraded schema (active defaults true)',
    () async {
      seedV4();
      final db = AppDatabase(NativeDatabase(dbFile));
      addTearDown(db.close);

      final id = await db
          .into(db.memories)
          .insert(
            MemoriesCompanion.insert(
              fact: 'name is Joe',
              category: MemoryCategory.identity.name,
              createdAt: DateTime.utc(2026, 6, 10),
              updatedAt: DateTime.utc(2026, 6, 10),
            ),
          );

      final row = await (db.select(
        db.memories,
      )..where((m) => m.id.equals(id))).getSingle();
      expect(row.fact, 'name is Joe');
      expect(row.category, 'identity');
      expect(row.active, isTrue, reason: 'active defaults to true');
      expect(
        row.sourceConversationId,
        isNull,
        reason: 'manual fact has no provenance',
      );
    },
  );

  test(
    'ON DELETE SET NULL: deleting a conversation keeps the fact but nulls provenance '
    '(durable, NOT cascade — data-model §2)',
    () async {
      seedV4();
      final db = AppDatabase(NativeDatabase(dbFile));
      addTearDown(db.close);

      final memId = await db
          .into(db.memories)
          .insert(
            MemoriesCompanion.insert(
              fact: 'lives in Cairo',
              category: MemoryCategory.identity.name,
              createdAt: DateTime.utc(2026, 6, 10),
              updatedAt: DateTime.utc(2026, 6, 10),
              sourceConversationId: const Value(1),
            ),
          );

      // Deleting conversation 1 cascades its messages away but must SET NULL the fact's provenance.
      await (db.delete(db.conversations)..where((c) => c.id.equals(1))).go();

      expect(
        await db.select(db.messages).get(),
        isEmpty,
        reason: 'messages cascade-delete with their conversation',
      );

      final mem = await (db.select(
        db.memories,
      )..where((m) => m.id.equals(memId))).getSingle();
      expect(
        mem.fact,
        'lives in Cairo',
        reason: 'the durable fact outlives its source conversation',
      );
      expect(
        mem.sourceConversationId,
        isNull,
        reason: 'provenance is nulled, not cascaded',
      );
    },
  );

  test('idx_memories_active is created by the upgrade', () async {
    seedV4();
    final db = AppDatabase(NativeDatabase(dbFile));
    addTearDown(db.close);
    await db.select(db.memories).get(); // touch → open + migrate
    final indexes = await db
        .customSelect("SELECT name FROM sqlite_master WHERE type = 'index'")
        .get();
    final names = indexes.map((r) => r.data['name'] as String).toList();
    expect(names, contains('idx_memories_active'));
    expect(
      names,
      contains('idx_messages_conversation'),
      reason: 'the pre-existing index is untouched',
    );
  });

  test(
    'fresh installs land on v5 directly with memories + memory_enabled (onCreate round-trip)',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);

      // memory_enabled default applies on a fresh insert too.
      await db
          .into(db.appSettingsTable)
          .insert(
            AppSettingsTableCompanion.insert(
              id: const Value(1),
              themeMode: 'dark',
            ),
          );
      final settings = await db.select(db.appSettingsTable).getSingle();
      expect(settings.memoryEnabled, isTrue);

      final id = await db
          .into(db.memories)
          .insert(
            MemoriesCompanion.insert(
              fact: 'prefers dark mode',
              category: MemoryCategory.preferences.name,
              createdAt: DateTime.utc(2026, 6, 10),
              updatedAt: DateTime.utc(2026, 6, 10),
            ),
          );
      final row = (await db.select(db.memories).get()).single;
      expect(row.id, id);
      expect(row.category, 'preferences');
    },
  );
}
