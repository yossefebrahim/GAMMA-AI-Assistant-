import 'package:ai_assistant/core/model_catalog.dart';
import 'package:ai_assistant/data/db/app_database.dart';
import 'package:ai_assistant/domain/entities/model_install.dart';
import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Persists the single `model_install` row (data-model.md): the install state machine, verified
/// file path, on-disk size, and install timestamp. The downloader owns the FILE; this owns the
/// RECORD. Routing (T029) and settings (FR-030) read it.
class ModelInstallRepository {
  ModelInstallRepository(this._db);

  final AppDatabase _db;

  ModelInstall _toEntity(ModelInstallRow row) => ModelInstall(
        id: row.id,
        state: ModelInstallState.values.byName(row.state),
        filePath: row.filePath,
        sizeBytes: row.sizeBytes,
        installedAt: row.installedAt,
      );

  Future<ModelInstall?> read() async {
    final row = await (_db.select(_db.modelInstalls)
          ..where((t) => t.id.equals(ModelCatalog.modelId)))
        .getSingleOrNull();
    return row == null ? null : _toEntity(row);
  }

  Stream<ModelInstall?> watch() {
    return (_db.select(_db.modelInstalls)..where((t) => t.id.equals(ModelCatalog.modelId)))
        .watchSingleOrNull()
        .map((row) => row == null ? null : _toEntity(row));
  }

  /// Record a verified, installed model (after the atomic `.part` → final rename, FR-011).
  Future<void> markInstalled({required String filePath, required int sizeBytes}) async {
    await _db.into(_db.modelInstalls).insertOnConflictUpdate(
          ModelInstallsCompanion.insert(
            id: ModelCatalog.modelId,
            state: ModelInstallState.installed.name,
            filePath: Value(filePath),
            sizeBytes: Value(sizeBytes),
            installedAt: Value(DateTime.now().toUtc()),
          ),
        );
  }

  /// Reset to not-installed (on delete/cancel, FR-030).
  Future<void> markNotInstalled() async {
    await _db.into(_db.modelInstalls).insertOnConflictUpdate(
          ModelInstallsCompanion.insert(
            id: ModelCatalog.modelId,
            state: ModelInstallState.notInstalled.name,
          ),
        );
  }
}

final modelInstallRepositoryProvider = Provider<ModelInstallRepository>((ref) {
  return ModelInstallRepository(ref.watch(appDatabaseProvider));
});
