# Research — 005 Memory (decisions & pinned choices)

All plugin-behavior claims are grounded in the Phase 0 spike
([spike-findings.md](spike-findings.md)) — source-inspected on `flutter_gemma 0.15.3` and confirmed
empirically on the A34. No new packages are introduced (Principle I/IX: SQLite only — no embeddings,
no vector store, no network).

## R1 — Facts-block injection: native `systemInstruction`, recreated per session

**Decision**: inject the facts block as the chat's **`systemInstruction`** (the native LiteRT-LM
`systemMessage` on our FFI path), composed at chat creation, NOT prepended to a user turn and NOT
appended to replay history.

Evidence (spike §1): on Android + `.litertlm` + `ModelType.gemma4` → FFI, `createChat(systemInstruction:)`
→ `createSession(systemInstruction:)` → `ffiClient.createConversation(systemMessage:)` — a true
system message rendered by Gemma 4's chat template. The `[System: …]` first-user-turn prepend exists
ONLY on the MediaPipe/web fallback, which our path never takes. On-device confirmation: planted facts
grounded "what's my name/where do I live/what pet" correctly, refused to fabricate an absent fact, and
**survived `clearHistory()` session recreation**.

**Lifetime**: `systemInstruction` is captured in the `sessionCreator` closure at `createChat` and is
immutable for the chat's lifetime; `clearHistory({replayHistory})` does `session.close()` then
`sessionCreator()` (chat.dart:574-575), re-applying the SAME instruction on every per-send replay.
To change the block you must recreate the **chat** (new `createChat`). **FFI caveat**: a second
`createChat` on the same model returns the cached native session unless the prior session is closed
first — the seam MUST `await chat.session.close()` before recreating with a new instruction.

**Alternatives considered**: facts as a leading replay turn (re-injected every send → leaks new facts
mid-chat via the warm path; not a system message); facts baked only at `loadModel` (too coarse — a new
conversation in the same chat-screen visit wouldn't see facts saved moments earlier; model reload is
~7-9 s and re-mmaps 2.4 GB). Rejected in favor of a cheap chat recreation at session boundaries (R2).

## R2 — Session boundary = chat recreation via a new seam method `startSession`

**Decision**: add `GemmaService.startSession({String? systemInstruction})` — recreates the chat
(close session → `createChat` with the same loaded model, tools, and capabilities, but the given
`systemInstruction`) WITHOUT reloading the model. The controller calls it when a conversation is
opened (the "next session" boundary, spec FR-008) and when the memory toggle flips. `generate` is
unchanged and takes NO per-call instruction, so a fact captured mid-conversation does NOT mutate the
running chat (FR-008) — it surfaces when the next conversation's `startSession` recomposes the block.

**Cost**: `createConversation` is ~ms (spike perf log); a NEW conversation has no history to
re-prefill, so the refresh is effectively free. Reopening an existing conversation re-prefills its
history on the next send anyway (today's not-warm path), so `startSession` adds no new cost there. The
seam resets its warm fingerprints on `startSession` (correctness over the optimization).

**Snapshot semantics**: the controller composes the instruction ONCE per session boundary (open /
toggle), never per send — this is what makes "facts apply from the next session, not retroactively
mid-chat" structural rather than best-effort. Fact edits/deletes (FR-017) apply at the next open;
the toggle applies promptly via an explicit `startSession` (a deliberate user action, the one mid-
screen exception).

## R3 — System-instruction composition (pure, byte-parity preserving)

**Decision**: a pure `SystemInstructionComposer` (in `lib/core/`) builds the final instruction from
three optional parts, joined with blank lines, in order:

1. **Facts block** — when memory is enabled AND ≥1 active fact (regardless of `functionCalling`, R6 /
   FR-009).
2. **Memory capture instruction** — when `functionCalling` AND memory enabled (the reliability lever,
   R5).
3. **Device tool-use instruction** (the existing 004 `ToolRegistry.systemInstruction`) — when
   `functionCalling`.

Returns `null` when all three are empty. **Byte-parity guarantee preserved**: a text-only model with
memory empty/off → `null` (byte-identical to 003/004 flag-off). The seam's `loadModel`/`startSession`
forward this composed string; the seam no longer hardcodes `ToolRegistry.systemInstruction` (that
literal moves into the composer). Pure → unit-tested for every flag combination.

**Token reserve**: `ContextAssembler` already reserves the 40-token device tool instruction; it gains
a `memoryReserveTokens` (block cap ~225 + capture instruction ~86 ≈ **~311 tokens** when both active)
subtracted off the 1536 budget so a long history can't crowd out the facts (R4).

## R4 — Cap & token budget (measured, native tokenizer)

**Decision**: cap = **≤ 20 active facts**, **per-fact ≤ 80 chars** (validated on capture), assembled
**facts block ≤ 900 chars (~225 tokens)** with overflow dropped **oldest-first** (block is ordered
category-then-recency, so the cap trims least-recent). Reserve ~311 tokens off the context budget when
memory + tools are both active.

Backed by spike §2 native `sizeInTokens`: compact category-grouped format costs ~8.7 tokens/fact (20
facts = 174 tokens; +capture instruction 86 = 260 ≈ 17% of the 1536 budget). The 900-char/225-token
block cap bounds the worst case to ≤ ~20% of the budget, leaving ≥ ~1225 tokens for conversation.

**Per-fact length** as the arg-validation bound keeps facts "canonical" (spike captures were all ≤ ~55
chars) and is enforced by the schema validator (`maxLength` — see R8) so an over-long fact is a visible
validation error, not a silent truncation.

## R5 — Capture reliability lever: the memory system instruction

**Decision**: when capture is active, prepend a short lowercase capture instruction naming the
durable-fact contract AND explicitly the instruction-shaped preferences the spike under-captured:

> "you remember the user across chats. when the user shares a durable fact about themselves — their
> name, where they live, their job, or a lasting preference about how you should respond (tone, units,
> formatting) — call remember_fact with a short third-person statement and a category. don't save
> questions, one-off tasks, weather, math, or trivia."

Rationale: the spike's 4 misses (80% capture) were all instruction-shaped preferences ("use metric
units", "address me formally") the model chose to obey rather than save; naming that class is the
cheapest lever to clear SC-001 with margin. Exact wording tuned on-device against the quickstart suite.
~86 tokens (spike §2). `ToolChoice.auto` (never `required` — the spike's 0 false positives depend on
auto).

## R6 — Capability gating: capture gated, injection + management NOT gated

**Decision**: the `remember_fact`/`forget_fact` tools are declared ONLY when `functionCalling` is on
AND memory is enabled — same structural coupling + seam-side `StateError` as 004 (the silent-trap
rule). Facts-block **injection** and the **settings management screen** are independent of
`functionCalling` (FR-009/FR-016): a text-only model still gets injected facts, and management always
works. The current catalog's single model declares `functionCalling`, so capture is available by
default; this split is forward-looking and matches the user's "manual management works regardless."

**Declared-tool composition**: `ToolRegistry` splits into `deviceTools` (004's four) + `memoryTools`
(the two). The session provider composes the declared list = `deviceTools` (if `functionCalling`) +
`memoryTools` (if `functionCalling` && memoryEnabled). The dispatcher's handler map covers exactly the
declared names (congruence sanity test, now spanning ≤ 6 tools).

## R7 — Persistence: a `memories` table + drift v4 → v5 (additive, house style)

**Decision**: a new `memories` table and a `memoryEnabled` flag on `app_settings`, via an additive
`m.createTable` + `m.addColumn` migration (house pattern: 1→2 image, 2→3 audio, 3→4 tools, now
**4→5 memory**). v4 rows untouched; fresh installs land on v5 via `onCreate`.

`memories`: `id` (autoinc PK), `fact` (TEXT), `category` (TEXT — enum name), `createdAt`, `updatedAt`
(DateTime as ISO-8601 TEXT, house option), `active` (BOOL, default true — soft-delete/supersede),
`sourceConversationId` (INT NULL, FK → conversations `ON DELETE SET NULL` — deleting a conversation
keeps its facts but nulls the provenance). Index `(active, category, updatedAt)` for the screen +
injection query. `app_settings.memoryEnabled` (BOOL, default true).

**Alternatives**: storing facts inside the settings blob (no querying/dedupe); a join table to
conversations (facts are first-class, not per-conversation — Clarifications Q1); hard-delete on forget
(soft-delete keeps supersede auditable and clear-all simple, and `active=false` rows are never injected
or listed).

## R8 — Dedupe / supersede: deterministic, on-device, no embeddings (FR-003)

**Decision**: `MemoryRepository.upsert(fact, category, source)` runs before any insert:

1. **Normalize**: lowercase, strip punctuation, collapse whitespace, trim.
2. **Exact match** within the same category → no new row; refresh `updatedAt` (idempotent restatement
   — spike "restate-same" case; SC-006).
3. **Near-duplicate / conflict** within the same category → **supersede in place** (update the
   existing row's `fact` + `updatedAt`) when token-set **Jaccard similarity ≥ ~0.5** over normalized
   content words. Catches "name is Yossef" → "name is Joe" (0.5) and "prefers dark mode" → "prefers
   light mode" (0.6) while leaving genuinely distinct same-category facts ("builds Android apps" vs
   "works as a mobile developer", ~0) untouched.
4. Else **insert** a new active fact. Then enforce the active-count cap (R4): if > 20, deactivate the
   oldest.

This is plain string-token overlap — **not** semantic vectors/embeddings — so it stays inside the
constitution boundary (R-note). Threshold is tunable and the merge is conservative + always
user-correctable in settings. Unit-tested with the spike's conflict/restate cases + false-merge
guards. `forget_fact(id)` soft-deletes by id and **validates the id against active rows** (unknown →
`ToolFailure('no such fact')`; spike showed the model guesses ids — never fuzzy-delete). Integer args
arriving as doubles are coerced (the 004 dispatcher already does this; `id` reuses it).

## R9 — Tool schemas (validator subset already covers them; add `maxLength`)

`remember_fact`: `{fact: string (required, maxLength 80), category: string enum[identity,work,
preferences,other] (required)}`. `forget_fact`: `{id: integer (required, minimum 1)}`. The 004
`SchemaValidator` subset (object/properties/required/enum/string/integer/min/max + strict
unknown-key) covers all of this except a **`maxLength`** on strings — a ~5-line addition to the
validator (R3-class change, no new dependency), unit-tested. Everything else is reuse.

## Pinned versions (this feature's additions)

| Package | Version | Why |
|---|---|---|
| (none) | — | SQLite via the existing drift stack; tools via the 004 registry/dispatcher; injection via the existing `systemInstruction` plumbing. **No new dependency** (Principle IX). |
| `flutter_gemma` | `^0.15.0` (0.15.3 installed) | UNCHANGED — spike findings are 0.15.3-specific; 0.16.x remains a model-load regression on the A34. |
