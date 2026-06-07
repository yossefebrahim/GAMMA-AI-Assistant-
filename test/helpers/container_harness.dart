import 'package:ai_assistant/data/db/app_database.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// Riverpod 3 splits its public surface across entrypoints; the `Override` type lives in `misc`.
import 'package:flutter_riverpod/misc.dart' show Override;

import 'test_db.dart';

/// Builds a [ProviderContainer] wired with an in-memory database by default, so any provider
/// graph depending on `appDatabaseProvider` (repositories, settings, controllers) can be unit
/// tested off-device. Pass [overrides] to inject seam fakes (FakeGemmaService, etc.).
///
/// The database is closed when the container is disposed (via the provider's `onDispose`), so
/// tests only need `addTearDown(container.dispose)`.
ProviderContainer makeContainer({
  List<Override> overrides = const <Override>[],
  AppDatabase? database,
}) {
  final db = database ?? newTestDatabase();
  return ProviderContainer(
    overrides: <Override>[
      appDatabaseProvider.overrideWith((ref) {
        ref.onDispose(db.close);
        return db;
      }),
      ...overrides,
    ],
  );
}
