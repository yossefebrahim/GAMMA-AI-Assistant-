import 'package:ai_assistant/domain/entities/memory.dart';

/// Abstraction over the `memories` drift table (R7) — the only seam for durable-fact storage.
///
/// `DriftMemoryRepository` (in `lib/data/repositories/`) is the only file wiring the `memories`
/// table; controllers, tool handlers, and composers depend on this interface and test with an
/// in-memory drift DB or `FakeMemoryRepository`. All reads/writes hit app-private OS-encrypted
/// SQLite — never the network, never embeddings/vectors (Principle I/IX). Dedupe/supersede is plain
/// string-token overlap (data-model §3). See `specs/005-memory/contracts/memory_repository.md`.
abstract interface class MemoryRepository {
  /// Active facts, ordered by category (declaration order) then `updatedAt` desc — drives BOTH the
  /// injected facts block AND the settings screen (they show the SAME set, FR-015). Reactive
  /// (drift `.watch`); emits on any capture/supersede/forget/clear/edit.
  Stream<List<Memory>> watchActive();

  /// One-shot ordered read of the active facts (for system-instruction composition at a session
  /// boundary, where a snapshot — not a stream — is what's needed).
  Future<List<Memory>> listActive();

  /// Capture path (the `remember_fact` handler + manual add). Runs dedupe/supersede BEFORE insert
  /// (data-model §3): a normalized exact match in the same category is `unchanged` (no dup,
  /// `updatedAt` refreshed); a same-category near-duplicate/conflict (content-word Jaccard ≥ the
  /// threshold) is `superseded` in place; otherwise a new active fact is inserted (`created`) and
  /// the active-count cap (≤ 20) is enforced. Returns what happened so the chip can say
  /// "remembered" / "updated" / "noted". [sourceConversationId] is the active conversation
  /// (injected by the controller, never a tool argument).
  Future<UpsertResult> upsert({
    required String fact,
    required MemoryCategory category,
    int? sourceConversationId,
  });

  /// `forget_fact` handler + settings delete. Soft-deletes (sets `active=false`) iff an ACTIVE row
  /// with [id] exists; returns `false` otherwise (→ `ToolFailure('no such fact')`; NEVER
  /// fuzzy-deletes — the model guesses ids, data-model §3 / FR-010).
  Future<bool> softDeleteById(int id);

  /// Settings edit — replace an active fact's text + category (validated upstream for length/enum).
  /// Refreshes `updatedAt`; applies from the next session (FR-017).
  Future<void> editFact(int id, String fact, MemoryCategory category);

  /// Settings clear-all (destructive) — soft-deletes every active fact.
  Future<void> clearAll();

  /// The number of active facts (drives the cap and the settings count).
  Future<int> activeCount();
}
