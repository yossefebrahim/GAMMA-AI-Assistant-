import 'package:ai_assistant/domain/entities/web_access_override.dart';
import 'package:meta/meta.dart';

/// A single chat thread (FR-018…FR-021). Persisted in the `conversations` table.
@immutable
class Conversation {
  const Conversation({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    this.webAccessOverride,
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

  /// Per-conversation web-access override (006, schema v6, FR-007). `null` means inherit the
  /// global [AppSettings.webAccessEnabled] setting (equivalent to [WebAccessOverride.inherit]).
  /// Persisted as NULL / 'on' / 'off' in `conversations.web_access_override` — the DB null maps
  /// to `null` here (the `inherit` enum value is never written; null IS inherit).
  final WebAccessOverride? webAccessOverride;

  Conversation copyWith({
    String? title,
    DateTime? updatedAt,
    // ignore: avoid_positional_boolean_parameters
    WebAccessOverride? webAccessOverride,
    bool clearWebAccessOverride = false,
  }) {
    return Conversation(
      id: id,
      title: title ?? this.title,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      webAccessOverride: clearWebAccessOverride
          ? null
          : (webAccessOverride ?? this.webAccessOverride),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Conversation &&
      other.id == id &&
      other.title == title &&
      other.createdAt == createdAt &&
      other.updatedAt == updatedAt &&
      other.webAccessOverride == webAccessOverride;

  @override
  int get hashCode =>
      Object.hash(id, title, createdAt, updatedAt, webAccessOverride);
}
