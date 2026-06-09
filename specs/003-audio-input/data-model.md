# Data Model — 003 Audio Input

**Date**: 2026-06-10 | **Branch**: `003-audio-input` | Builds on the as-built 002 model; nothing is reshaped.

## 1. Domain entities

### AudioInput *(new, transient — mirrors `ImageInput`)*

Pure-Dart value handed across the `GemmaService` seam for the duration of one `generate` call.

| Field | Type | Notes |
|---|---|---|
| `bytes` | `Uint8List` | WAV 16 kHz mono PCM16 file bytes, read just-in-time from the stored file |
| `mimeType` | `String?` | best-effort, `audio/wav` |

Never persisted, never retained between turns (Principle VIII). Duration is derivable:
`(bytes.length − 44) / 32000` seconds (PCM16 mono @16 kHz; 44-byte canonical WAV header).

### AudioAttachment *(new, persisted — mirrors `ImageAttachment`)*

| Field | Type | Notes |
|---|---|---|
| `path` | `String` | absolute app-private path under `<documents>/audio/` |
| `mimeType` | `String?` | `audio/wav` |

Bound to exactly one user message; removed with its conversation.

### PendingRecording *(new, composer-transient)*

Held by the recording/attachment controller; **path only, never decoded bytes**.

| Field | Type | Notes |
|---|---|---|
| `path` | `String` | recorder temp file (app cache); promoted via `AudioFileStore.persist` only at send |
| `mimeType` | `String?` | `audio/wav` |
| `durationMs` | `int` | reported by the recorder at stop; chip label + min/max validation |

### ChatTurn *(extended)*

`{isUser, text, ImageInput? image}` → gains `AudioInput? audio`. A user turn may carry **at most
one** of `image`/`audio` (spec Q3); assistant turns never carry media. History replay re-attaches
media so follow-ups keep referring to it (FR-016/FR-017).

### Message *(extended)*

Gains `AudioAttachment? audio` alongside the existing `ImageAttachment? image`. Invariant
(enforced in `appendUserMessage` and the controller): `image == null || audio == null`.

### ModelCapabilities *(unchanged shape — value flips)*

`audio` field already exists (default `false`). `ModelCatalog` now declares
`supportsAudio = true` for `gemma-4-e2b` (spike-verified) and builds
`ModelCapabilities(image: supportsImage, audio: supportsAudio)`.

### Audio capture constants *(new, data not UI)*

Single source of truth (e.g. `core/audio_constants.dart`, referenced by recorder config, store
guard, and controller validation):

| Constant | Value | Source |
|---|---|---|
| `sampleRateHz` | 16000 | model input contract (research R1/R2) |
| `channels` | 1 | model input contract |
| `encoding` | WAV / PCM16 | model input contract |
| `maxClipDuration` | 30 s | spec Q1 / research R3 |
| `minClipDuration` | 500 ms | spec FR-002 |
| `maxPersistedBytes` | 2 MiB | research R3 guard |

## 2. Schema migration — drift `schemaVersion` 2 → 3

`messages` table gains two **nullable** columns (additive only; v2 rows untouched):

```sql
ALTER TABLE messages ADD COLUMN audio_path TEXT NULL;
ALTER TABLE messages ADD COLUMN audio_mime_type TEXT NULL;
```

`AppDatabase`:

- `schemaVersion => 3`
- `onUpgrade`: preserve the existing `if (from < 2)` image block; append
  `if (from < 3) { addColumn(messages, messages.audioPath); addColumn(messages, messages.audioMimeType); }`
- `onCreate = m.createAll()` (fresh installs land on v3 directly); `beforeOpen` keeps
  `PRAGMA foreign_keys = ON`.
- Regenerate `app_database.g.dart` (`dart run build_runner build --delete-conflicting-outputs`).

**Migration test fidelity (002 audit I7 applied)**: the v2 seed is a real file DB created with raw
SQL at `user_version = 2` **including the `idx_messages_conversation` index**; assertions: old
rows survive byte-identical, new columns exist and default to NULL, foreign keys still enforced,
fresh-install round-trip works. No DAO edits expected — drift companions round-trip the new
columns after regeneration (002 precedent).

## 3. Files on disk

```
<app documents>/
├── models/   # 001 — the .litertlm
├── images/   # 002 — image attachments
└── audio/    # NEW — audio attachments, write-once names: <microsecondsSinceEpoch>_<seq>.wav
```

`AudioFileStore` (mirrors `ImageFileStore`): `persist(tempPath, {mimeType}) → storedPath` (copy at
**send only**; rejects empty, > `maxPersistedBytes`, throws `ArgumentError`); `readBytes(path)`
just-in-time for generate/replay; `deleteAll(paths)` idempotent. Extension derives from mimeType
via the shared helper (002 audit L5). Send-time guard catches `ArgumentError` **and**
`FileSystemException` (002 audit DF-2). Orphan window (crash between file write and row commit) is
accepted as in 002/R5; a future sweep remains out of scope.

`DriftConversationRepository.deleteConversation` collects `audioPath`s alongside `imagePath`s and
deletes both file sets **before** the cascading row delete.

## 4. State transitions

### Recording / attachment state machine (composer)

```
idle
 ├─ mic tap, permission granted ──────────────► recording(elapsed, amplitude)
 ├─ mic tap, denied-askable ─► request ─► granted ─► recording | denied ─► explainer ─► idle
 ├─ mic tap, permanentlyDenied/restricted ─► explainer(+settings) ─► idle
recording
 ├─ stop tap (≥ minClipDuration) ─────────────► previewing(PendingRecording)
 ├─ stop tap (< minClipDuration) ─► note "too short" ─► idle
 ├─ cap reached (auto-stop) ─► note "limit reached" ─► previewing
 ├─ discard tap ──────────────────────────────► idle (temp file deleted)
 ├─ backgrounded / audio-focus lost ─► stop; ≥min → previewing + note · <min → idle + note
previewing
 ├─ play/stop preview (AudioPreviewPlayer; stopped on any exit from previewing)
 ├─ remove ───────────────────────────────────► idle (temp file deleted)
 ├─ re-record ────────────────────────────────► recording (old temp replaced)
 ├─ image attached (Q3) ─► note "one attachment" ─► image pending, clip discarded
 ├─ model flips audio-incapable (GENUINELY loaded only — modelSessionReady guard) ─► idle + note
 ├─ send ─► AudioFileStore.persist ─► message row (audioPath) ─► idle
 └─ conversation switch ──────────────────────► idle (temp file deleted)
```

### Message send (audio-bearing)

`ChatController.send`: persist clip via `AudioFileStore` (failure → composer-inline "record
again" error, abort) → create conversation if needed (audio-only first message gets the fallback
title) → `appendUserMessage(text?, audio: AudioAttachment)` → assemble history (ContextAssembler
injects media via the id-keyed map — now `Map<int, ImageInput|AudioInput>` equivalents — staying
pure/no-I/O) → `generate(history, prompt, audio: AudioInput)` → stream deltas (first immediate,
then ≥100 ms throttle) → finalize `complete`/`stoppedPartial`. The M1 invariant is untouched:
each delta is written **before** the stop flag is honored.

### Kept-warm session fingerprint *(extended)*

`_TurnFingerprint` gains `audioByteLength` (role + text + imageByteLength + audioByteLength) —
write-once stored files ⇒ same path ⇒ same length ⇒ same clip, without retaining bytes. Any
stop/error/cancel/load still bumps the epoch and forces a full `clearHistory(replayHistory:)`
resync; replayed audio turns map to `Message.withAudio`/`audioOnly`.

## 5. Validation rules

| Rule | Where enforced |
|---|---|
| clip ≥ 500 ms | recording controller at stop (discard + note) |
| clip ≤ 30 s | recorder auto-stop at cap (keep + note) |
| persisted file ≤ 2 MiB, non-empty | `AudioFileStore.persist` (ArgumentError → "record again") |
| one attachment per message (audio XOR image) | attachment/recording controller (replace + note) + `appendUserMessage` assert |
| send requires text OR attachment | composer send-enable logic (unchanged rule, audio added) |
| audio passed only when `capabilities.audio` | `GemmaService.generate` throws `StateError` (caller gates first) |
| audio never in DB as bytes | schema has no BLOB column; files only |
