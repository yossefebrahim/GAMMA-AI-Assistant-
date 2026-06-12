# Data Model — 005 Memory

## 1. Domain entities

### Memory (new, immutable — `lib/domain/entities/memory.dart`)

| Field | Type | Rules |
|---|---|---|
| `id` | `int` | autoincrement PK; the id injected into the facts block and referenced by `forget_fact(id)` |
| `fact` | `String` | short canonical statement; non-empty after trim; **≤ 80 chars** (R4, validated on capture) |
| `category` | `MemoryCategory` enum: `identity` \| `work` \| `preferences` \| `other` | required; drives grouping in the block + settings |
| `createdAt` | `DateTime` | capture time |
| `updatedAt` | `DateTime` | refreshed on supersede/edit; the recency key for block ordering + cap |
| `active` | `bool` | soft-delete / supersede flag; only `active` facts are injected or listed (default true) |
| `sourceConversationId` | `int?` | the conversation it was captured in; `null` for manually-added facts or after the source conversation is deleted |

### MemoryCategory (new enum — ordered for block/screen rendering)

`identity`, `work`, `preferences`, `other` — fixed declaration order is the block + settings order.

### remember_fact / forget_fact ToolSpecs (added to `ToolRegistry`)

| Tool | Args schema (R9) | Kind | Handler |
|---|---|---|---|
| `remember_fact` | `{fact: string (required, maxLength 80), category: enum[identity,work,preferences,other] (required)}` | `stateChanging` | `MemoryRepository.upsert` |
| `forget_fact` | `{id: integer (required, minimum 1)}` | `stateChanging` | `MemoryRepository.softDeleteById` (id validated against active rows) |

`ToolRegistry` now exposes three views (registry-sanity test updated from "exactly four" to these
groupings): `deviceTools` (004's four), `memoryTools` (these two), `specs` (all six, for `byName`).

### App settings (existing — extended)

`AppSettings` gains `memoryEnabled` (`bool`, default **true** — Clarifications Q3). Persisted in the
single-row `app_settings` table, read/written like `themeMode`.

### Facts block (derived, not stored — `FactsBlockComposer` in `lib/core/`)

A pure function of the active facts + cap → the injected text. Format (the spike-measured compact
shape, ~8.7 tok/fact): a header line, then one line per category present, each listing its facts as
`#<id> <fact>` joined by `; `, ordered by category then `updatedAt` desc. Capped to ≤ 20 facts / ≤ 900
chars (oldest-first drop). Empty store → empty string → no block injected (no token cost).

```
known facts about the user (saved across chats):
identity — #1 name is Joe; #2 lives in Cairo, Egypt (GMT+2)
work — #4 builds Android apps with Flutter and Dart; #5 mobile developer
preferences — #8 prefers dark mode; #10 wants metric units
```

## 2. Database schema — drift v4 → v5 (additive only, house style)

New `memories` table + one new column on `app_settings`:

```sql
CREATE TABLE memories (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  fact TEXT NOT NULL,
  category TEXT NOT NULL,              -- MemoryCategory.name
  created_at TEXT NOT NULL,            -- ISO-8601 (house option storeDateTimeAsText)
  updated_at TEXT NOT NULL,
  active INTEGER NOT NULL DEFAULT 1,   -- bool; only active rows are injected/listed
  source_conversation_id INTEGER NULL REFERENCES conversations(id) ON DELETE SET NULL
);
CREATE INDEX idx_memories_active ON memories (active, category, updated_at);

ALTER TABLE app_settings ADD COLUMN memory_enabled INTEGER NOT NULL DEFAULT 1;  -- bool, default on
```

- v4 rows untouched; `app_settings`'s existing single row gets `memory_enabled = 1` by default. Fresh
  installs land on v5 via `onCreate`.
- **`ON DELETE SET NULL`** on `sourceConversationId`: deleting a conversation does NOT delete the
  facts captured in it (facts are durable, app-global, Clarifications Q1) — it only nulls provenance.
  (Contrast with messages, which cascade-delete with their conversation.)
- **Migration test** (house pattern): seed a real **v4 file DB** (with the v4 messages/tool columns +
  index), open at v5, assert old rows intact, `memory_enabled` defaulted true, a `memories`
  insert/readback round-trips, and the `ON DELETE SET NULL` fires on conversation delete.

## 3. Dedupe / supersede (R8) — `MemoryRepository.upsert`

```
upsert(fact, category, sourceConversationId):
  n = normalize(fact)                         # lowercase, strip punct, collapse ws, trim
  actives = active facts in `category`
  if ∃ a ∈ actives with normalize(a.fact) == n:        # exact restatement
      touch a.updatedAt; return UpsertResult.unchanged(a)
  if ∃ a ∈ actives with jaccard(words(n), words(a)) ≥ 0.5:   # near-dup / conflict
      a.fact = fact; a.updatedAt = now; return UpsertResult.superseded(a)
  insert new active fact; enforceCap(); return UpsertResult.created(new)
```

- `enforceCap()`: if active count > 20, deactivate the oldest `updatedAt` rows down to 20.
- `jaccard` is over normalized **content-word** sets (stop words dropped) — plain string overlap, NOT
  semantic similarity / embeddings (constitution boundary). Threshold ~0.5, tunable; conservative to
  avoid false merges; always user-correctable in settings.
- The chip summary reflects the `UpsertResult` (`remembered …` / `updated …`), so the user sees a
  supersede as an update, not a new capture.

`forget_fact(id)`: `softDeleteById(id)` sets `active=false` iff an active row with that id exists;
returns whether it did. The dispatcher maps `false` → `ToolFailure('no such fact: <id>')` (spike: the
model guesses ids; never fuzzy-delete). Integer `id` arriving as a double is coerced (004 dispatcher).

## 4. Injection & session lifecycle (R1/R2/R3)

```
loadModel(model):                      # app start / model reload / backend switch
  systemInstruction = SystemInstructionComposer.compose(
      factsBlock: memoryEnabled ? FactsBlockComposer(activeFacts) : null,
      memoryCapture: functionCalling && memoryEnabled,
      deviceTools:  functionCalling)
  createChat(tools: declaredTools, systemInstruction: systemInstruction, …)

openConversation(id) | toggleMemory():  # a "session boundary" (FR-008/FR-017)
  recompose systemInstruction from CURRENT memory + flags
  gemma.startSession(systemInstruction:)   # close session → createChat (no model reload)

send(...) each turn:                    # systemInstruction is FIXED for the conversation
  generate(history, prompt)             # no per-call instruction → facts can't change mid-chat
```

- `declaredTools` = `deviceTools` (if functionCalling) + `memoryTools` (if functionCalling &&
  memoryEnabled) (R6). The seam's structural coupling + `StateError` gate (004 guarantee 18) extends
  to the memory tools unchanged.
- **`SystemInstructionComposer.compose(...) == null`** when memory is empty/off AND functionCalling is
  off → byte-parity with 003/004 flag-off (guarantee 19 preserved; dedicated parity test).
- `ContextAssembler` reserves `memoryReserveTokens` (~225 block + ~86 capture instruction when both
  active) off the 1536 budget, alongside the existing 40-token device-tool reserve.

## 5. Memory tool turns (reuse 004 — no schema change beyond the tools)

`remember_fact`/`forget_fact` calls flow through the EXISTING 004 controller tool-turn state machine
and persist as `role='tool'` message rows (`toolName`/`toolArgs`/`toolStatus`/`toolResult`) — rendered
by the existing `ToolChip`. No new message kind. Chip states:

| Outcome | Chip |
|---|---|
| remember success (created) | `TOOL · REMEMBER_FACT` + `remembered: <fact>` |
| remember success (superseded) | `… · updated: <fact>` (reflects dedupe, §3) |
| remember success (unchanged) | `… · noted: <fact>` (exact restatement — no new row, `updatedAt` refreshed, §3) |
| forget success | `TOOL · FORGET_FACT` + `forgot #<id>` |
| invalid args / unknown id / cap / disabled | error chip (sanctioned red) + honest reply |

Memory chips render in reopened history regardless of the active model's capability (FR-019),
identically to 004 device-tool chips.

## 6. Providers (Riverpod) — additive

- `memoryRepositoryProvider` (over the drift DB; in-memory in tests).
- `activeMemoriesProvider` (stream of active facts, grouped — drives the settings screen + composition).
- `memoryEnabledProvider` (Notifier over `app_settings.memoryEnabled`, like `themeModeProvider`).
- `toolHandlersProvider` (existing) gains `remember_fact`/`forget_fact` handlers bound to the repo.
- The session provider composes `declaredTools` + the `SystemInstructionComposer` output and passes
  them to `loadModel`/`startSession`.
