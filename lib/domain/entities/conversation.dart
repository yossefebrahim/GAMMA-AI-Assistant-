import 'package:meta/meta.dart';

/// A single chat thread (FR-018…FR-021). Persisted in the `conversations` table.
@immutable
class Conversation {
  const Conversation({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
  });

  /// Immutable identity (PK).
  final int id;

  /// Derived from the first user message, trimmed to ≤40 chars (FR-021); `null` until the first
  /// message, with a fallback label applied if that message is empty after trimming.
  final String? title;

  final DateTime createdAt;

  /// Bumped on every new/changed message; the **primary sort key** for the history list
  /// (most-recent first).
  final DateTime updatedAt;

  Conversation copyWith({String? title, DateTime? updatedAt}) {
    return Conversation(
      id: id,
      title: title ?? this.title,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Conversation &&
      other.id == id &&
      other.title == title &&
      other.createdAt == createdAt &&
      other.updatedAt == updatedAt;

  @override
  int get hashCode => Object.hash(id, title, createdAt, updatedAt);
}
