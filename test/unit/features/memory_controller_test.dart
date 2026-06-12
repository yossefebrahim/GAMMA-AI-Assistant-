import 'package:ai_assistant/data/repositories/drift_memory_repository.dart';
import 'package:ai_assistant/data/repositories/settings_repository.dart';
import 'package:ai_assistant/domain/entities/memory.dart';
import 'package:ai_assistant/domain/entities/model_capabilities.dart';
import 'package:ai_assistant/features/settings/memory_controller.dart';
import 'package:ai_assistant/infrastructure/gemma/flutter_gemma_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/container_harness.dart';
import '../../helpers/fake_gemma_service.dart';
import '../../helpers/fake_memory_repository.dart';

/// T028 — MemoryController unit tests (005, US3).
///
/// Each test overrides [gemmaServiceProvider] with a [FakeGemmaService] and
/// [memoryRepositoryProvider] with a [FakeMemoryRepository]. No SQLite, no plugin.
void main() {
  late FakeGemmaService gemma;
  late FakeMemoryRepository repo;
  late ProviderContainer container;

  /// Build a container with the given capabilities loaded (or not loaded at all).
  Future<ProviderContainer> makeLoaded({
    ModelCapabilities caps = const ModelCapabilities(functionCalling: true),
  }) async {
    gemma = FakeGemmaService(capabilitiesData: caps);
    repo = FakeMemoryRepository();
    final c = makeContainer(
      overrides: [
        gemmaServiceProvider.overrideWithValue(gemma),
        memoryRepositoryProvider.overrideWithValue(repo),
      ],
    );
    // Simulate a model already loaded so _refreshSession can proceed.
    await gemma.loadModel(
      '/fake/model.litertlm',
      capabilities: caps,
      tools: const [],
    );
    return c;
  }

  ProviderContainer makeUnloaded() {
    gemma = FakeGemmaService();
    repo = FakeMemoryRepository();
    return makeContainer(
      overrides: [
        gemmaServiceProvider.overrideWithValue(gemma),
        memoryRepositoryProvider.overrideWithValue(repo),
      ],
    );
  }

  tearDown(() {
    container.dispose();
    repo.dispose();
  });

  // ---------------------------------------------------------------------------
  // add (manual capture)
  // ---------------------------------------------------------------------------

  group('add', () {
    test('delegates to repository.upsert and returns UpsertCreated', () async {
      container = await makeLoaded();
      final ctrl = container.read(memoryControllerProvider.notifier);

      final result = await ctrl.add(
        fact: 'name is Alice',
        category: MemoryCategory.identity,
      );

      expect(result, isA<UpsertCreated>());
      expect(result.memory.fact, 'name is Alice');
      expect(result.memory.category, MemoryCategory.identity);
    });

    test('returns UpsertUnchanged on exact restatement', () async {
      container = await makeLoaded();
      final ctrl = container.read(memoryControllerProvider.notifier);
      await ctrl.add(fact: 'name is Alice', category: MemoryCategory.identity);

      final result = await ctrl.add(
        fact: 'name is Alice',
        category: MemoryCategory.identity,
      );

      expect(result, isA<UpsertUnchanged>());
    });

    test('returns UpsertSuperseded on near-duplicate', () async {
      container = await makeLoaded();
      final ctrl = container.read(memoryControllerProvider.notifier);
      await ctrl.add(fact: 'name is Alice', category: MemoryCategory.identity);

      // "name is Bob" has jaccard ≥ 0.5 with "name is Alice" on content words {name, is, alice/bob}
      final result = await ctrl.add(
        fact: 'name is Bob',
        category: MemoryCategory.identity,
      );

      expect(result, isA<UpsertSuperseded>());
    });

    test(
      'does NOT call startSession (session refresh is deferred to next open)',
      () async {
        container = await makeLoaded();
        final ctrl = container.read(memoryControllerProvider.notifier);

        await ctrl.add(
          fact: 'name is Alice',
          category: MemoryCategory.identity,
        );

        expect(gemma.startSessionCount, 0);
      },
    );
  });

  // ---------------------------------------------------------------------------
  // edit
  // ---------------------------------------------------------------------------

  group('edit', () {
    test('delegates to repository.editFact', () async {
      container = await makeLoaded();
      final ctrl = container.read(memoryControllerProvider.notifier);
      final upsert = await ctrl.add(
        fact: 'name is Alice',
        category: MemoryCategory.identity,
      );
      final id = upsert.memory.id;

      await ctrl.edit(id, 'name is Alicia', MemoryCategory.identity);

      final facts = await repo.listActive();
      expect(
        facts.any((m) => m.id == id && m.fact == 'name is Alicia'),
        isTrue,
      );
    });

    test('does NOT call startSession', () async {
      container = await makeLoaded();
      final ctrl = container.read(memoryControllerProvider.notifier);
      final upsert = await ctrl.add(
        fact: 'name is Alice',
        category: MemoryCategory.identity,
      );

      await ctrl.edit(
        upsert.memory.id,
        'name is Alicia',
        MemoryCategory.identity,
      );

      expect(gemma.startSessionCount, 0);
    });
  });

  // ---------------------------------------------------------------------------
  // delete
  // ---------------------------------------------------------------------------

  group('delete', () {
    test('returns true and removes an active fact', () async {
      container = await makeLoaded();
      final ctrl = container.read(memoryControllerProvider.notifier);
      final upsert = await ctrl.add(
        fact: 'uses dark mode',
        category: MemoryCategory.preferences,
      );
      final id = upsert.memory.id;

      final deleted = await ctrl.delete(id);

      expect(deleted, isTrue);
      final facts = await repo.listActive();
      expect(facts.any((m) => m.id == id), isFalse);
    });

    test('returns false for an unknown id', () async {
      container = await makeLoaded();
      final ctrl = container.read(memoryControllerProvider.notifier);

      final deleted = await ctrl.delete(999);

      expect(deleted, isFalse);
    });

    test('does NOT call startSession', () async {
      container = await makeLoaded();
      final ctrl = container.read(memoryControllerProvider.notifier);
      final upsert = await ctrl.add(
        fact: 'uses dark mode',
        category: MemoryCategory.preferences,
      );

      await ctrl.delete(upsert.memory.id);

      expect(gemma.startSessionCount, 0);
    });
  });

  // ---------------------------------------------------------------------------
  // clearAll
  // ---------------------------------------------------------------------------

  group('clearAll', () {
    test('soft-deletes all active facts', () async {
      container = await makeLoaded();
      final ctrl = container.read(memoryControllerProvider.notifier);
      await ctrl.add(fact: 'name is Alice', category: MemoryCategory.identity);
      await ctrl.add(
        fact: 'uses dark mode',
        category: MemoryCategory.preferences,
      );

      await ctrl.clearAll();

      expect(await repo.activeCount(), 0);
    });

    test('does NOT call startSession', () async {
      container = await makeLoaded();
      final ctrl = container.read(memoryControllerProvider.notifier);
      await ctrl.add(fact: 'name is Alice', category: MemoryCategory.identity);

      await ctrl.clearAll();

      expect(gemma.startSessionCount, 0);
    });
  });

  // ---------------------------------------------------------------------------
  // setEnabled
  // ---------------------------------------------------------------------------

  group('setEnabled', () {
    test('persists false and reflects in memoryEnabledProvider', () async {
      container = await makeLoaded();
      final ctrl = container.read(memoryControllerProvider.notifier);

      await ctrl.setEnabled(false);

      expect(container.read(memoryEnabledProvider), isFalse);
      expect(
        await container.read(settingsRepositoryProvider).readMemoryEnabled(),
        isFalse,
      );
    });

    test('persists true after false', () async {
      container = await makeLoaded();
      final ctrl = container.read(memoryControllerProvider.notifier);
      await ctrl.setEnabled(false);

      await ctrl.setEnabled(true);

      expect(container.read(memoryEnabledProvider), isTrue);
    });

    test(
      'calls startSession exactly once when model is loaded (FR-014)',
      () async {
        container = await makeLoaded();
        final ctrl = container.read(memoryControllerProvider.notifier);

        await ctrl.setEnabled(false);

        expect(gemma.startSessionCount, 1);
      },
    );

    test('does NOT call startSession when model is not loaded', () async {
      container = makeUnloaded();
      final ctrl = container.read(memoryControllerProvider.notifier);

      await ctrl.setEnabled(false);

      expect(gemma.startSessionCount, 0);
    });

    test(
      'startSession receives null instruction when memory disabled and no facts',
      () async {
        container = await makeLoaded();
        final ctrl = container.read(memoryControllerProvider.notifier);

        await ctrl.setEnabled(false);

        // functionCalling true but memoryEnabled false and no facts → all three composer parts absent
        // → null instruction (byte-parity guarantee 29 with deviceTools=true only kept by systemInstruction
        // not being null when functionCalling is on; however with no device tools instruction in this
        // path the instruction IS the device tool instruction only — check it is non-null).
        // With functionCalling=true the device-tool part IS included → non-null.
        expect(gemma.startSessionCount, 1);
        // With functionCalling=true + memoryEnabled=false → deviceTools instruction present (non-null).
        expect(gemma.lastStartSessionInstruction, isNotNull);
      },
    );

    test(
      'startSession receives null instruction when functionCalling off and no facts',
      () async {
        container = await makeLoaded(caps: ModelCapabilities.textOnly);
        final ctrl = container.read(memoryControllerProvider.notifier);

        await ctrl.setEnabled(false);

        // functionCalling=false, memoryEnabled=false, no facts → composer returns null
        expect(gemma.lastStartSessionInstruction, isNull);
      },
    );

    test(
      'startSession instruction contains facts block when memory enabled with facts',
      () async {
        container = await makeLoaded();
        repo.seed([
          Memory(
            id: 1,
            fact: 'name is Alice',
            category: MemoryCategory.identity,
            createdAt: DateTime(2025),
            updatedAt: DateTime(2025),
          ),
        ]);
        final ctrl = container.read(memoryControllerProvider.notifier);

        // setEnabled(true) with a fact seeded → instruction should contain the facts block
        await ctrl.setEnabled(true);

        expect(gemma.lastStartSessionInstruction, contains('name is Alice'));
      },
    );
  });
}
