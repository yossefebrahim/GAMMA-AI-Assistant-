# Data Model: Model Download & Chat

**Feature**: `001-model-download-chat` | **Date**: 2026-06-07

Derived from the spec's Key Entities and Functional Requirements. Persisted entities live in an
app-private `drift` SQLite database (OS-encrypted, FR-032); transient entities are in-memory value
objects. The domain entities are pure Dart (no Flutter, no flutter_gemma) so they unit-test
without the native plugin.

## Entity overview

| Entity | Persisted? | Backing store |
|--------|-----------|---------------|
| Conversation | Yes | `conversations` table |
| Message | Yes | `messages` table |
| ModelInstall | Yes (single row) | `model_install` table (+ the model file on disk) |
| AppSettings (theme, license-ack) | Yes (single row) | `app_settings` table |
| DeviceCapability | No (transient) | computed at preflight |

---

## Conversation

A single chat thread (FR-018, FR-019, FR-020, FR-021).

| Field | Type | Rules |
|-------|------|-------|
| `id` | int (PK, autoincrement) | immutable identity |
| `title` | text, nullable | derived from first user message, trimmed to ≤ 40 chars (FR-021); `null` until first message, then a fallback label (e.g. `"untitled"`) if the first message is empty after trimming |
| `createdAt` | datetime (UTC) | set on creation |
| `updatedAt` | datetime (UTC) | bumped on every new/changed message; **primary sort key** for the history list (most-recent first) |

- Relationship: one Conversation has many Messages (1‑N), `ON DELETE CASCADE` (FR-022 — deleting
  a conversation removes its messages so they are no longer retrievable).
- Reactive: the history list is a `watch()` query ordered by `updatedAt DESC` (R3) so it updates
  live on create/delete/new-message.

## Message

One turn within a conversation (FR-012, FR-013, FR-014, FR-017).

| Field | Type | Rules |
|-------|------|-------|
| `id` | int (PK, autoincrement) | immutable identity |
| `conversationId` | int (FK → conversations.id) | `ON DELETE CASCADE` |
| `role` | text enum: `user` \| `assistant` | required |
| `content` | text | user: non-empty after trim (FR — empty send prevented); assistant: may be empty only transiently while generating |
| `sequence` | int | monotonic per conversation; defines turn order |
| `createdAt` | datetime (UTC) | set on creation |
| `status` | text enum: `complete` \| `streaming` \| `stoppedPartial` | assistant turns only; user turns are always `complete` |

- `status` semantics:
  - `streaming` — assistant turn currently being generated; `content` grows as deltas arrive.
  - `complete` — generation finished normally.
  - `stoppedPartial` — user pressed stop; `content` retains all text produced up to that instant
    (FR-014) and is treated as a completed turn for context assembly (FR-017).
- Ordering: `(conversationId, sequence)` is the read order; index on `conversationId`.

## ModelInstall

Tracks the single default model (FR-009, FR-010, FR-030). One row.

| Field | Type | Rules |
|-------|------|-------|
| `id` | text (PK) | constant model id, e.g. `gemma-4-e2b` |
| `state` | text enum: `notInstalled` \| `downloading` \| `installed` | see state machine |
| `filePath` | text, nullable | absolute app-private path to the verified `.litertlm`; `null` unless `installed` |
| `sizeBytes` | int, nullable | on-disk size, shown to the user (FR-030) |
| `installedAt` | datetime (UTC), nullable | set on successful install |

- The authoritative "is the model usable" check = `state == installed` AND `filePath` exists on
  disk. A `*.part` file is never recorded here (R2 atomic rename).
- Capabilities are **not** stored here — they are read live from `GemmaService.capabilities`
  (Principle III: capabilities are data from the active model, not persisted config).

## AppSettings

Single-row app preferences.

| Field | Type | Rules |
|-------|------|-------|
| `id` | int (PK, constant = 1) | single row |
| `themeMode` | text enum: `dark` \| `light` \| `system` | default `dark` (FR-023); persisted (FR-024) |
| `licenseAcknowledgedAt` | datetime (UTC), nullable | set when the user accepts the one-time model license (clarification Q1); gates the download |

## DeviceCapability (transient value object)

Computed at preflight (FR-003, FR-004, FR-005); never persisted.

| Field | Type | Meaning |
|-------|------|---------|
| `ramMb` | int | `device_info_plus` `physicalRamSize` (MB) |
| `abis` | List<String> | `supportedAbis` |
| `meetsRamBaseline` | bool | `ramMb >= 7000` (R4 — real 8 GB devices report ~7400–7700 MB) |
| `supportsArm64` | bool | `abis.contains('arm64-v8a')` |
| `isEligible` | bool | `meetsRamBaseline && supportsArm64` |
| `ineligibleReason` | enum?: `insufficientMemory` \| `unsupportedAbi` \| `null` | drives the honest message (FR-004/FR-006) |

---

## drift schema sketch

```text
conversations(id PK, title TEXT?, createdAt DATETIME, updatedAt DATETIME)
messages(id PK, conversationId INT FK→conversations.id ON DELETE CASCADE,
         role TEXT, content TEXT, sequence INT, createdAt DATETIME, status TEXT)
  index: idx_messages_conversation (conversationId, sequence)
model_install(id TEXT PK, state TEXT, filePath TEXT?, sizeBytes INT?, installedAt DATETIME?)
app_settings(id INT PK = 1, themeMode TEXT, licenseAcknowledgedAt DATETIME?)
```

- `PRAGMA foreign_keys = ON` so the cascade fires.
- `schemaVersion = 1`; `MigrationStrategy.onCreate = m.createAll()` (R3).
- Reactive queries: `watchConversationsByUpdatedAtDesc()`, `watchMessages(conversationId)`.

---

## State machines

### Onboarding → install (FR-001…FR-011)

```text
firstRun ──▶ welcome (privacy explainer)
welcome ──(start)──▶ licenseAck ──(accept)──▶ preflight
preflight ──(ineligible)──▶ blocked  [honest reason; no download — terminal for this device]
preflight ──(eligible)────▶ readyToDownload
readyToDownload ──(download)──▶ downloading
downloading ──(cancel)──▶ readyToDownload     [partial .part discarded]
downloading ──(fail/interrupt)──▶ downloadError ──(retry)──▶ downloading
downloading ──(complete)──▶ verifying ──(ok)──▶ installed ──▶ chat
verifying ──(bad)──▶ downloadError
installed ──(deleteModel FR-030)──▶ readyToDownload   [file removed, space reclaimed]
```

`ModelInstall.state` mirrors: `notInstalled` (welcome…readyToDownload), `downloading`
(downloading/verifying), `installed`.

### Message generation (FR-012…FR-017, Q4)

```text
idle ──(send, input non-empty)──▶ persist user msg (complete)
   ──▶ create assistant msg (streaming) ──▶ generating
generating: append TextResponse deltas to assistant.content   [send disabled, stop shown — Q4]
generating ──(stream done)──▶ assistant msg → complete ──▶ idle
generating ──(stop, FR-014)──▶ stopGeneration + cancel subscription
   ──▶ assistant msg → stoppedPartial (retain text) ──▶ idle
```

- Only one generation in flight (Q4): an `isGenerating` guard blocks new sends; the composer's
  send action is replaced by the stop control while `generating` (FR-012).
- Context assembly (FR-017): build the model prompt from the conversation's turns in order,
  including any `stoppedPartial` assistant turn; if the assembled context exceeds the model's
  window, drop oldest turns (sliding window, Q2) — stored history is untouched.

### Model resource lifecycle (FR-029, Principle VIII)

```text
notLoaded ──(enter chat / model installed)──▶ loading ──▶ loaded(active, exactly one)
loaded ──(leave chat screen)──▶ releasing ──▶ notLoaded   [chat.close() + model.close()]
loaded ──(app backgrounded)──▶ releasing ──▶ notLoaded     [AppLifecycleListener, R5]
* loading a new model MUST release the current one first (single active model)
* persisted conversation data is never lost on release
```

---

## Validation rules (traceability)

| Rule | Source |
|------|--------|
| User message non-empty after trim before send | Edge Cases (empty/whitespace) |
| Assistant `stoppedPartial` retains 100% of produced text | FR-014, SC-005 |
| Conversation `title` ≤ 40 chars, fallback when empty | FR-021 |
| Delete conversation cascades to messages | FR-022 |
| Context = ordered turns incl. stopped-partial; sliding window on overflow | FR-017, Q2 |
| Only `installed` + on-disk file counts as usable model | FR-009/FR-010, R2 |
| Theme defaults to dark, persisted | FR-023, FR-024 |
| `isEligible` requires RAM ≥ 7000 MB and arm64-v8a | FR-003, R4 |
| All persisted data in app-private OS-encrypted storage | FR-032 |
