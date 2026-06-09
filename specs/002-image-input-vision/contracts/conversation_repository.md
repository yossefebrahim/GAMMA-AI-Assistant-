# Contract: ConversationRepository — image extensions

**Feature**: `002-image-input-vision` | FR-012, FR-017, FR-018, FR-019 | Principle VII

Extends the 001 `ConversationRepository`
([001 contract](../../001-model-download-chat/contracts/conversation_repository.md)) to persist an
optional image on a user message and to clean up image files on delete. `DriftConversationRepository`
(in `lib/data/repositories/`) wires drift + the new `ImageFileStore`. Only deltas shown.

## Interface deltas

```dart
abstract interface class ConversationRepository {
  // ...unchanged: watchConversations, watchMessages, createConversation,
  //    beginAssistantMessage, updateAssistantContent, finalizeAssistantMessage, loadTurns...

  /// Append a user message, optionally with an image (FR-012). Validates that the message has
  /// non-empty text OR an image (FR-004). When [image] is given, its bytes have already been
  /// persisted to app-private storage by the caller (ImageFileStore) and [image].path is the
  /// STORED path. Bumps updatedAt; sets the title from the first message's text if still null
  /// (falls back to a label for an image-only first message).
  Future<Message> appendUserMessage(
    int conversationId,
    String text, {
    ImageAttachment? image,        // NEW
  });

  /// Delete a conversation, cascade its messages, AND delete its image files (FR-019).
  Future<void> deleteConversation(int conversationId);   // behavior extended
}
```

`watchMessages` / `loadTurns` now return `Message`s whose `image` field is populated from the
`imagePath` / `imageMimeType` columns (FR-017/FR-018).

## ImageFileStore (supporting type, `lib/data/images/`)

```dart
class ImageFileStore {
  Future<String> persist(String tempPath, {String? extension});  // copy → app-private images/, return stored path
  Future<Uint8List> readBytes(String storedPath);                // just-in-time read for generate/replay
  Future<void> deleteAll(Iterable<String> storedPaths);          // remove files on conversation delete
}
```

## Semantics & guarantees (additions)

| # | Behavior | Source |
|---|----------|--------|
| 8 | `appendUserMessage` accepts text-only, image-only, or text+image; rejects empty/empty. | FR-004 |
| 9 | Image stored as an app-private file; only its path is written to the DB. | R5, FR-024 |
| 10 | Restored `Message`s carry their image (path → file) so history shows it in place. | FR-017/FR-018, SC-004/SC-005 |
| 11 | `deleteConversation` deletes the conversation's image files, then the row (messages cascade). | FR-019 |
| 12 | An image-only first message uses a fallback title (text title derivation unchanged otherwise). | FR-021-equivalent (001) |
| 13 | All reads/writes are app-private, OS-encrypted, no network. | FR-022/FR-024, Principle I |

## Schema / migration (see [data-model.md](../data-model.md))

- `messages.imagePath TEXT NULL`, `messages.imageMimeType TEXT NULL`; `schemaVersion 1 → 2` with
  `onUpgrade` `addColumn`. New columns nullable → existing text conversations valid (FR-017).

## Test strategy

- **Migration test**: seed a v1 `NativeDatabase.memory()`, open at v2, assert old rows survive and
  the new columns exist (R5).
- **Repository tests**: real drift in-memory + a temp-dir `ImageFileStore` — persist a message with
  an image, read it back (path populated), delete the conversation and assert the file is gone
  (FR-019). User-message validation (text/image/empty) per FR-004.
- **Controller tests**: a `FakeConversationRepository` + `FakeGemmaService` drive chat/attachment
  controllers deterministically.
