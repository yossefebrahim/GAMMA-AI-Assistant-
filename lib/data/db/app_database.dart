import 'package:ai_assistant/data/db/tables.dart';
import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

part 'app_database.g.dart';
part 'daos/conversation_dao.dart';

/// The app-private drift/SQLite database (R3). Stored under app-private storage, which is
/// Credential-Encrypted by default on FBE devices — OS-level at-rest encryption, no app crypto
/// (FR-032 / clarification Q3). Pass an explicit [executor] (e.g. `NativeDatabase.memory()`) in
/// tests to run entirely off-device.
@DriftDatabase(
  tables: [Conversations, Messages, ModelInstalls, AppSettingsTable],
  daos: [ConversationDao],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase([QueryExecutor? executor]) : super(executor ?? _open());

  @override
  int get schemaVersion => 3;

  // Store DateTimes as ISO-8601 TEXT (UTC) instead of integer Unix *seconds* (drift's default).
  // This preserves sub-second precision so the history list orders correctly when conversations
  // are created/updated within the same second (FR-020), and keeps timezone information.
  @override
  DriftDatabaseOptions get options =>
      const DriftDatabaseOptions(storeDateTimeAsText: true);

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) => m.createAll(),
        onUpgrade: (m, from, to) async {
          // v1 → v2 (002): add the nullable image columns to `messages`. 001 has shipped, so
          // upgraders' existing rows must survive; the columns are nullable → old text
          // conversations stay valid with NULL (FR-017, R5). Fresh installs get v2 via onCreate.
          if (from < 2) {
            await m.addColumn(messages, messages.imagePath);
            await m.addColumn(messages, messages.imageMimeType);
          }
          // v2 → v3 (003): add the nullable audio columns (additive only; v2 rows untouched —
          // data-model.md §2). Fresh installs land on v3 directly via onCreate.
          if (from < 3) {
            await m.addColumn(messages, messages.audioPath);
            await m.addColumn(messages, messages.audioMimeType);
          }
        },
        beforeOpen: (details) async {
          // Required so the messages→conversations cascade actually fires (FR-022).
          await customStatement('PRAGMA foreign_keys = ON');
        },
      );

  static QueryExecutor _open() => driftDatabase(name: 'gemma_assistant');
}

/// Owns the single app database for the lifetime of the app; closed on dispose. Overridden in
/// tests with an in-memory database (see `test/helpers/test_db.dart`).
final appDatabaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase();
  ref.onDispose(db.close);
  return db;
});
