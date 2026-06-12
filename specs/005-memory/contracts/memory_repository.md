# Contract — MemoryRepository (005)

Plugin-free (Principle VII). Interface in `lib/domain/repositories/memory_repository.dart`; the only
implementation, `DriftMemoryRepository` (`lib/data/repositories/`), is the sole wirer of the
`memories` drift table. Controllers/handlers/composers depend on the interface and test with an
in-memory drift DB or a fake. All reads/writes hit app-private OS-encrypted SQLite — never the network
(Principle I); no embeddings/vectors (Principle IX).

## Interface

```dart
abstract interface class MemoryRepository {
  /// Active facts, ordered by category then updatedAt desc — drives the facts block AND the
  /// settings screen (they show the SAME set, FR-015). Reactive (drift .watch).
  Stream<List<Memory>> watchActive();
  Future<List<Memory>> listActive();

  /// Capture path (remember_fact handler + manual add). Runs dedupe/supersede BEFORE insert
  /// (data-model §3) and enforces the active-count cap. Returns what happened so the chip can say
  /// "remembered" vs "updated".
  Future<UpsertResult> upsert({
    required String fact,
    required MemoryCategory category,
    int? sourceConversationId,
  });

  /// forget_fact handler + settings delete. Soft-deletes (active=false) iff an ACTIVE row with [id]
  /// exists; returns false otherwise (→ ToolFailure('no such fact'); NEVER fuzzy-deletes).
  Future<bool> softDeleteById(int id);

  /// Settings edit — replace a fact's text (re-runs normalization/length validation upstream);
  /// applies from the next session (FR-017).
  Future<void> editFact(int id, String fact, MemoryCategory category);

  /// Settings clear-all (destructive) — soft-deletes every active fact.
  Future<void> clearAll();

  Future<int> activeCount();
}

sealed class UpsertResult { /* created(Memory) | superseded(Memory) | unchanged(Memory) */ }
```

## Guarantees (unit-tested)

1. **Dedupe is exact-within-category**: an active fact whose normalized text equals the incoming one
   (same category) is NOT duplicated — `unchanged`, `updatedAt` refreshed (SC-006 restate case).
2. **Supersede is conservative & deterministic**: a same-category active fact with normalized
   content-word Jaccard ≥ the threshold (~0.5) is updated in place — `superseded` (spike conflict
   cases: name→name, dark→light). Distinct same-category facts (Jaccard < threshold) are NOT merged
   (false-merge guard test). No embeddings/semantic similarity — plain token overlap only.
3. **Cap enforced**: after an insert pushing the active count over 20, the oldest-`updatedAt` actives
   are deactivated down to 20 (R4). Never unbounded growth.
4. **Soft-delete only**: `softDeleteById`/`clearAll`/supersede set `active=false`; rows are never hard-
   deleted here, so `forget` and `clear` are auditable and `active=false` rows are never injected or
   listed. `forget_fact` on a non-active/absent id → `false` (→ structured error, FR-010).
5. **Provenance survives conversation delete**: deleting a conversation nulls `sourceConversationId`
   (`ON DELETE SET NULL`) — it does NOT delete the fact (facts are app-global, durable; data-model §2).
6. **Validation is upstream**: length (≤80) + category-enum are enforced by the schema validator
   (capture) and the settings form (manual) BEFORE `upsert`/`editFact`; the repo trusts validated
   input but still normalizes for dedupe.

## Fakes / tests

- `FakeMemoryRepository` (in-memory list) for handler + composer + controller tests.
- In-memory drift for `DriftMemoryRepository` dedupe/supersede/cap/soft-delete tests.
- Migration test (v4→v5) lives with the data tests (data-model §2).
