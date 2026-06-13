import 'package:ai_assistant/data/db/app_database.dart';
import 'package:ai_assistant/domain/entities/app_settings.dart';
import 'package:drift/drift.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Reads/writes the single-row app settings (FR-023/FR-024 theme; clarification Q1 license ack).
/// Pure data access — the row is created lazily with [AppSettings.defaults] (dark theme).
class SettingsRepository {
  SettingsRepository(this._db);

  final AppDatabase _db;

  /// The settings table holds exactly one row.
  static const int _rowId = 1;

  AppSettings _toSettings(AppSettingsRow row) => AppSettings(
    themeMode: AppThemeMode.values.byName(row.themeMode),
    licenseAcknowledgedAt: row.licenseAcknowledgedAt,
    memoryEnabled: row.memoryEnabled,
    webAccessEnabled: row.webAccessEnabled,
  );

  Future<void> _ensureRow() async {
    await _db
        .into(_db.appSettingsTable)
        .insert(
          AppSettingsTableCompanion.insert(
            id: const Value(_rowId),
            themeMode: AppThemeMode.dark.name,
          ),
          mode: InsertMode.insertOrIgnore,
        );
  }

  /// Read current settings, lazily creating the default row if absent.
  Future<AppSettings> read() async {
    final row = await (_db.select(
      _db.appSettingsTable,
    )..where((t) => t.id.equals(_rowId))).getSingleOrNull();
    if (row == null) {
      await _ensureRow();
      return AppSettings.defaults;
    }
    return _toSettings(row);
  }

  /// Reactive settings — emits on every change (drift `.watch`).
  Stream<AppSettings> watch() {
    return (_db.select(_db.appSettingsTable)..where((t) => t.id.equals(_rowId)))
        .watchSingleOrNull()
        .map((row) => row == null ? AppSettings.defaults : _toSettings(row));
  }

  /// Persist the theme preference (FR-024).
  Future<void> setThemeMode(AppThemeMode mode) async {
    await _ensureRow();
    await (_db.update(_db.appSettingsTable)..where((t) => t.id.equals(_rowId)))
        .write(AppSettingsTableCompanion(themeMode: Value(mode.name)));
  }

  /// Read just the memory-enabled flag (005). Lazily creates the default row if absent.
  Future<bool> readMemoryEnabled() async {
    final settings = await read();
    return settings.memoryEnabled;
  }

  /// Persist the memory-enabled preference (005, Clarifications Q3).
  Future<void> setMemoryEnabled(bool enabled) async {
    await _ensureRow();
    await (_db.update(_db.appSettingsTable)..where((t) => t.id.equals(_rowId)))
        .write(AppSettingsTableCompanion(memoryEnabled: Value(enabled)));
  }

  /// Read just the web-access-enabled flag (006). Lazily creates the default row if absent.
  Future<bool> readWebAccessEnabled() async {
    final settings = await read();
    return settings.webAccessEnabled;
  }

  /// Persist the web-access-enabled preference (006, FR-001).
  Future<void> setWebAccessEnabled(bool enabled) async {
    await _ensureRow();
    await (_db.update(_db.appSettingsTable)..where((t) => t.id.equals(_rowId)))
        .write(AppSettingsTableCompanion(webAccessEnabled: Value(enabled)));
  }

  /// Record the one-time model-license acknowledgment (clarification Q1).
  Future<void> acknowledgeLicense(DateTime at) async {
    await _ensureRow();
    await (_db.update(_db.appSettingsTable)..where((t) => t.id.equals(_rowId)))
        .write(AppSettingsTableCompanion(licenseAcknowledgedAt: Value(at)));
  }
}

/// Maps the domain theme mode to Material's [ThemeMode] for the app shell.
extension AppThemeModeX on AppThemeMode {
  ThemeMode get material => switch (this) {
    AppThemeMode.dark => ThemeMode.dark,
    AppThemeMode.light => ThemeMode.light,
    AppThemeMode.system => ThemeMode.system,
  };
}

final settingsRepositoryProvider = Provider<SettingsRepository>((ref) {
  return SettingsRepository(ref.watch(appDatabaseProvider));
});

/// Reactive stream of persisted settings.
final settingsStreamProvider = StreamProvider<AppSettings>((ref) {
  return ref.watch(settingsRepositoryProvider).watch();
});

/// The theme mode applied at the app root (FR-023 default dark; FR-024 persisted). Reflects the
/// persisted value reactively and exposes [ThemeModeController.set] to change + persist it.
class ThemeModeController extends Notifier<AppThemeMode> {
  @override
  AppThemeMode build() {
    final settings = ref.watch(settingsStreamProvider);
    return settings.maybeWhen(
      data: (value) => value.themeMode,
      orElse: () => AppThemeMode.dark,
    );
  }

  Future<void> set(AppThemeMode mode) async {
    state = mode; // optimistic; the persisted stream will re-confirm
    await ref.read(settingsRepositoryProvider).setThemeMode(mode);
  }
}

final themeModeProvider = NotifierProvider<ThemeModeController, AppThemeMode>(
  ThemeModeController.new,
);

/// Whether durable memory is enabled (005, Clarifications Q3 — default **true**). Reflects the
/// persisted value reactively and exposes [MemoryEnabledController.set] to change + persist it.
class MemoryEnabledController extends Notifier<bool> {
  @override
  bool build() {
    final settings = ref.watch(settingsStreamProvider);
    return settings.maybeWhen(
      data: (value) => value.memoryEnabled,
      orElse: () => true,
    );
  }

  Future<void> set(bool enabled) async {
    state = enabled; // optimistic; the persisted stream will re-confirm
    await ref.read(settingsRepositoryProvider).setMemoryEnabled(enabled);
  }
}

final memoryEnabledProvider = NotifierProvider<MemoryEnabledController, bool>(
  MemoryEnabledController.new,
);

/// Whether web research is globally enabled (006, Decision 1 — default **false**). Reflects the
/// persisted value reactively and exposes [WebAccessEnabledController.set] to change + persist it.
class WebAccessEnabledController extends Notifier<bool> {
  @override
  bool build() {
    final settings = ref.watch(settingsStreamProvider);
    return settings.maybeWhen(
      data: (value) => value.webAccessEnabled,
      orElse: () => false,
    );
  }

  Future<void> set(bool enabled) async {
    state = enabled; // optimistic; the persisted stream will re-confirm
    await ref.read(settingsRepositoryProvider).setWebAccessEnabled(enabled);
  }
}

final webAccessEnabledProvider =
    NotifierProvider<WebAccessEnabledController, bool>(
      WebAccessEnabledController.new,
    );
