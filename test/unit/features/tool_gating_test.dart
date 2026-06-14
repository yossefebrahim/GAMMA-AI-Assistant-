import 'package:ai_assistant/core/model_catalog.dart';
import 'package:ai_assistant/core/tools/tool_registry.dart';
import 'package:ai_assistant/data/repositories/settings_repository.dart';
import 'package:ai_assistant/domain/entities/model_capabilities.dart';
import 'package:ai_assistant/features/chat/chat_providers.dart';
import 'package:ai_assistant/features/chat/tool_handler_providers.dart';
import 'package:ai_assistant/infrastructure/gemma/flutter_gemma_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/container_harness.dart';
import '../../helpers/fake_gemma_service.dart';
import '../../helpers/fake_secure_key_store.dart';

/// 004 US3 — capability gating is provably data-driven. Tools couple STRUCTURALLY to
/// `capabilities.functionCalling` (guarantees 18/19): flag-off load passes empty tools + flag
/// false; flag-on passes the registry; an ungated `loadModel(tools:)` is a StateError. Verified at
/// the seam-contract level (the fake models the gate) and the provider-wiring level.
///
/// 006 T031: the provider wiring test is extended to exercise the triple gate
/// (functionCalling && webAccessEnabled && hasValidKey). The test overrides
/// [secureKeyStoreProvider] with a [FakeSecureKeyStore] seeded with a key and
/// [webAccessEnabledProvider] with [_AlwaysTrueWebAccess] so all three gate
/// conditions are satisfied — producing all eight tools.

/// Stub notifier: [webAccessEnabledProvider] always returns true (triple-gate test fixture).
/// Extends [WebAccessEnabledController] (the exact type required by [NotifierProvider.overrideWith])
/// and short-circuits [build] to `true` without touching the stream/DB.
class _AlwaysTrueWebAccess extends WebAccessEnabledController {
  @override
  bool build() => true;
}

void main() {
  group('seam gate (guarantees 18 & 19)', () {
    test(
      'flag-off: empty tools + functionCalling false — byte-parity inputs (guarantee 19)',
      () async {
        final gemma = FakeGemmaService();
        await gemma.loadModel(
          '/m',
          capabilities: ModelCapabilities.textOnly,
          tools: const [],
        );
        expect(gemma.loadedTools, isEmpty);
        expect(gemma.loadedCapabilities!.functionCalling, isFalse);
      },
    );

    test(
      'flag-on: the registry tools are passed, coupled to the capability',
      () async {
        final gemma = FakeGemmaService();
        await gemma.loadModel(
          '/m',
          capabilities: const ModelCapabilities(functionCalling: true),
          tools: ToolRegistry.specs,
        );
        expect(gemma.loadedTools, ToolRegistry.specs);
        expect(gemma.loadedCapabilities!.functionCalling, isTrue);
      },
    );

    test(
      'ungated tools (flag off + non-empty tools) → StateError (guarantee 18)',
      () async {
        final gemma = FakeGemmaService();
        expect(
          () => gemma.loadModel(
            '/m',
            capabilities: ModelCapabilities.textOnly,
            tools: ToolRegistry.specs,
          ),
          throwsStateError,
        );
      },
    );
  });

  group('provider wiring (the catalog flag drives the tools passed)', () {
    test(
      'with the catalog flag on, modelSessionProvider threads the registry tools',
      () async {
        // Guard: this assertion only holds while the catalog declares function calling.
        expect(ModelCatalog.capabilities.functionCalling, isTrue);

        // The triple gate (functionCalling && webAccessEnabled && hasValidKey) must all be true
        // for all eight tools to be threaded. Override the key store and web-access flag so the
        // gate is satisfied in this test container (no platform channels, no real secure storage).
        final keyStore = FakeSecureKeyStore()..seed('fake-tavily-key');

        final gemma = FakeGemmaService();
        final container = makeContainer(
          secureKeyStore: keyStore,
          overrides: [
            gemmaServiceProvider.overrideWithValue(gemma),
            installedModelPathProvider.overrideWith(
              (ref) async => '/fake/model',
            ),
            webAccessEnabledProvider.overrideWith(_AlwaysTrueWebAccess.new),
          ],
        );
        addTearDown(container.dispose);

        final sub = container.listen(modelSessionProvider, (_, _) {});
        await container.read(modelSessionProvider.future);

        expect(gemma.loadedTools, ToolRegistry.specs);
        expect(gemma.loadedCapabilities!.functionCalling, isTrue);
        sub.close();
      },
    );

    test(
      'on macOS, set_timer is NOT declared but the other tools are (007 FR-008)',
      () async {
        expect(ModelCatalog.capabilities.functionCalling, isTrue);
        final keyStore = FakeSecureKeyStore()..seed('fake-tavily-key');
        final gemma = FakeGemmaService();
        final container = makeContainer(
          isMacOs: true,
          secureKeyStore: keyStore,
          overrides: [
            gemmaServiceProvider.overrideWithValue(gemma),
            installedModelPathProvider.overrideWith(
              (ref) async => '/fake/model',
            ),
            webAccessEnabledProvider.overrideWith(_AlwaysTrueWebAccess.new),
          ],
        );
        addTearDown(container.dispose);

        final sub = container.listen(modelSessionProvider, (_, _) {});
        await container.read(modelSessionProvider.future);

        final names = gemma.loadedTools!.map((t) => t.name).toList();
        expect(names, contains('get_device_info'));
        expect(
          names,
          isNot(contains('set_timer')),
          reason: 'set_timer has no macOS implementation (007 FR-008)',
        );
        // All eight registry tools minus set_timer.
        expect(gemma.loadedTools!.length, ToolRegistry.specs.length - 1);
        sub.close();
      },
    );
  });
}
