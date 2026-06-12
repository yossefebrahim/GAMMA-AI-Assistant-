import 'package:ai_assistant/data/db/app_database.dart';
import 'package:ai_assistant/data/repositories/drift_memory_repository.dart';
import 'package:ai_assistant/domain/entities/memory.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_db.dart';

/// 005 contract memory_repository.md — dedupe/supersede/cap/soft-delete over REAL in-memory drift.
/// Dedupe is plain normalized token-overlap (NOT embeddings); supersede is conservative + scoped to
/// the same category; the cap bounds active growth; soft-delete keeps everything auditable; and a
/// fact outlives the conversation it was captured in (`ON DELETE SET NULL` provenance).
void main() {
  late AppDatabase db;
  late DriftMemoryRepository repo;

  setUp(() {
    db = newTestDatabase();
    repo = DriftMemoryRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  group('dedupe / supersede (data-model §3)', () {
    test('exact restatement does not duplicate — unchanged (SC-006)', () async {
      final first = await repo.upsert(
        fact: 'prefers dark mode',
        category: MemoryCategory.preferences,
      );
      expect(first, isA<UpsertCreated>());

      // Different case + punctuation normalizes to the same fact → no new row.
      final again = await repo.upsert(
        fact: 'Prefers dark mode.',
        category: MemoryCategory.preferences,
      );
      expect(again, isA<UpsertUnchanged>());
      expect(again.memory.id, first.memory.id);
      expect(await repo.activeCount(), 1);
    });

    test('name→name conflict supersedes in place (Jaccard 0.5)', () async {
      final created = await repo.upsert(
        fact: 'name is Yossef',
        category: MemoryCategory.identity,
      );
      final superseded = await repo.upsert(
        fact: 'name is Joe',
        category: MemoryCategory.identity,
      );

      expect(superseded, isA<UpsertSuperseded>());
      expect(
        superseded.memory.id,
        created.memory.id,
        reason: 'same row, updated in place',
      );
      expect(superseded.memory.fact, 'name is Joe');
      expect(
        await repo.activeCount(),
        1,
        reason: 'no contradictory second name fact',
      );
    });

    test('dark→light preference supersedes', () async {
      await repo.upsert(
        fact: 'prefers dark mode',
        category: MemoryCategory.preferences,
      );
      final superseded = await repo.upsert(
        fact: 'prefers light mode',
        category: MemoryCategory.preferences,
      );

      expect(superseded, isA<UpsertSuperseded>());
      expect(superseded.memory.fact, 'prefers light mode');
      expect(await repo.activeCount(), 1);
    });

    test(
      'distinct same-category facts are NOT merged (false-merge guard)',
      () async {
        await repo.upsert(
          fact: 'builds android apps',
          category: MemoryCategory.work,
        );
        final second = await repo.upsert(
          fact: 'works as a mobile developer',
          category: MemoryCategory.work,
        );

        expect(
          second,
          isA<UpsertCreated>(),
          reason: 'Jaccard ~0 → genuinely distinct facts',
        );
        expect(await repo.activeCount(), 2);
      },
    );

    test('dedupe is scoped to the same category', () async {
      await repo.upsert(
        fact: 'loves coffee',
        category: MemoryCategory.preferences,
      );
      final other = await repo.upsert(
        fact: 'loves coffee',
        category: MemoryCategory.other,
      );
      expect(
        other,
        isA<UpsertCreated>(),
        reason: 'identical text in a different category is a separate fact',
      );
      expect(await repo.activeCount(), 2);
    });
  });

  group('cap (R4)', () {
    test(
      'a 21st distinct fact deactivates the oldest, holding active at 20',
      () async {
        // 21 distinct single-word facts → pairwise Jaccard 0 → all inserts, no supersede.
        for (var i = 0; i < 21; i++) {
          await repo.upsert(
            fact: 'token${i.toString().padLeft(2, '0')}',
            category: MemoryCategory.other,
          );
        }
        expect(
          await repo.activeCount(),
          20,
          reason: 'cap holds the active count at 20',
        );

        final active = await repo.listActive();
        // token00 was inserted first (oldest by updatedAt+id) → it is the one deactivated.
        expect(active.any((m) => m.fact == 'token00'), isFalse);
        expect(active.any((m) => m.fact == 'token20'), isTrue);
      },
    );
  });

  group('soft-delete (FR-010)', () {
    test(
      'softDeleteById is true for an active id, false for unknown/inactive',
      () async {
        final created = await repo.upsert(
          fact: 'name is Joe',
          category: MemoryCategory.identity,
        );
        final id = created.memory.id;

        expect(await repo.softDeleteById(id), isTrue);
        expect(await repo.activeCount(), 0);
        expect((await repo.listActive()).any((m) => m.id == id), isFalse);

        // Already inactive → false (no re-delete); unknown id → false (never fuzzy-delete).
        expect(await repo.softDeleteById(id), isFalse);
        expect(await repo.softDeleteById(999999), isFalse);
      },
    );

    test('clearAll soft-deletes every active fact', () async {
      await repo.upsert(fact: 'name is Joe', category: MemoryCategory.identity);
      await repo.upsert(
        fact: 'mobile developer',
        category: MemoryCategory.work,
      );
      await repo.upsert(
        fact: 'prefers dark mode',
        category: MemoryCategory.preferences,
      );
      expect(await repo.activeCount(), 3);

      await repo.clearAll();
      expect(await repo.activeCount(), 0);
      expect(await repo.listActive(), isEmpty);
    });
  });

  group('editFact (FR-017)', () {
    test('replaces an active fact text + category', () async {
      final created = await repo.upsert(
        fact: 'name is Joe',
        category: MemoryCategory.identity,
      );
      await repo.editFact(
        created.memory.id,
        'name is Joseph',
        MemoryCategory.identity,
      );

      final active = await repo.listActive();
      expect(active.single.fact, 'name is Joseph');
      expect(active.single.category, MemoryCategory.identity);
    });
  });

  group('ordering (FR-015)', () {
    test(
      'listActive is ordered by category (declaration order) then recency',
      () async {
        await repo.upsert(
          fact: 'wants metric units',
          category: MemoryCategory.preferences,
        );
        await repo.upsert(
          fact: 'name is Joe',
          category: MemoryCategory.identity,
        );
        await repo.upsert(
          fact: 'mobile developer',
          category: MemoryCategory.work,
        );
        await repo.upsert(fact: 'loves coffee', category: MemoryCategory.other);

        final categories = (await repo.listActive())
            .map((m) => m.category)
            .toList();
        expect(categories, [
          MemoryCategory.identity,
          MemoryCategory.work,
          MemoryCategory.preferences,
          MemoryCategory.other,
        ]);
      },
    );

    test('watchActive emits the active set reactively', () async {
      final emissions = <List<Memory>>[];
      final sub = repo.watchActive().listen(emissions.add);
      addTearDown(sub.cancel);

      await repo.upsert(fact: 'name is Joe', category: MemoryCategory.identity);
      await pumpEventQueue();

      expect(emissions.last.map((m) => m.fact), contains('name is Joe'));
    });
  });

  group('provenance (ON DELETE SET NULL, data-model §2)', () {
    test(
      'a captured fact outlives its source conversation, with provenance nulled',
      () async {
        final convId = await db
            .into(db.conversations)
            .insert(
              ConversationsCompanion.insert(
                createdAt: DateTime.utc(2026, 6, 10),
                updatedAt: DateTime.utc(2026, 6, 10),
              ),
            );
        await repo.upsert(
          fact: 'lives in Cairo',
          category: MemoryCategory.identity,
          sourceConversationId: convId,
        );

        // Deleting the conversation must NOT delete the fact (facts are durable, app-global).
        await (db.delete(
          db.conversations,
        )..where((c) => c.id.equals(convId))).go();

        final active = await repo.listActive();
        expect(
          active.where((m) => m.fact == 'lives in Cairo'),
          hasLength(1),
          reason: 'the fact survives the conversation delete',
        );

        final row = await (db.select(
          db.memories,
        )..where((m) => m.fact.equals('lives in Cairo'))).getSingle();
        expect(
          row.sourceConversationId,
          isNull,
          reason: 'provenance is nulled, not cascaded',
        );
      },
    );
  });
}
