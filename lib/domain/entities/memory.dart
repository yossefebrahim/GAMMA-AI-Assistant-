import 'package:meta/meta.dart';

/// A durable, app-global fact about the user (005, data-model §1). Persisted in the `memories`
/// table; only `active` facts are injected into the model's system message or shown in settings.
/// Immutable — the repository maps rows to this and supersede/edit produce new rows/values.
@immutable
class Memory {
  const Memory({
    required this.id,
    required this.fact,
    required this.category,
    required this.createdAt,
    required this.updatedAt,
    this.active = true,
    this.sourceConversationId,
  });

  /// Autoincrement PK; the id injected into the facts block and referenced by `forget_fact(id)`.
  final int id;

  /// Short canonical statement; non-empty after trim; ≤ 80 chars (R4, validated on capture).
  final String fact;

  /// Grouping key for the block + settings; fixed enum declaration order is the render order.
  final MemoryCategory category;

  final DateTime createdAt;

  /// Refreshed on supersede/edit; the recency key for block ordering + the cap (data-model §3).
  final DateTime updatedAt;

  /// Soft-delete / supersede flag — only `active` facts are injected or listed.
  final bool active;

  /// The conversation it was captured in; `null` for manually-added facts or once the source
  /// conversation is deleted (`ON DELETE SET NULL`, data-model §2).
  final int? sourceConversationId;

  Memory copyWith({
    String? fact,
    MemoryCategory? category,
    DateTime? updatedAt,
    bool? active,
  }) {
    return Memory(
      id: id,
      fact: fact ?? this.fact,
      category: category ?? this.category,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      active: active ?? this.active,
      sourceConversationId: sourceConversationId,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Memory &&
      other.id == id &&
      other.fact == fact &&
      other.category == category &&
      other.createdAt == createdAt &&
      other.updatedAt == updatedAt &&
      other.active == active &&
      other.sourceConversationId == sourceConversationId;

  @override
  int get hashCode => Object.hash(
    id,
    fact,
    category,
    createdAt,
    updatedAt,
    active,
    sourceConversationId,
  );
}

/// Fact categories (data-model §1). Declaration order is the canonical render order for both the
/// injected facts block and the settings screen (FR-015) — keep `identity` first, `other` last.
enum MemoryCategory { identity, work, preferences, other }

/// The outcome of [MemoryRepository.upsert] (data-model §3). `sealed` so the dispatcher's
/// remember_fact handler maps every case exhaustively to a chip summary: a fresh insert says
/// "remembered", an in-place supersede says "updated", and an exact restatement (no new row,
/// `updatedAt` refreshed) is "noted". All three carry the resulting active [memory].
@immutable
sealed class UpsertResult {
  const UpsertResult(this.memory);

  final Memory memory;
}

/// A new active fact was inserted (chip: "remembered: …").
@immutable
final class UpsertCreated extends UpsertResult {
  const UpsertCreated(super.memory);
}

/// A same-category near-duplicate / conflict was updated in place (chip: "updated: …", data-model
/// §3 supersede).
@immutable
final class UpsertSuperseded extends UpsertResult {
  const UpsertSuperseded(super.memory);
}

/// An exact restatement of an existing active fact — no new row; `updatedAt` refreshed (chip:
/// "noted: …", SC-006 restate case).
@immutable
final class UpsertUnchanged extends UpsertResult {
  const UpsertUnchanged(super.memory);
}
