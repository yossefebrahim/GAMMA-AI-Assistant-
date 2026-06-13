import 'dart:io';

import 'package:ai_assistant/data/db/app_database.dart';
import 'package:ai_assistant/domain/entities/memory.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

/// 006 schema migration (data-model §5) — a shipped v5 database (005) upgrades to v6 with its
/// data intact (text + tool + memory rows), the new `web_access_override` nullable column added to
/// `conversations` (defaulting to NULL = inherit), and `web_access_enabled` added to
/// `app_settings_table` (defaulting to false = off by default). The v5 seed is a REAL file DB
/// built with raw SQL at `user_version = 5` **including all five tables, the tool columns, the
/// `idx_messages_conversation` index, the `memories` table with its `idx_memories_active` index,
/// and `app_settings_table.memory_enabled`** (the seed mirrors the schema drift actually created
/// at v5). No `@TableIndex` is created for `web_access_override` (data-model §2).
void main() {
  late Directory tempDir;
  late File dbFile;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('mig_v5_v6_');
    dbFile = File('${tempDir.path}/app.sqlite');
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  /// The 005 v5 schema, faithfully: conversations + messages (with image/audio/tool columns) +
  /// model_installs + app_settings_table (with memory_enabled) + memories (with its active index).
  /// Does NOT include web_access_override or web_access_enabled — those are added by v5→v6.
  void seedV5() {
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
      CREATE TABLE model_installs (
        id TEXT NOT NULL PRIMARY KEY,
        state TEXT NOT NULL,
        file_path TEXT NULL,
        size_bytes INTEGER NULL,
        installed_at TEXT NULL
      );
      CREATE TABLE app_settings_table (
        id INTEGER NOT NULL PRIMARY KEY,
        theme_mode TEXT NOT NULL,
        license_acknowledged_at TEXT NULL,
        memory_enabled INTEGER NOT NULL DEFAULT 1
      );
      CREATE TABLE memories (
        id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
        fact TEXT NOT NULL,
        category TEXT NOT NULL,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        active INTEGER NOT NULL DEFAULT 1,
        source_conversation_id INTEGER NULL REFERENCES conversations (id) ON DELETE SET NULL
      );
      CREATE INDEX idx_memories_active ON memories (active, category, updated_at);
    ''');
    raw.execute('''
      INSERT INTO conversations (id, title, created_at, updated_at)
      VALUES (1, 'v5 chat', '2026-06-11T00:00:00.000Z', '2026-06-11T00:00:00.000Z');
    ''');
    raw.execute('''
      INSERT INTO messages
        (id, conversation_id, role, content, sequence, created_at, status,
         image_path, image_mime_type, audio_path, audio_mime_type,
         tool_name, tool_args, tool_status, tool_result)
      VALUES
        (1, 1, 'user', 'hello from v5', 0, '2026-06-11T00:00:00.000Z', 'complete',
         NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL),
        (2, 1, 'tool', 'battery 90%', 1, '2026-06-11T00:01:00.000Z', 'complete',
         NULL, NULL, NULL, NULL,
         'get_device_info', '{"section":"battery"}', 'success', '{"battery":90}');
    ''');
    raw.execute('''
      INSERT INTO app_settings_table (id, theme_mode, license_acknowledged_at, memory_enabled)
      VALUES (1, 'dark', NULL, 1);
    ''');
    raw.execute('''
      INSERT INTO memories (id, fact, category, created_at, updated_at, active, source_conversation_id)
      VALUES
        (1, 'name is Alice', 'identity', '2026-06-11T00:00:00.000Z', '2026-06-11T00:00:00.000Z', 1, 1),
        (2, 'prefers dark mode', 'preferences', '2026-06-11T00:00:00.000Z', '2026-06-11T00:00:00.000Z', 1, NULL);
    ''');
    raw.execute('PRAGMA user_version = 5;');
    raw.close();
  }

  test('v5 → v6 adds web_access_override + web_access_enabled; v5 rows survive unchanged '
      '(data-model §5, FR-030)', () async {
    seedV5();

    // Open at v6 → drift runs onUpgrade(5, 6): only the `from < 6` block fires.
    final db = AppDatabase(NativeDatabase(dbFile));
    addTearDown(db.close);

    // (1) Existing conversation rows have web_access_override = null (inherit).
    final conversations = await db.select(db.conversations).get();
    expect(conversations, hasLength(1));
    expect(conversations.single.title, 'v5 chat');
    expect(
      conversations.single.webAccessOverride,
      isNull,
      reason: 'existing rows default to NULL (= inherit global setting)',
    );

    // (2) App settings row survives with web_access_enabled = false (off by default — SC-001).
    final settings = await db.select(db.appSettingsTable).getSingle();
    expect(
      settings.webAccessEnabled,
      isFalse,
      reason: 'the v5→v6 migration defaults the existing row to web access off',
    );
    // memory_enabled is untouched.
    expect(
      settings.memoryEnabled,
      isTrue,
      reason: 'memory_enabled is untouched by the v5→v6 migration',
    );

    // (3) Memories rows survive untouched.
    final mems = await db.select(db.memories).get();
    expect(mems, hasLength(2));
    expect(
      mems.map((m) => m.fact),
      containsAll(['name is Alice', 'prefers dark mode']),
    );

    // (7) Schema version is 6.
    expect(db.schemaVersion, 6);
  });

  test(
    '(4) new conversation row with web_access_override = "on" round-trips correctly',
    () async {
      seedV5();
      final db = AppDatabase(NativeDatabase(dbFile));
      addTearDown(db.close);

      final id = await db
          .into(db.conversations)
          .insert(
            ConversationsCompanion.insert(
              createdAt: DateTime.utc(2026, 6, 11, 1),
              updatedAt: DateTime.utc(2026, 6, 11, 1),
              webAccessOverride: const Value('on'),
            ),
          );

      final row = await (db.select(
        db.conversations,
      )..where((c) => c.id.equals(id))).getSingle();
      expect(row.webAccessOverride, 'on');
    },
  );

  test(
    '(5) web_access_override = null round-trips as null (inherit case)',
    () async {
      seedV5();
      final db = AppDatabase(NativeDatabase(dbFile));
      addTearDown(db.close);

      final id = await db
          .into(db.conversations)
          .insert(
            ConversationsCompanion.insert(
              createdAt: DateTime.utc(2026, 6, 11, 2),
              updatedAt: DateTime.utc(2026, 6, 11, 2),
              // webAccessOverride absent → Value.absent() → NULL
            ),
          );

      final row = await (db.select(
        db.conversations,
      )..where((c) => c.id.equals(id))).getSingle();
      expect(
        row.webAccessOverride,
        isNull,
        reason: 'absent webAccessOverride is stored as NULL (= inherit)',
      );
    },
  );

  test(
    '(6) setting web_access_enabled = true on app_settings persists and reads back',
    () async {
      seedV5();
      final db = AppDatabase(NativeDatabase(dbFile));
      addTearDown(db.close);

      await (db.update(
        db.appSettingsTable,
      )..where((s) => s.id.equals(1))).write(
        const AppSettingsTableCompanion(webAccessEnabled: Value(true)),
      );

      final settings = await db.select(db.appSettingsTable).getSingle();
      expect(
        settings.webAccessEnabled,
        isTrue,
        reason: 'web_access_enabled=true persists and reads back correctly',
      );
    },
  );

  test(
    'memories and messages survive the migration completely untouched',
    () async {
      seedV5();
      final db = AppDatabase(NativeDatabase(dbFile));
      addTearDown(db.close);

      final messages = await db.select(db.messages).get();
      expect(messages, hasLength(2));
      final tool = messages.firstWhere((m) => m.id == 2);
      expect(tool.role, 'tool');
      expect(tool.toolName, 'get_device_info');
      expect(tool.toolResult, '{"battery":90}');

      final mems = await db.select(db.memories).get();
      expect(mems.firstWhere((m) => m.id == 1).fact, 'name is Alice');
      expect(mems.firstWhere((m) => m.id == 1).active, isTrue);
      expect(mems.firstWhere((m) => m.id == 2).sourceConversationId, isNull);
    },
  );

  test(
    'idx_memories_active and idx_messages_conversation survive the upgrade',
    () async {
      seedV5();
      final db = AppDatabase(NativeDatabase(dbFile));
      addTearDown(db.close);
      await db.select(db.memories).get(); // ensure open + migrate
      final indexes = await db
          .customSelect("SELECT name FROM sqlite_master WHERE type = 'index'")
          .get();
      final names = indexes.map((r) => r.data['name'] as String).toList();
      expect(names, contains('idx_memories_active'));
      expect(names, contains('idx_messages_conversation'));
    },
  );

  test(
    'fresh installs land on v6 directly with web_access_override + web_access_enabled (onCreate round-trip)',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);

      // Insert app settings on fresh install.
      await db
          .into(db.appSettingsTable)
          .insert(
            AppSettingsTableCompanion.insert(
              id: const Value(1),
              themeMode: 'dark',
            ),
          );
      final settings = await db.select(db.appSettingsTable).getSingle();
      expect(settings.webAccessEnabled, isFalse);
      expect(settings.memoryEnabled, isTrue);

      // Insert a conversation with web_access_override = 'off'.
      final convId = await db
          .into(db.conversations)
          .insert(
            ConversationsCompanion.insert(
              createdAt: DateTime.utc(2026, 6, 11),
              updatedAt: DateTime.utc(2026, 6, 11),
              webAccessOverride: const Value('off'),
            ),
          );
      final conv = await (db.select(
        db.conversations,
      )..where((c) => c.id.equals(convId))).getSingle();
      expect(conv.webAccessOverride, 'off');

      // Memories still insertable on fresh v6 schema.
      final memId = await db
          .into(db.memories)
          .insert(
            MemoriesCompanion.insert(
              fact: 'works remotely',
              category: MemoryCategory.work.name,
              createdAt: DateTime.utc(2026, 6, 11),
              updatedAt: DateTime.utc(2026, 6, 11),
            ),
          );
      final mem = (await db.select(db.memories).get()).single;
      expect(mem.id, memId);
      expect(mem.fact, 'works remotely');
    },
  );
}
