import 'package:ai_assistant/domain/entities/memory.dart';

/// Pure function: converts the active fact list into the system-message facts block (data-model §2,
/// R3/R4). Called by [SystemInstructionComposer] when memory is enabled and ≥1 fact is active.
///
/// Usage:
/// ```dart
/// final block = FactsBlockComposer.compose(activeFacts);
/// // block is '' when activeFacts is empty → no token cost.
/// ```
///
/// **Format** (data-model example):
/// ```
/// known facts about the user (saved across chats):
/// identity — #1 name is Joe; #2 lives in Cairo, Egypt (GMT+2)
/// work — #4 builds Android apps with Flutter and Dart
/// preferences — #8 prefers dark mode; #10 wants metric units
/// ```
///
/// Categories appear in [MemoryCategory] declaration order (identity, work, preferences, other);
/// within a category facts are ordered `updatedAt` desc (most recent first). Capped to ≤ 20 facts
/// AND ≤ 900 chars — when either bound is exceeded the oldest (lowest `updatedAt`) facts are dropped
/// first (R4).
abstract final class FactsBlockComposer {
  /// The header line injected at the top of the block.
  static const String _header =
      'known facts about the user (saved across chats):';

  /// Hard caps (R4).
  static const int _maxFacts = 20;
  static const int _maxChars = 900;

  /// Compose a facts block from [memories] (must all be active; inactive facts are the caller's
  /// responsibility to filter). Returns `''` for an empty input — callers must treat an empty
  /// return as "no block" (zero token cost).
  static String compose(List<Memory> memories) {
    if (memories.isEmpty) return '';

    // Sort defensively: primary key = category enum index (declaration order); secondary key =
    // updatedAt desc (most recent first). The repository already returns this order, but the spec
    // says "don't assume".
    final sorted = memories.toList()
      ..sort((a, b) {
        final catCmp = a.category.index.compareTo(b.category.index);
        if (catCmp != 0) return catCmp;
        return b.updatedAt.compareTo(a.updatedAt); // desc
      });

    // Apply the fact-count cap (oldest = tail of the sorted list after desc-within-category sort;
    // globally oldest = lowest updatedAt overall). Drop from oldest first.
    List<Memory> capped = _dropOldestToFitCount(sorted, _maxFacts);

    // Apply the character cap iteratively: build → measure → drop oldest → repeat.
    // This is O(n²) in the worst case but n ≤ 20 so the cost is negligible.
    String block;
    while (true) {
      if (capped.isEmpty) return '';
      block = _buildBlock(capped);
      if (block.length <= _maxChars) break;
      // Remove the globally-oldest fact (lowest updatedAt) and try again.
      capped = _dropOldest(capped);
    }

    return block;
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  /// Drop facts from [sorted] until at most [max] remain. Removal is oldest-first (globally lowest
  /// `updatedAt`). The sort order (category asc, updatedAt desc) means the globally oldest facts
  /// are NOT necessarily at the tail; we must compare across categories.
  static List<Memory> _dropOldestToFitCount(List<Memory> sorted, int max) {
    if (sorted.length <= max) return sorted;
    // Build a mutable copy sorted by updatedAt asc so we can trim from the front.
    final byAge = sorted.toList()
      ..sort((a, b) => a.updatedAt.compareTo(b.updatedAt));
    final keep = byAge.sublist(byAge.length - max); // keep the newest `max`
    // Re-sort the kept subset into display order (category asc, updatedAt desc).
    return keep..sort((a, b) {
      final catCmp = a.category.index.compareTo(b.category.index);
      if (catCmp != 0) return catCmp;
      return b.updatedAt.compareTo(a.updatedAt);
    });
  }

  /// Remove the single globally-oldest fact (lowest `updatedAt`), preserving display order.
  static List<Memory> _dropOldest(List<Memory> facts) {
    if (facts.isEmpty) return facts;
    Memory? oldest;
    for (final m in facts) {
      if (oldest == null || m.updatedAt.isBefore(oldest.updatedAt)) {
        oldest = m;
      }
    }
    return facts.where((m) => m != oldest).toList();
  }

  /// Render [facts] (already in display order) into the block string.
  static String _buildBlock(List<Memory> facts) {
    final buf = StringBuffer(_header);

    // Group by category in the order they appear (already category-sorted).
    MemoryCategory? currentCat;
    final catBuf = StringBuffer();

    void flushCategory() {
      if (currentCat == null) return;
      buf.write('\n');
      buf.write(catBuf.toString());
    }

    for (final m in facts) {
      if (m.category != currentCat) {
        flushCategory();
        currentCat = m.category;
        catBuf.clear();
        catBuf.write('${m.category.name} — #${m.id} ${m.fact}');
      } else {
        catBuf.write('; #${m.id} ${m.fact}');
      }
    }
    flushCategory();

    return buf.toString();
  }
}
