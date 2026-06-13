import 'package:ai_assistant/data/repositories/settings_repository.dart';
import 'package:ai_assistant/domain/entities/model_capabilities.dart';
import 'package:ai_assistant/features/settings/web_research_controller.dart';
import 'package:ai_assistant/infrastructure/gemma/flutter_gemma_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/container_harness.dart';
import '../../helpers/fake_gemma_service.dart';
import '../../helpers/fake_secure_key_store.dart';

/// T040 — WebResearchController unit tests (006, US2; FR-003, FR-004, FR-005, FR-032).
///
/// The controller never exposes the raw key (FR-003) — only [hasValidKey]. Each test injects a
/// [FakeSecureKeyStore] and (where a live session is needed) a loaded [FakeGemmaService] so the
/// session-refresh side-effect of save/clear/toggle is observable via [startSessionCount].
void main() {
  late FakeGemmaService gemma;
  late FakeSecureKeyStore keyStore;
  late ProviderContainer container;

  /// A container with a model already loaded so [refreshSessionInstruction] reaches [startSession].
  Future<ProviderContainer> makeLoaded({
    bool withKey = false,
    bool globalEnabled = false,
  }) async {
    gemma = FakeGemmaService(
      capabilitiesData: const ModelCapabilities(functionCalling: true),
    );
    keyStore = FakeSecureKeyStore();
    if (withKey) keyStore.seed('tvly-existing');
    final c = makeContainer(
      secureKeyStore: keyStore,
      overrides: [gemmaServiceProvider.overrideWithValue(gemma)],
    );
    if (globalEnabled) {
      await c.read(webAccessEnabledProvider.notifier).set(true);
    }
    await gemma.loadModel(
      '/fake/model.litertlm',
      capabilities: const ModelCapabilities(functionCalling: true),
      tools: const [],
    );
    return c;
  }

  /// A container with NO model loaded — the session-refresh is a no-op (cold start).
  ProviderContainer makeUnloaded({bool withKey = false}) {
    gemma = FakeGemmaService(
      capabilitiesData: const ModelCapabilities(functionCalling: true),
    );
    keyStore = FakeSecureKeyStore();
    if (withKey) keyStore.seed('tvly-existing');
    return makeContainer(
      secureKeyStore: keyStore,
      overrides: [gemmaServiceProvider.overrideWithValue(gemma)],
    );
  }

  tearDown(() => container.dispose());

  group('hasValidKey (FR-003 masking)', () {
    test('false when no key stored', () async {
      container = makeUnloaded();
      final ctrl = container.read(webResearchControllerProvider.notifier);
      expect(await ctrl.hasValidKey(), isFalse);
    });

    test('true after a key is stored', () async {
      container = makeUnloaded(withKey: true);
      final ctrl = container.read(webResearchControllerProvider.notifier);
      expect(await ctrl.hasValidKey(), isTrue);
    });
  });

  group('saveKey', () {
    test('writes the key to the store; hasValidKey becomes true', () async {
      container = makeUnloaded();
      final ctrl = container.read(webResearchControllerProvider.notifier);

      await ctrl.saveKey('tvly-new-key');

      expect(await ctrl.hasValidKey(), isTrue);
      expect(await keyStore.readTavilyKey(), 'tvly-new-key');
    });

    test('refreshes the live session (FR-032)', () async {
      container = await makeLoaded();
      final ctrl = container.read(webResearchControllerProvider.notifier);

      await ctrl.saveKey('tvly-new-key');

      expect(gemma.startSessionCount, 1);
    });

    test('no session refresh when no model is loaded (cold start)', () async {
      container = makeUnloaded();
      final ctrl = container.read(webResearchControllerProvider.notifier);

      await ctrl.saveKey('tvly-new-key');

      expect(gemma.startSessionCount, 0);
      expect(gemma.isLoaded, isFalse);
    });
  });

  group('clearKey (FR-004)', () {
    test('removes the key; hasValidKey becomes false', () async {
      container = makeUnloaded(withKey: true);
      final ctrl = container.read(webResearchControllerProvider.notifier);

      await ctrl.clearKey();

      expect(await ctrl.hasValidKey(), isFalse);
      expect(keyStore.clearWasCalled, isTrue);
    });

    test('sets the global toggle to false (FR-004)', () async {
      container = await makeLoaded(withKey: true, globalEnabled: true);
      expect(container.read(webAccessEnabledProvider), isTrue);
      final ctrl = container.read(webResearchControllerProvider.notifier);

      await ctrl.clearKey();

      expect(container.read(webAccessEnabledProvider), isFalse);
      expect(
        await container.read(settingsRepositoryProvider).readWebAccessEnabled(),
        isFalse,
      );
    });

    test('recreates the live session without web tools (FR-032)', () async {
      container = await makeLoaded(withKey: true, globalEnabled: true);
      final ctrl = container.read(webResearchControllerProvider.notifier);

      await ctrl.clearKey();

      expect(gemma.startSessionCount, 1);
    });
  });

  group('setGlobalToggle (FR-005)', () {
    test('enabling with no key is rejected; toggle stays off', () async {
      container = await makeLoaded();
      final ctrl = container.read(webResearchControllerProvider.notifier);

      final applied = await ctrl.setGlobalToggle(true);

      expect(applied, isFalse);
      expect(container.read(webAccessEnabledProvider), isFalse);
      // A rejected toggle does not recreate the session.
      expect(gemma.startSessionCount, 0);
    });

    test('enabling with a key persists true + refreshes the session', () async {
      container = await makeLoaded(withKey: true);
      final ctrl = container.read(webResearchControllerProvider.notifier);

      final applied = await ctrl.setGlobalToggle(true);

      expect(applied, isTrue);
      expect(container.read(webAccessEnabledProvider), isTrue);
      expect(gemma.startSessionCount, 1);
    });

    test('disabling is always allowed (no key needed)', () async {
      container = await makeLoaded(withKey: true, globalEnabled: true);
      final ctrl = container.read(webResearchControllerProvider.notifier);

      final applied = await ctrl.setGlobalToggle(false);

      expect(applied, isTrue);
      expect(container.read(webAccessEnabledProvider), isFalse);
    });
  });
}
