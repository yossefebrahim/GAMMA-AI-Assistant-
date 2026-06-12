import 'package:ai_assistant/data/db/app_database.dart';
import 'package:ai_assistant/domain/entities/memory.dart';
import 'package:ai_assistant/domain/repositories/memory_repository.dart';
import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// drift-backed [MemoryRepository] (R7) — the sole wirer of the `memories` table. Dedupe/supersede
/// (data-model §3) is plain normalized string-token overlap, NOT embeddings/semantic similarity
/// (the constitution boundary, Principle I/IX). Soft-delete throughout (`active=false`), so
/// supersede / forget / clear are auditable and inactive rows are never injected or listed. All
/// time is stored in UTC.
class DriftMemoryRepository implements MemoryRepository {
  DriftMemoryRepository(this._db);

  final AppDatabase _db;

  /// Active-fact cap (R4). After an insert pushes the count over this, the oldest-`updatedAt`
  /// actives are deactivated down to it.
  static const int maxActiveFacts = 20;

  /// Token-set Jaccard threshold for supersede (R8/data-model §3). ≥ this → an existing
  /// same-category fact is updated in place. Conservative to avoid false merges; user-correctable.
  static const double supersedeThreshold = 0.5;

  /// Intentionally MINIMAL stop-word set — English articles only. Dropping prepositions like "in"
  /// would break legitimate conflict supersede (e.g. "lives in cairo" → "lives in alexandria"
  /// drops to Jaccard 0.33), so they are deliberately kept. Copulas ("is") are kept too: they are
  /// what make "name is X" → "name is Y" land at the 0.5 threshold (data-model §3 numbers).
  static const Set<String> _stopWords = {'a', 'an', 'the'};

  static DateTime _now() => DateTime.now().toUtc();

  Memory _toMemory(MemoryRow r) => Memory(
    id: r.id,
    fact: r.fact,
    category: MemoryCategory.values.byName(r.category),
    createdAt: r.createdAt,
    updatedAt: r.updatedAt,
    active: r.active,
    sourceConversationId: r.sourceConversationId,
  );

  /// lowercase, strip punctuation to spaces, collapse whitespace, trim (data-model §3).
  String _normalize(String s) => s
      .toLowerCase()
      .replaceAll(RegExp(r'[^\w\s]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  /// Content-word token set of an already-normalized string (articles dropped).
  Set<String> _contentWords(String normalized) => normalized
      .split(' ')
      .where((w) => w.isNotEmpty && !_stopWords.contains(w))
      .toSet();

  double _jaccard(Set<String> a, Set<String> b) {
    if (a.isEmpty || b.isEmpty) return 0;
    final intersection = a.intersection(b).length;
    final union = a.union(b).length;
    return intersection / union;
  }

  /// Active facts ordered by category (enum declaration order) then `updatedAt` desc — the SAME
  /// set the settings screen and the facts block render (FR-015). id desc breaks ties so the order
  /// is deterministic.
  List<Memory> _ordered(List<MemoryRow> rows) {
    final list = rows.map(_toMemory).toList();
    list.sort((a, b) {
      final byCategory = a.category.index.compareTo(b.category.index);
      if (byCategory != 0) return byCategory;
      final byUpdated = b.updatedAt.compareTo(a.updatedAt);
      if (byUpdated != 0) return byUpdated;
      return b.id.compareTo(a.id);
    });
    return list;
  }

  @override
  Stream<List<Memory>> watchActive() => (_db.select(
    _db.memories,
  )..where((m) => m.active.equals(true))).watch().map(_ordered);

  @override
  Future<List<Memory>> listActive() async {
    final rows = await (_db.select(
      _db.memories,
    )..where((m) => m.active.equals(true))).get();
    return _ordered(rows);
  }

  @override
  Future<UpsertResult> upsert({
    required String fact,
    required MemoryCategory category,
    int? sourceConversationId,
  }) async {
    final trimmed = fact.trim();
    final normalizedIncoming = _normalize(trimmed);

    // Compare only against active facts in the SAME category, most-recent first (deterministic).
    final actives =
        await (_db.select(_db.memories)
              ..where(
                (m) => m.active.equals(true) & m.category.equals(category.name),
              )
              ..orderBy([
                (m) => OrderingTerm(
                  expression: m.updatedAt,
                  mode: OrderingMode.desc,
                ),
                (m) => OrderingTerm(expression: m.id, mode: OrderingMode.desc),
              ]))
            .get();

    // 1. Exact restatement → no new row, refresh updatedAt (SC-006).
    for (final a in actives) {
      if (_normalize(a.fact) == normalizedIncoming) {
        final now = _now();
        await (_db.update(_db.memories)..where((m) => m.id.equals(a.id))).write(
          MemoriesCompanion(updatedAt: Value(now)),
        );
        return UpsertUnchanged(_toMemory(a).copyWith(updatedAt: now));
      }
    }

    // 2. Near-duplicate / conflict (Jaccard ≥ threshold) → supersede in place.
    final incomingWords = _contentWords(normalizedIncoming);
    for (final a in actives) {
      final similarity = _jaccard(
        incomingWords,
        _contentWords(_normalize(a.fact)),
      );
      if (similarity >= supersedeThreshold) {
        final now = _now();
        await (_db.update(_db.memories)..where((m) => m.id.equals(a.id))).write(
          MemoriesCompanion(fact: Value(trimmed), updatedAt: Value(now)),
        );
        return UpsertSuperseded(
          _toMemory(a).copyWith(fact: trimmed, updatedAt: now),
        );
      }
    }

    // 3. Otherwise insert a new active fact, then enforce the cap.
    final now = _now();
    final id = await _db
        .into(_db.memories)
        .insert(
          MemoriesCompanion.insert(
            fact: trimmed,
            category: category.name,
            createdAt: now,
            updatedAt: now,
            sourceConversationId: Value(sourceConversationId),
          ),
        );
    await _enforceCap();
    final inserted = await (_db.select(
      _db.memories,
    )..where((m) => m.id.equals(id))).getSingle();
    return UpsertCreated(_toMemory(inserted));
  }

  /// If the active count exceeds [maxActiveFacts], deactivate the oldest-`updatedAt` actives down
  /// to the cap (R4 — never unbounded growth).
  Future<void> _enforceCap() async {
    final actives =
        await (_db.select(_db.memories)
              ..where((m) => m.active.equals(true))
              ..orderBy([
                (m) => OrderingTerm(
                  expression: m.updatedAt,
                  mode: OrderingMode.desc,
                ),
                (m) => OrderingTerm(expression: m.id, mode: OrderingMode.desc),
              ]))
            .get();
    if (actives.length <= maxActiveFacts) return;
    for (final row in actives.skip(maxActiveFacts)) {
      await (_db.update(_db.memories)..where((m) => m.id.equals(row.id))).write(
        const MemoriesCompanion(active: Value(false)),
      );
    }
  }

  @override
  Future<bool> softDeleteById(int id) async {
    // Soft-delete iff an ACTIVE row with this id exists — never fuzzy-delete (FR-010). The update
    // count is 0 for an unknown or already-inactive id.
    final updated =
        await (_db.update(_db.memories)
              ..where((m) => m.id.equals(id) & m.active.equals(true)))
            .write(const MemoriesCompanion(active: Value(false)));
    return updated > 0;
  }

  @override
  Future<void> editFact(int id, String fact, MemoryCategory category) async {
    await (_db.update(
      _db.memories,
    )..where((m) => m.id.equals(id) & m.active.equals(true))).write(
      MemoriesCompanion(
        fact: Value(fact.trim()),
        category: Value(category.name),
        updatedAt: Value(_now()),
      ),
    );
  }

  @override
  Future<void> clearAll() async {
    await (_db.update(_db.memories)..where((m) => m.active.equals(true))).write(
      const MemoriesCompanion(active: Value(false)),
    );
  }

  @override
  Future<int> activeCount() async {
    final count = _db.memories.id.count();
    final query = _db.selectOnly(_db.memories)
      ..addColumns([count])
      ..where(_db.memories.active.equals(true));
    final row = await query.getSingle();
    return row.read(count) ?? 0;
  }
}

/// App-wide [MemoryRepository] backed by the drift database (in-memory in tests). Lives here beside
/// its only implementation, mirroring `conversationRepositoryProvider` / `settingsRepositoryProvider`.
final memoryRepositoryProvider = Provider<MemoryRepository>((ref) {
  return DriftMemoryRepository(ref.watch(appDatabaseProvider));
});

/// Reactive active facts (ordered category→updatedAt desc) — drives the settings screen and the
/// system-instruction composition (the same set, FR-015). Mirrors `settingsStreamProvider`.
final activeMemoriesProvider = StreamProvider<List<Memory>>((ref) {
  return ref.watch(memoryRepositoryProvider).watchActive();
});
