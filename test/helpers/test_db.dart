import 'package:ai_assistant/data/db/app_database.dart';
import 'package:drift/native.dart';

/// A fresh [AppDatabase] backed by an in-memory SQLite (real sqlite3, pure Dart — no device).
///
/// The database's `beforeOpen` still runs `PRAGMA foreign_keys = ON`, so cascade behavior
/// (FR-022) is exercised exactly as on-device. Close it in `tearDown`.
AppDatabase newTestDatabase() => AppDatabase(NativeDatabase.memory());
