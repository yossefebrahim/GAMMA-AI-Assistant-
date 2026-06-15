import 'package:ai_assistant/data/db/app_database.dart';
import 'package:ai_assistant/domain/services/network_research_service.dart';
import 'package:ai_assistant/domain/services/secure_key_store.dart';
import 'package:ai_assistant/features/chat/chat_providers.dart' show isMacOsProvider;
import 'package:ai_assistant/features/chat/tool_handler_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// Riverpod 3 splits its public surface across entrypoints; the `Override` type lives in `misc`.
import 'package:flutter_riverpod/misc.dart' show Override;

import 'fake_network_research_service.dart';
import 'fake_secure_key_store.dart';
import 'test_db.dart';

/// Builds a [ProviderContainer] wired with an in-memory database by default, so any provider
/// graph depending on `appDatabaseProvider` (repositories, settings, controllers) can be unit
/// tested off-device. Pass [overrides] to inject seam fakes (FakeGemmaService, etc.).
///
/// The database is closed when the container is disposed (via the provider's `onDispose`), so
/// tests only need `addTearDown(container.dispose)`.
///
/// The 006 network seams ([secureKeyStoreProvider], [networkResearchServiceProvider]) default to
/// no-network fakes so any provider graph that starts a chat session (which reads `hasValidKey()`)
/// never touches `flutter_secure_storage` or `package:http`. Tests exercising web tools pass a
/// configured [secureKeyStore] / [networkResearch] instead of overriding via [overrides] — keeping
/// these out of the list avoids Riverpod's duplicate-override assertion.
ProviderContainer makeContainer({
  List<Override> overrides = const <Override>[],
  AppDatabase? database,
  SecureKeyStore? secureKeyStore,
  NetworkResearchService? networkResearch,
  bool isMacOs = false,
}) {
  final db = database ?? newTestDatabase();
  return ProviderContainer(
    overrides: <Override>[
      appDatabaseProvider.overrideWith((ref) {
        ref.onDispose(db.close);
        return db;
      }),
      secureKeyStoreProvider.overrideWithValue(
        secureKeyStore ?? FakeSecureKeyStore(),
      ),
      networkResearchServiceProvider.overrideWithValue(
        networkResearch ?? FakeNetworkResearchService(),
      ),
      // Pin the platform gate (007 macOS support, FR-008) so tests don't depend on the host
      // platform — host tests run on macOS, where the real provider would drop `set_timer`. Pass
      // `isMacOs: true` to exercise the macOS tool-declaration path. Kept OUT of [overrides] (like
      // [secureKeyStore]) to avoid Riverpod's duplicate-override assertion.
      isMacOsProvider.overrideWithValue(isMacOs),
      ...overrides,
    ],
  );
}
