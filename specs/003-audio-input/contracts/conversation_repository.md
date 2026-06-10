# Contract — ConversationRepository audio extensions (003)

Extends the as-built 001/002 contract; image behavior is unchanged.

## Interface deltas

```dart
Future<Message> appendUserMessage(
  int conversationId,
  String text, {
  ImageAttachment? image,   // 002
  AudioAttachment? audio,   // NEW — at most one of image/audio may be non-null (asserted)
});
// watchMessages / loadTurns now also repopulate Message.audio from the columns
```

## Guarantees

1. **Validation**: a user message requires non-empty text OR an attachment; `image != null &&
   audio != null` is rejected (spec Q3). An audio-only first message receives the fallback
   conversation title (002 image-only precedent).
2. **Round-trip**: `audioPath`/`audioMimeType` persist with the row and are rehydrated into
   `Message.audio` by every read path, so history renders the chip independent of the
   currently-active model's capabilities (FR-018) and across restarts (FR-019).
3. **Delete cleans files**: `deleteConversation` collects the conversation's `audioPath`s (and
   `imagePath`s, as today) and calls the file stores' `deleteAll` **before** the cascading row
   delete — after the cascade the paths are unknowable. No per-message delete exists; the
   crash-window orphan remains accepted (002 R5/I3) and out of scope.
4. **Migration**: rows written at v2 (or v1) are readable unchanged at v3; the new columns are
   NULL for them. See [data-model.md](../data-model.md) §2 for the migration contract and the
   index-faithful seed requirement (002 audit I7).
5. **No bytes in the DB**: the repository never reads or writes audio bytes — only paths/metadata.
   Byte I/O belongs to `AudioFileStore` (persist at send, `readBytes` at context assembly).

## Test double / harness

In-memory drift (`NativeDatabase.memory()`) repository tests cover: audio round-trip,
audio XOR image validation, audio-only fallback title, delete-cleans-audio-files (temp-dir file
store), and the v2→v3 migration test against a real seeded file DB.
