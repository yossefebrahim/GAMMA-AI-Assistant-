/// Shared order-independent equality + hashing for the small `Map<String, Object?>`
/// payloads carried by domain entities ([Message.toolArgs]/[Message.toolResult],
/// [ChatTurn.toolArgs]/[ChatTurn.toolResult], [ToolCallRequested.args]).
///
/// Pure Dart, zero Flutter/Drift/plugin imports — entities import this without breaking the
/// dependency rule. Non-null callers (e.g. [ToolCallRequested.args] is always non-null) pass
/// through the nullable variant unchanged: two non-null maps never short-circuit on the
/// null-equality branch.
library;

/// Structural map equality: same length and same key→value pairs, order-independent. Two `null`
/// maps are equal; a `null` and a non-`null` map are not.
bool mapEquals(Map<String, Object?>? a, Map<String, Object?>? b) {
  if (a == null || b == null) return a == b;
  if (a.length != b.length) return false;
  for (final entry in a.entries) {
    if (!b.containsKey(entry.key) || b[entry.key] != entry.value) return false;
  }
  return true;
}

/// Order-independent hash so two equal maps hash alike regardless of key insertion order. A
/// `null` map hashes to 0.
int mapHash(Map<String, Object?>? map) {
  if (map == null) return 0;
  var hash = 0;
  for (final entry in map.entries) {
    hash ^= Object.hash(entry.key, entry.value);
  }
  return hash;
}
