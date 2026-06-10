# Contract — ConversationRepository tool extensions (004)

Extends the 001/002/003 repository contract (`lib/domain/repositories/` +
`lib/data/repositories/drift_conversation_repository.dart`). Storage details in
[data-model.md](../data-model.md) §2–3.

## Interface deltas

```dart
// NEW — insert a tool invocation row (toolStatus: running) at the next sequence.
Future<int> appendToolInvocation({
  required int conversationId,
  required String toolName,
  required Map<String, Object?> args,
});

// NEW — finalize the invocation to a terminal state (success | error | skipped),
// attaching the bounded result/error payload and the chip's one-line summary.
Future<void> finalizeToolInvocation(
  int messageId, {
  required ToolCallStatus status,   // terminal states only — `running` is rejected
  Map<String, Object?>? result,
  required String summary,          // lowercase chip line (display only)
});
```

`watchMessages` is unchanged — tool rows flow through the existing reactive stream and render as
chips by `role == tool`.

## Guarantees (continues the house numbering)

- **Field invariants** (mirrors the 003 attachment XOR): tool fields all-null on user/assistant
  rows; `toolName`+`toolStatus` non-null on tool rows; tool rows never carry `imagePath`/
  `audioPath`; violations throw `ArgumentError` at the repository boundary (state-free,
  unit-testable without a device).
- **Terminal-state writes only**: `finalizeToolInvocation` rejects `running`; the
  startup/open sweep finalizes any stale `running` row to `error('interrupted')` — reopened
  history never shows an in-flight chip (data-model §4).
- **Sequence integrity**: tool rows take the conversation's next monotonic `sequence` like any
  message; the controller's ordering rule (user → optional text → chip → answer) is achieved by
  insertion order, not sequence rewrites.
- **Result bound enforced at write**: `toolResult` JSON > 2,000 chars is rejected (the
  dispatcher truncates first — this is the belt-and-braces check).
- **Cascade**: conversation delete removes tool rows via the existing FK cascade; nothing
  tool-specific to clean (no files).
- **Replay mapping**: the repository exposes tool rows to the context assembler with enough
  data (`toolName`, `toolArgs`, `toolResult`, `toolStatus`) to reconstruct the plugin replay
  pair (data-model §3); `skipped`/`error` rows replay with `{error: …}` payloads.
- **Migration**: v3 → v4 is additive-only; v3 rows read back unchanged with NULL tool fields
  (seeded-file migration test, house pattern).
