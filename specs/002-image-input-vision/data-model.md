# Data Model: Image Input — Visual Understanding

**Feature**: `002-image-input-vision` | **Date**: 2026-06-08

Extends the 001 data model. Only the **deltas** are described here; everything not mentioned is
unchanged from [001 data-model.md](../001-model-download-chat/data-model.md). Image **bytes** are
stored as app-private files (OS-encrypted, FR-024); the database holds only a **path** to the file.
Domain entities stay pure Dart (no Flutter, no flutter_gemma) so they unit-test without the plugin.

## Entity overview (changes)

| Entity | Persisted? | Change |
|--------|-----------|--------|
| Message | Yes (`messages` table) | **+ optional image** (`imagePath`, `imageMimeType`) |
| ImageAttachment | Yes (as a file + the two `messages` columns) | **NEW** — a persisted image bound to one message |
| ImageInput | No (transient) | **NEW** — image bytes handed to the `GemmaService` seam |
| PendingAttachment | No (transient) | **NEW** — the previewed-but-unsent image in the composer |
| ChatTurn | No (transient) | **+ optional image** so follow-ups replay the image as context |
| ModelCapabilities | No (transient) | unchanged shape; `image` now sourced from catalog data (R1) |

Conversation, ModelInstall, AppSettings, DeviceCapability are **unchanged**.

---

## Message (extended)

One turn within a conversation. A **user** turn MAY now carry one image; assistant turns never do.

| Field | Type | Rules |
|-------|------|-------|
| `id`, `conversationId`, `role`, `content`, `sequence`, `createdAt`, `status` | — | **unchanged** (see 001) |
| `image` | `ImageAttachment?` | NEW. Non-null only on user turns that included an image. Maps to the `imagePath` + `imageMimeType` columns. |

- Validation: send is allowed when `content` is non-empty after trim **OR** `image != null`
  (FR-004) — this relaxes the old "non-empty text required" rule for user turns that carry an image.
- `content` may be empty when `image != null` (image-only message).
- `copyWith`/equality/hashCode extended to include `image`.

## ImageAttachment (new, persisted)

A single image bound to exactly one message.

| Field | Type | Rules |
|-------|------|-------|
| `path` | String | Absolute app-private path under `…/images/`; the stored copy (not the picker temp file). |
| `mimeType` | String? | e.g. `image/jpeg`; best-effort, for rendering/debugging. |

- 1:0..1 with Message (a message has zero or one image — FR-002, single image).
- Lifecycle tied to its message's conversation: deleted when the conversation is deleted (FR-019).

## ImageInput (new, transient)

The bytes handed across the `GemmaService` seam for the current prompt and for replayed history
turns. Pure Dart (`dart:typed_data`), never persisted.

| Field | Type | Rules |
|-------|------|-------|
| `bytes` | `Uint8List` | Raw image bytes read just-in-time from the stored file. |
| `mimeType` | String? | Optional hint. |

- Held only for the duration of a `generate` call; not retained between turns (Principle VIII).

## PendingAttachment (new, transient — composer state)

The previewed-but-unsent image in the message composer.

| Field | Type | Rules |
|-------|------|-------|
| `path` | String | The picker's temp-file path (copied into app-private storage on send). |
| `mimeType` | String? | From the picker. |

- At most one at a time (FR-002); picking another **replaces** it (FR-003).
- Cleared on: remove (FR-003), successful send, conversation switch, or switching to a model that
  cannot take images (FR-008).

## ChatTurn (extended, transient)

| Field | Type | Rules |
|-------|------|-------|
| `isUser`, `text` | — | unchanged |
| `image` | `ImageInput?` | NEW. Carries a prior turn's image so the seam can replay it for follow-ups (FR-015/FR-016). |

---

## drift schema delta (v1 → v2)

```text
messages(
  id PK, conversationId INT FK→conversations.id ON DELETE CASCADE,
  role TEXT, content TEXT, sequence INT, createdAt DATETIME, status TEXT,
  imagePath TEXT NULL,        -- NEW (v2)
  imageMimeType TEXT NULL     -- NEW (v2)
)
```

- `schemaVersion`: **1 → 2**.
- `MigrationStrategy.onUpgrade(from, to)`: `if (from < 2) { m.addColumn(messages, messages.imagePath);
  m.addColumn(messages, messages.imageMimeType); }`. New columns are nullable, so existing rows are
  valid with `NULL` (existing text conversations are untouched — FR-017).
- `beforeOpen` keeps `PRAGMA foreign_keys = ON`. `onCreate = m.createAll()` (fresh installs get v2
  directly).
- Regenerate `app_database.g.dart` (build_runner) after the table change.
- A **v1→v2 migration test** seeds a v1 DB, opens at v2, and asserts data survives and the columns
  exist (R5).

## File storage layout

```text
<app documents>/
├── models/        # (001) the model artifact
└── images/        # (NEW) one file per sent image, e.g. <millisSinceEpoch>_<seq>.jpg
```

- `ImageFileStore.persist(tempPath) -> storedPath`: copies the picker temp file into `images/` with a
  unique name; returns the absolute stored path.
- `ImageFileStore.readBytes(path) -> Uint8List`: just-in-time read for `generate`/replay.
- `ImageFileStore.delete(paths)`: removes files when their conversation is deleted.

---

## State machines (deltas)

### Attachment lifecycle (composer) — FR-001…FR-004, FR-008

```text
none ──(tap attach)──▶ choosingSource         [camera | library]
choosingSource ──(permission needed & denied)──▶ permissionExplainer ──(grant/settings)──▶ choosingSource
choosingSource ──(pick ok)──▶ previewing(pendingAttachment)
choosingSource ──(cancel)──▶ none
previewing ──(remove)──▶ none
previewing ──(pick another)──▶ previewing(new)           [replace, single image — FR-002]
previewing ──(switch to text-only model)──▶ none         [cleared + note — FR-008]
previewing ──(send)──▶ persist file + message ──▶ none
```

### Message generation with an image — FR-012…FR-016, FR-020

```text
idle ──(send; text non-empty OR image present)──▶
   persist user msg (content, imagePath?) ──▶ create assistant msg (streaming) ──▶ generating
generating: GemmaService.generate(history[with prior image turns], prompt, image: thisTurnImage?)
   append TextResponse deltas                       [send disabled, stop shown]
generating ──(stream done)──▶ assistant → complete ──▶ idle
generating ──(stop, FR-014)──▶ stopGeneration + cancel ──▶ assistant → stoppedPartial (retain) ──▶ idle
generating ──(ImageProcessingException / load/OOM, FR-020)──▶
   finalize assistant turn cleanly + show "couldn't process this image" ──▶ idle   [no hang/crash]
```

- Single in-flight generation unchanged (Q4): `isGenerating` guards new sends.
- Context assembly (FR-015/FR-016): prior turns include any image turn; the assembler keeps the
  image on its `ChatTurn`; the controller reads bytes just-in-time and the seam replays it. Sliding
  window still trims **oldest** turns on overflow (stored history untouched).

### Capability gate (model switch) — FR-005…FR-008

```text
modelLoaded(caps.image == true)  ──▶ composer shows attach control
modelLoaded(caps.image == false) ──▶ composer hides attach control; text chat normal
switch model ──▶ capabilities re-read (data) ──▶ control shown/hidden live (no restart)
switch to text-only WHILE previewing ──▶ pending image cleared + note (FR-008)
already-sent images ──▶ still rendered in history regardless of active model (FR-017)
```

---

## Validation rules (traceability — additions)

| Rule | Source |
|------|--------|
| At most one image per message; picking another replaces it | FR-002 |
| Send allowed when image present even with empty text | FR-004 |
| Attach control shown iff `ModelCapabilities.image` (data) | FR-005/FR-006, Principle III |
| Control updates live on model switch; pending image cleared if new model can't take it | FR-007/FR-008 |
| Prior image included in assembled context for follow-ups | FR-015/FR-016 |
| Already-sent images remain in history after switching to text-only model | FR-017 |
| Image conversations persist across restart (file + path row) | FR-018, SC-005 |
| Deleting a conversation deletes its image files (no orphans) | FR-019 |
| Unprocessable/oversized/corrupt image → clear message, no crash | FR-020/FR-021, SC-008 |
| Image bytes never leave the device; all storage app-private | FR-022/FR-024, Principle I |
| New columns nullable; v1 data survives the v2 migration | FR-017, R5 |
