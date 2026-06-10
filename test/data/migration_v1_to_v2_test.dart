import 'dart:io';

import 'package:ai_assistant/data/db/app_database.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

/// US5 schema migration (R5, FR-017) — a shipped v1 database upgrades to v2 with its data intact
/// and the new nullable image columns added (defaulting to null). Seeds a real v1 schema by hand
/// (no image columns, `user_version = 1`), then opens the app database at v2 to drive `onUpgrade`.
void main() {
  late Directory tempDir;
  late File dbFile;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('mig_v1_v2_');
    dbFile = File('${tempDir.path}/app.sqlite');
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('v1 → v2 adds nullable image columns and preserves existing rows (R5, FR-017)', () async {
    // --- Seed a v1 database (the 001 schema — messages has NO image columns). ---
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
        status TEXT NOT NULL
      );
    ''');
    raw.execute('''
      INSERT INTO conversations (id, title, created_at, updated_at)
      VALUES (1, 'old chat', '2026-06-01T00:00:00.000Z', '2026-06-01T00:00:00.000Z');
    ''');
    raw.execute('''
      INSERT INTO messages (id, conversation_id, role, content, sequence, created_at, status)
      VALUES (1, 1, 'user', 'hello from v1', 0, '2026-06-01T00:00:00.000Z', 'complete');
    ''');
    raw.execute('PRAGMA user_version = 1;');
    raw.close();

    // --- Open at the current schema → drift runs onUpgrade(1, …), through the v2 block (and on
    // through v3's audio block, 003). ---
    final db = AppDatabase(NativeDatabase(dbFile));
    addTearDown(db.close);

    // The new columns exist and old rows survive with them defaulting to null (FR-017).
    final messages = await db.select(db.messages).get();
    expect(messages, hasLength(1));
    expect(messages.single.content, 'hello from v1');
    expect(messages.single.imagePath, isNull);
    expect(messages.single.imageMimeType, isNull);
    expect(messages.single.audioPath, isNull, reason: 'v3 audio columns land too (003)');
    expect(messages.single.audioMimeType, isNull);

    // The conversation survived the upgrade.
    final conversations = await db.select(db.conversations).get();
    expect(conversations.single.title, 'old chat');

    expect(db.schemaVersion, 3);
  });

  test('fresh installs are created with the image columns (onCreate)', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);

    // A round-trip through the new columns proves they exist on a fresh schema.
    final convId = await db.into(db.conversations).insert(
          ConversationsCompanion.insert(
            createdAt: DateTime.utc(2026, 6, 8),
            updatedAt: DateTime.utc(2026, 6, 8),
          ),
        );
    await db.into(db.messages).insert(
          MessagesCompanion.insert(
            conversationId: convId,
            role: 'user',
            content: '',
            sequence: 0,
            createdAt: DateTime.utc(2026, 6, 8),
            status: 'complete',
            imagePath: const Value('/images/x.jpg'),
            imageMimeType: const Value('image/jpeg'),
          ),
        );

    final row = (await db.select(db.messages).get()).single;
    expect(row.imagePath, '/images/x.jpg');
    expect(row.imageMimeType, 'image/jpeg');
  });
}
