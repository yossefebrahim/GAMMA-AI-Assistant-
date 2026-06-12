# Feature Specification: On-Device Memory — Durable Facts About the User

**Feature Branch**: `005-memory`

**Created**: 2026-06-11

**Status**: Draft — clarifications resolved 2026-06-11

**Input**: User description: "On-device durable user memory: the assistant remembers durable facts
about the user (name, job, preferences) across conversations. A `remember_fact` tool auto-captures
durable facts the user shares; a `forget_fact` tool removes them; saved facts are injected as a
compact block into the model's context at session creation so future conversations are grounded in
them. A settings screen lists/edits/deletes facts and a global on/off toggle gives full
transparency. Built on the Phase 4 tool registry; fully on-device (SQLite only — no embeddings, no
RAG, no network). Phase 0 spike (spike-findings.md) verified auto-capture is reliable (80% capture,
0 false positives, native system-message injection that grounds answers and survives session
recreation — GATE PASSED)."

## Clarifications

### Session 2026-06-11

- **Q: Is the injected facts block app-global, or toggleable per conversation?** → **A: App-global.**
  Every conversation sees the same facts; a single global on/off lives in settings. Matches "durable
  facts about the user" and stays consistent with the out-of-scope exclusion of per-conversation
  memory profiles. → FR-006, FR-014.
- **Q: When the model auto-captures a fact, confirm each one, or is the visible chip + settings
  screen enough?** → **A: Chip + settings sufficient (auto-save).** A valid `remember_fact` call
  saves immediately; the inline tool chip is the visibility safeguard and the settings screen is the
  control surface. Mirrors 004's auto-execute decision; the spike measured 0 false positives across
  30 prompts. → FR-001, FR-004.
- **Q: Memory on by default (opt-out) or off by default (opt-in)?** → **A: On by default (opt-out).**
  Everything stays on-device (Principle I is not at risk), so memory works out of the box, is fully
  transparent via chips + settings, and is disableable anytime. → FR-014.

### Resolved by Phase 0 spike evidence (not re-asked — see spike-findings.md §4)

- **Injection is NOT gated on function calling.** The facts block is a plain system message the model
  reads regardless of modality; only **auto-capture** (the `remember_fact`/`forget_fact` tools)
  requires `functionCalling`. A text-only model still benefits from injected facts, and manual
  management always works. → FR-009, FR-016, FR-018.
- **Facts are injected WITH their ids and `forget_fact(id)` validates against real rows.** The spike
  showed the model fabricates ids when none are in context (it guessed `id: 1`). No fuzzy matching.
  → FR-006, FR-010.
- **Repository-side dedupe/supersede is mandatory.** The spike showed the model re-saves duplicates
  and, on a conflict, attempts to forget-then-replace. → FR-003.
- **The global toggle is non-destructive.** Turning memory off stops injection + capture but retains
  facts; clear-all is the only destructive bulk action. → FR-014.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - The assistant remembers a fact you share (Priority: P1)

A user mentions something durable about themselves mid-conversation — "I'm Yossef", "I build Android
apps", "I prefer dark mode". The assistant recognizes it as a lasting fact, calls `remember_fact` to
save it as a short canonical statement (auto-saved per Clarifications Q2), and a small inline tool
chip records what was remembered. Nothing is saved silently: the user always sees a chip when a fact
is captured, and the saved fact appears in the settings memory screen.

**Why this priority**: This is the feature's core write loop — durable facts only exist if they can
be captured. It is the lowest-risk slice (auto-save with a visible chip, no cross-conversation
dependency) and proves capture end-to-end.

**Independent Test**: With a tool-capable model and memory enabled, send 8–10 fact-sharing phrasings;
verify each produces a visible memory chip and a corresponding row in the settings memory list with a
short canonical fact string and a sensible category.

**Acceptance Scenarios**:

1. **Given** memory is on and a tool-capable model is active, **When** the user sends "I prefer dark
   mode", **Then** a `remember_fact` chip appears recording the saved fact, and the fact is listed
   under preferences in the settings memory screen.
2. **Given** the same setup, **When** the user sends a message with no durable fact ("what's 17×23?"),
   **Then** no memory chip appears and nothing is saved (no over-capture of trivia/tasks).
3. **Given** the user shares a fact, **When** `remember_fact` is called with a fact string over the
   length bound or a missing/invalid category, **Then** the fact is NOT saved, an error chip records
   the validation failure, and the assistant still replies normally.

---

### User Story 2 - Saved facts inform future conversations (Priority: P1)

In a brand-new conversation (or after relaunching the app), the user asks something that depends on a
previously saved fact — "what stack do I use?", "summarize this in my preferred style" — and the
assistant answers correctly **without the user restating the fact**, because the saved facts are
injected into the model's context at session creation. Facts saved in a conversation apply from the
**next** session, not retroactively mid-chat.

**Why this priority**: Capture is only valuable if it changes future behavior. This is the read loop
and the actual payoff of memory; it pairs with US1 to form the MVP.

**Independent Test**: Save a fact in one conversation, start a NEW conversation, ask a question that
requires the fact; verify the answer uses the real value. Ask about a fact that was never saved;
verify the assistant does not fabricate one.

**Acceptance Scenarios**:

1. **Given** "name is Yossef" is a saved fact, **When** the user opens a new conversation and asks
   "what's my name?", **Then** the assistant answers "Yossef" from the injected facts block — without
   the user restating it.
2. **Given** no fact about the user's favorite color exists, **When** the user asks "what's my
   favorite color?", **Then** the assistant says it doesn't have that information (no fabrication).
3. **Given** a fact is saved mid-conversation, **When** the user continues that SAME conversation,
   **Then** the running chat's behavior is unchanged for that turn (facts apply from the next
   session) — and the new fact is present when the next conversation starts.
4. **Given** more facts exist than the cap allows, **When** the block is assembled, **Then** it is
   bounded (oldest-first drop) so it never crowds the conversation out of the context budget.

---

### User Story 3 - See and manage everything the assistant remembers (Priority: P2)

The user opens a memory screen in settings and sees **exactly** what the model sees: all saved facts
grouped by category (identity / work / preferences / other). They can edit a fact's text, delete a
single fact, clear everything, and flip a global memory on/off switch. Full transparency — the screen
is the ground truth of the user's stored memory.

**Why this priority**: Transparency and control are the trust contract for a memory feature
(constitution privacy ethos). It also works regardless of the active model, so it is the universally
available management surface.

**Independent Test**: With several saved facts, open the memory screen; verify the listed facts match
what gets injected; edit one and confirm the change persists; delete one and confirm it's gone;
toggle memory off and confirm injection + capture stop; clear-all and confirm the list empties.

**Acceptance Scenarios**:

1. **Given** saved facts across categories, **When** the user opens the memory screen, **Then** every
   active fact is shown grouped by category, matching the injected block exactly.
2. **Given** the memory screen, **When** the user edits a fact's text and saves, **Then** the updated
   text persists and is what the next session injects.
3. **Given** the memory screen, **When** the user deletes a fact (or taps clear-all and confirms),
   **Then** the fact(s) are removed and no longer injected.
4. **Given** memory is on, **When** the user turns the global toggle off, **Then** no facts are
   injected and no new facts are captured, while existing facts are retained (re-enabling restores
   them).
5. **Given** a non-tool-capable model is active, **When** the user opens the memory screen, **Then**
   it works fully (list/edit/delete/clear/toggle) — management is not gated on function calling.

---

### User Story 4 - Correct or update a fact by saying so (Priority: P2)

The user changes a previously stated fact — "actually, call me Joe", "I switched to light mode now",
or simply restates the same fact. The memory does not accumulate duplicates or contradictions: a
near-duplicate updates in place, and a conflicting fact supersedes the old one rather than appending
a second, contradictory row.

**Why this priority**: The Phase 0 spike showed the model re-saves duplicates and attempts conflict
edits; without dedupe/supersede the store degrades into contradictory clutter. This is what keeps
memory coherent over time.

**Independent Test**: Save "name is Yossef", then send "actually call me Joe"; verify the stored
identity fact reflects "Joe" (not two conflicting name rows). Restate an existing fact verbatim;
verify no duplicate row is created.

**Acceptance Scenarios**:

1. **Given** "name is Yossef" is saved, **When** the user says "actually, call me Joe" and a
   `remember_fact("name is Joe", identity)` is captured, **Then** the prior name fact is superseded
   (one current name fact remains), not duplicated.
2. **Given** "prefers dark mode" is saved, **When** the user restates "I prefer dark mode", **Then**
   no second identical row is created (idempotent — the existing fact's recency may refresh).
3. **Given** a near-duplicate save, **When** dedupe runs, **Then** the surviving fact is the latest
   canonical phrasing and the chip reflects an update rather than a new capture.

---

### User Story 5 - Forget a fact by asking (Priority: P3)

The user asks the assistant to forget something — "forget that I live in Cairo", "remove what you
know about my car". Because facts are injected with their ids, the model calls `forget_fact(id)`
referencing the exact fact; the dispatcher validates the id against the active store and removes that
fact. An unknown/guessed id fails honestly (visible error chip), never deleting the wrong fact.

**Why this priority**: A natural-language delete completes the symmetry with capture, but it is lower
risk/lower frequency than capture and injection, and the settings screen already covers deletion. It
depends on injection (US2) supplying ids.

**Independent Test**: With facts injected (each carrying an id), ask the assistant to forget a
specific one; verify that exact fact is removed and a chip records it. Force a `forget_fact` with an
id not in the store; verify an error chip and no deletion.

**Acceptance Scenarios**:

1. **Given** facts are injected with ids and the user asks to forget one, **When** `forget_fact(id)`
   is called with a valid id, **Then** exactly that fact is removed, a chip records it, and it no
   longer appears in settings or future injections.
2. **Given** the model calls `forget_fact` with an id not in the active store, **When** the call is
   processed, **Then** no fact is deleted, an error chip records "no such fact", and the assistant
   replies honestly.
3. **Given** memory is off (no facts injected), **When** the user asks to forget something, **Then**
   the assistant has no ids to reference and responds honestly rather than guessing an id.

---

### User Story 6 - Memory is honest about model capability and never regresses chat (Priority: P3)

Auto-capture depends on the active model declaring function calling (it is built on the Phase 4 tool
registry). With a tool-capable model, the assistant may capture/forget facts. With a model lacking
the capability, no capture tools are offered and the chat behaves exactly as before this feature —
but injected facts and the settings screen still work. Memory chips saved in past conversations
render regardless of the current model.

**Why this priority**: Capability honesty is a constitutional principle and protects every existing
flow from regression. It is defense-in-depth around the capture path.

**Independent Test**: Run capture prompts against a capability-on and a capability-off configuration;
verify capture happens only when on, that injection + settings still function when off, and that
history memory chips render under both.

**Acceptance Scenarios**:

1. **Given** the active model declares function calling, **When** the user shares a durable fact,
   **Then** the assistant may capture it via `remember_fact`.
2. **Given** the active model does NOT declare function calling, **When** the user shares a durable
   fact, **Then** no capture is attempted and chat behaves exactly as today — yet previously saved
   facts are still injected and the memory screen still works.
3. **Given** a conversation containing memory chips from an earlier session, **When** it is reopened
   while any model is active, **Then** the saved chips still render in place.

---

### User Story 7 - Honest failure: bad memory operations degrade visibly (Priority: P3)

When a memory operation is invalid — a fact string too long, an invalid category, an unknown
`forget_fact` id, the cap exceeded — the system never crashes and never silently loses the event. The
attempt is recorded as a visible error chip and the assistant still produces a normal reply. Raw
machine-format tool-call text is never rendered (the 004 LeakFilter rule applies to these tools too).

**Why this priority**: The spike's failure profile is conservative, so this is defense-in-depth — but
a shipped memory feature mishandling a bad call would be a crash or silent corruption, so it is
specified and tested deliberately.

**Independent Test**: Force each failure path through a test seam (over-length fact, bad category,
unknown forget id, cap exceeded); verify error chip + text reply + no crash + no raw JSON for each.

**Acceptance Scenarios**:

1. **Given** `remember_fact` is called with a fact over the length bound or an invalid category,
   **When** processed, **Then** nothing is saved, an error chip records the reason, and the assistant
   replies in text.
2. **Given** the store is at the fact cap, **When** a new `remember_fact` is captured, **Then** the
   cap is enforced (oldest-first or per the documented rule) and the chip reflects the outcome — no
   unbounded growth, no crash.
3. **Given** any memory tool call, **When** the model emits raw machine-format call text into the
   stream, **Then** none of it is rendered (004 LeakFilter), only the chip and prose.
4. **Given** `forget_fact` names an id not in the store, **When** processed, **Then** no deletion
   occurs, an error chip records it, and the reply is honest.

---

### Edge Cases

- **Fact captured mid-conversation**: it is saved immediately (chip shown) but does NOT alter the
  running chat's injected block — facts apply from the next session (FR-008). Documented so users
  aren't surprised the same chat "doesn't know yet".
- **Conflicting facts in one turn vs across sessions**: a same-turn correction ("actually Joe")
  resolves via repository dedupe/supersede on the new `remember_fact` (the just-saved fact isn't in
  the injected block yet, so the model can't reliably `forget_fact` it — FR-003 covers this).
- **Model fabricates a `forget_fact` id**: rejected as "no such fact" (FR-010); never deletes a
  wrong/guessed fact.
- **Over the fact cap**: the block is bounded for injection (oldest-first, FR-007); the store's active
  count is bounded on capture (FR-002/FR-003 dedupe first, then the documented cap rule).
- **Memory off but old chips on screen**: memory chips are render-only history regardless of the
  toggle (mirrors how audio/tool chips render under a text-only model).
- **Edit/delete mid-conversation**: like capture, changes apply from the next session (FR-017).
- **Very long / rambling fact arg**: bounded to the per-fact char cap; over-length → validation error
  (no truncation-into-nonsense), surfaced in the chip (FR-002).
- **Empty store**: the facts block is omitted entirely (no empty header injected; no token cost).
- **Capture while memory disabled**: the capture tools are not declared to the model, so no capture
  occurs (FR-018/FR-021); a programming-error guard backs this at the seam.
- **Duplicate detection across categories**: dedupe compares within the same subject/category so a
  legitimately distinct fact in another category is not wrongly merged (FR-003).

## Requirements *(mandatory)*

### Functional Requirements

**Capture (`remember_fact`)**

- **FR-001**: When a tool-capable model is active AND memory is enabled, the assistant MUST be able to
  call `remember_fact` to save a durable fact the user shares, deciding per turn whether to do so (no
  special syntax). A valid call auto-saves immediately (Clarifications Q2) — no confirmation step.
- **FR-002**: `remember_fact` arguments MUST be validated against the registered schema before any
  save: `fact` (string, non-empty after trim, ≤ the documented per-fact length bound) and `category`
  (required enum: identity | work | preferences | other). A validation failure MUST prevent the save
  and produce a visible error chip with the reason.
- **FR-003**: Before insert, the system MUST dedupe: a near-duplicate of an existing active fact
  (same subject/category, normalized comparison) MUST update/supersede the existing fact rather than
  append a new row; a conflicting fact about the same subject MUST supersede the prior one. The
  dedupe/supersede rule MUST be documented (data-model).
- **FR-004**: Every `remember_fact`/`forget_fact` invocation MUST render as an inline tool chip in the
  004 design-system treatment (monochrome mono tag, quiet result line; red only for error). Capture
  is never silent.
- **FR-005**: Captured facts MUST persist across app restarts in an on-device store.

**Injection (reading memory into context)**

- **FR-006**: At chat/session creation, the active facts MUST be composed into a compact facts block
  injected as the model's **system instruction**, ordered by category then recency, with **each fact
  prefixed by its id** (so `forget_fact(id)` can reference a real row — no fuzzy matching).
- **FR-007**: The facts block MUST be capped — at most the documented number of active facts (target
  20) AND the documented total character bound (target ~900 chars) — with overflow dropped
  oldest-first; the cap's token cost MUST be reserved off the context budget so a long conversation
  cannot crowd the facts out (and vice-versa).
- **FR-008**: New or changed facts MUST apply from the NEXT session (next conversation, model reload,
  or app restart), NOT retroactively mid-conversation. This MUST be documented as expected behavior.
- **FR-009**: Facts-block injection MUST work regardless of the active model's function-calling
  capability (a text-only model still receives injected facts). Only auto-capture (the tools) is
  capability-gated (FR-018).

**Forget (`forget_fact`)**

- **FR-010**: `forget_fact(id)` MUST remove the fact with that id, where the id comes from the
  injected facts block. The dispatcher MUST validate the id against the active store; an unknown id
  MUST produce a structured error (rendered in the chip) and delete nothing — never a fuzzy match,
  never a wrong deletion. Integer args arriving as doubles MUST be coerced (004 hazard).
- **FR-011**: `forget_fact` MUST render as a tool chip (FR-004) and, on success, remove the fact from
  future injections and the settings screen.

**Memory management screen (settings)**

- **FR-012**: A memory management screen MUST list all active facts grouped by category (identity /
  work / preferences / other), each individually editable and deletable.
- **FR-013**: The screen MUST offer clear-all (remove every fact) behind a destructive confirmation.
- **FR-014**: The screen MUST offer a global memory on/off toggle, **on by default** (Clarifications
  Q3). Off MUST stop both injection and auto-capture while RETAINING existing facts (non-destructive);
  on MUST restore them. The toggle state MUST persist across restarts.
- **FR-015**: The screen MUST show exactly what the model sees — the same facts, in the same canonical
  text — so memory is fully transparent.
- **FR-016**: Manual management (list/edit/delete/clear/toggle) MUST work regardless of the active
  model's capabilities (not gated on function calling).
- **FR-017**: Edits, deletes, and toggle changes MUST apply from the next session (consistent with
  FR-008) — they are not required to mutate a running conversation.

**Capability gating & transparency**

- **FR-018**: Auto-capture MUST be gated by the active model's function-calling capability flag: the
  `remember_fact`/`forget_fact` tools are declared to the model ONLY when `functionCalling` is on,
  structurally coupled at the seam (the 004 silent-trap rule — a seam-side `StateError` guards the
  ungated combination). With the flag off, no capture tools are declared and chat behavior is
  byte-for-byte today's (plus any injected facts, FR-009).
- **FR-019**: Memory chips persisted in history MUST render regardless of the currently active model's
  capabilities (history outlives capability, as with image/audio/tool chips).

**Failure behavior**

- **FR-020**: An invalid `remember_fact` (bad args), an unknown `forget_fact` id, a cap-exceeded
  capture, or an internal handler failure MUST degrade to a visible error chip + an honest text reply
  — never a crash, never a silent loss, never a fabricated success.
- **FR-021**: The system MUST NOT capture or inject when memory is disabled, and MUST NOT declare
  capture tools when function calling is off; these are enforced structurally (the tools simply aren't
  registered), with a seam-side programming-error guard as defense-in-depth.
- **FR-022**: Raw machine-format tool-call text from a memory tool MUST never render (the 004
  LeakFilter applies unchanged to `remember_fact`/`forget_fact`).

**On-device, privacy, design**

- **FR-023**: All memory MUST live on-device in SQLite; facts MUST never leave the device. The feature
  MUST NOT introduce embeddings, semantic vectors, RAG, or any network call (a v1 constitution
  boundary — Principle I/IX).
- **FR-024**: All new UI (memory chips, memory screen) MUST use centralized design tokens (no
  hardcoded colors/fonts), the 004 chip treatment, and the established motion language; destructive
  actions (delete, clear-all) use the sanctioned red; interactive elements meet the 48dp touch-target
  and WCAG AA contrast floors.

### Key Entities *(include if feature involves data)*

- **Memory (fact)**: one durable fact about the user — `id`, `fact` (short canonical string, bounded
  length), `category` (identity | work | preferences | other), `createdAt`, `updatedAt`, `active`
  flag (soft-delete / supersede), `sourceConversationId` (the conversation it was captured in;
  nullable for manually-added facts). Persisted in a new `memories` table.
- **remember_fact tool**: a registry entry (name, description, arg schema: `fact` string + `category`
  enum, both required) — declared to the model only when function calling + memory are on.
- **forget_fact tool**: a registry entry (arg schema: `id` integer, required) — declared with the
  facts block (which carries ids) so the model can reference a real fact.
- **Facts block (derived)**: the compact, id-bearing, category-ordered, capped text injected as the
  system instruction at session creation; the settings screen mirrors its contents.
- **App settings (existing)**: gains a persisted `memoryEnabled` flag (default on).
- **Conversation / Message (existing)**: memory tool calls are persisted and rendered as 004-style
  tool chips (no new message kind beyond `role='tool'`).

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: On a scripted ≥30-prompt evaluation suite (≥20 fact-sharing, ≥10 no-fact), the shipped
  feature achieves **≥ 75% capture** on the fact-sharing set (the spike's 80% with a basic
  instruction is the floor; the tuned capture instruction is the lever) and **zero** crashes — on the
  reference 8 GB arm64-v8a device.
- **SC-002**: **Zero** false-positive captures on the no-fact prompts and **zero** invented/unknown
  tool names across the suite (parity with the spike's measured floor).
- **SC-003**: ≥ 90% of captured facts have good arg quality — a short canonical fact string within the
  length bound AND a valid category enum (spike: 16/16).
- **SC-004**: In a fresh conversation, a question answerable from a saved fact is answered correctly
  using the injected value in 100% of trials for facts in the block; a question about a never-saved
  fact yields no fabricated answer.
- **SC-005**: The injected facts block stays within the cap (≤ 20 facts / ≤ ~900 chars, ~≤ 20% of the
  context budget) in 100% of assemblies; conversation history is never dropped solely because the
  facts block was oversized.
- **SC-006**: Restating an existing fact creates **zero** duplicate rows, and a conflicting fact
  results in exactly one current fact for that subject (dedupe/supersede), in 100% of trials.
- **SC-007**: `forget_fact(id)` on an id present in the injected block removes exactly that fact in
  100% of trials; an id NOT in the store deletes nothing and surfaces an error chip in 100% of trials.
- **SC-008**: The settings memory screen shows exactly the set of facts the next session injects;
  edits/deletes/clear/toggle persist across an app restart in 100% of trials.
- **SC-009**: With the global toggle off, **zero** facts are injected and **zero** captures occur,
  while the stored facts remain intact and reappear when toggled on.
- **SC-010**: With a non-tool-capable model configuration, **zero** capture is attempted and a
  regression pass over existing chat (text/image/audio) shows **zero** behavioral change — while
  injection and the settings screen still function.
- **SC-011**: After killing and relaunching, 100% of saved facts persist and 100% of memory chips in
  prior conversations render in place regardless of the active model.
- **SC-012**: With connectivity disabled (airplane mode), all memory operations — capture, inject,
  forget, manage — work end-to-end; **zero** network requests are observed.
- **SC-013**: Every new interactive element passes the 48dp touch-target and AA contrast audit before
  release (Principle VI).
- **SC-014**: A code/network audit confirms **no** embeddings, vector store, or network path was
  introduced (Principle I/IX constitution boundary); `check_network_seam.sh` stays green.

## Assumptions

- The Phase 0 spike's measured behavior holds: ~80% capture with a basic instruction, conservative
  misses (prose instead of a call), zero false positives, native system-message injection that
  grounds answers and survives session recreation. The tuned capture instruction (covering
  instruction-shaped preferences) is the lever to clear SC-001 with margin; the spec does not depend
  on exceeding the spike floor.
- One model is active at a time (existing constraint); the current catalog's single model (Gemma 4
  E2B) declares function calling, so capture is available by default. A future text-only model would
  still receive injected facts and full manual management.
- Facts are short textual statements; the per-fact and block caps keep memory inside the existing
  1536-token context budget without redesigning context assembly.
- "Durable fact" is judged by the model (guided by the capture instruction + tool description);
  borderline calls degrade to ordinary prose (a miss) or are manageable/deletable after the fact —
  acceptable behavior.
- English-language prompts are the testing baseline (consistent with 001–004).
- The reference device and its installed Gemma 4 E2B `.litertlm` artifact remain the verification
  baseline (the same device/model the spike used).

## Dependencies

- **Phase 0 spike (PASSED)** — `specs/005-memory/spike-findings.md`: verified the injection mechanism,
  capture reliability, token budget, and the dedupe/forget-id design constraints on the reference
  device.
- **004 (function calling)**: the tool registry, dispatcher + strict schema validator, the
  `GenerationEvent`/`resumeWithToolResult` seam, the seam-side capability `StateError` gate, the
  LeakFilter, the `role='tool'` message kind + tool chip, and the system-instruction plumbing — all
  reused directly. `remember_fact`/`forget_fact` are added to the existing registry.
- **001–003**: conversation persistence + drift migration pattern, streaming/stop, context assembly,
  capability-gating-as-data, history-outlives-capability rendering.
- **Settings + theme mechanism**: the memory screen reuses the settings list/section pattern; the
  global toggle reuses the persisted single-row app-settings mechanism (like `themeMode`).
- **Design system** (`.specify/memory/design-system.md` §8): the tool-chip treatment and settings-row
  treatment.

## Out of Scope

- **Embeddings / semantic recall / RAG / vector stores** — a v1 constitution boundary (Principle
  I/IX). Recall is exact-text injection of a small capped block, nothing more.
- **Automatic conversation summarization into memory** — only explicit, model-decided
  `remember_fact` calls (and manual additions) create facts; the assistant does not mine whole
  conversations into memory.
- **Memory sync / export / import / backup** — memory is local to the device and this install.
- **Per-conversation memory profiles** — memory is app-global (Clarifications Q1); no per-thread fact
  sets.
- **Retroactive mid-conversation memory** — new/changed facts apply from the next session (FR-008),
  not to the in-flight chat.
- **Confirmation flows for capture** — auto-save with a visible chip + settings control
  (Clarifications Q2); a future confirmation policy is enabled by the existing read-only/state-class
  data but not built here.
- **Cross-modal facts** (remembering images/audio the user shared) — facts are short text only.
- **Manual fact creation via a rich form beyond a simple add/edit** is minimized to text + category;
  no tagging, pinning, or priority weighting in v1.
- **Non-Android platforms** (Principle IX).
