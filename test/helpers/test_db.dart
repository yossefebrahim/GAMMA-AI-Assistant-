import 'package:ai_assistant/data/db/app_database.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';

/// A fresh [AppDatabase] backed by an in-memory SQLite (real sqlite3, pure Dart — no device).
///
/// The database's `beforeOpen` still runs `PRAGMA foreign_keys = ON`, so cascade behavior
/// (FR-022) is exercised exactly as on-device. Close it in `tearDown`.
AppDatabase newTestDatabase() {
  // Each test spins up its own isolated in-memory DB; silence drift's "multiple databases" warning
  // (it guards against shared executors, which these are not).
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  return AppDatabase(NativeDatabase.memory());
}
