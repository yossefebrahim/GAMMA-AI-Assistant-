# Phase 0 Spike Findings — On-Device Memory (facts injection + remember_fact/forget_fact)

**Feature**: 005-memory | **Date**: 2026-06-11 | **Device**: Samsung A34 (SM-A346E, Dimensity 1080, 7.3 GiB usable RAM) | **Stack under test**: flutter_gemma 0.15.3 (installed, pinned `^0.15.0`) + `gemma-4-e2b.litertlm` (the artifact already on the device) | **Backend**: GPU (LiteRT OpenCL delegate), model load 7.0 s

**Questions**: (1) how does flutter_gemma inject a system-level facts block for Gemma 4 `.litertlm`
chats, and how does it behave across session recreation? (2) what does a 15–20 fact block cost in
tokens? (3) is auto-capture via a `remember_fact` tool reliable (capture rate, false-positive rate,
arg quality)? (4) what happens on conflicting facts?

**DECISION GATE STATUS**: ✅ **PASS** — auto-capture is viable. **80.0% capture** (16/20 fact
prompts called `remember_fact`), **0 false positives** (0/10 junk prompts), **0 wrong-tool** calls,
**16/16 good arg quality** (short canonical fact string + valid category enum). The 4 misses were
all conservative (the model answered/obeyed in prose instead of calling) and clustered on
*instruction-shaped preferences* ("please use metric units", "address me formally") — a tunable gap,
not a wrong action. The facts-block injection mechanism is a **true native system message** on our
path and was confirmed to ground answers (name/location/pet) and to **survive session recreation**.
Gate threshold was <70% capture **or** noisy false positives → explicit-only fallback; we cleared
both. Full evidence in §3–§4. Throwaway harness: `integration_test/spike_memory_test.dart` (DO NOT
SHIP; remove before merge, per the 004 precedent).

---

## 1. Injection mechanism (Q1) — source inspection + on-device confirmation

### 1.1 Exact mechanism on our path: native `systemMessage`, NOT a first-turn prepend

flutter_gemma exposes a **single** system-instruction parameter that rides the chat/session config:
`createChat(..., String? systemInstruction)`. On our exact path (Android + `.litertlm` +
`ModelType.gemma4` → FFI), it reaches the model as a **true native system message**:

| Layer | Call | Evidence |
|---|---|---|
| Seam today | `createChat(systemInstruction: ToolRegistry.systemInstruction)` (only when fn-calling on) | `flutter_gemma_service.dart:156-167` |
| Chat → session | `sessionCreator: () => createSession(systemInstruction: systemInstruction, …)` | `ffi_inference_model.dart:144-155` |
| Session → native | `ffiClient.createConversation(systemMessage: systemInstruction, toolsJson: …)` | `ffi_inference_model.dart:86-93` |

The LiteRT-LM conversation renders the system message via Gemma 4's chat template. This is **distinct
from** the MediaPipe/web fallback, which prepends `[System: …]\n\n${message.text}` onto the first
user turn (`flutter_gemma_mobile.dart:93-99`, `flutter_gemma_web.dart:581-586`) — **our FFI path
never takes that branch**. Conclusion: the facts block belongs in `systemInstruction`, where it is a
system message, not polluted into the first user turn.

### 1.2 Lifetime & behavior across session recreation

`systemInstruction` is **captured in the `sessionCreator` closure at `createChat`** and is therefore
**immutable for the chat's lifetime**. `clearHistory({replayHistory})` does
`await session.close()` **then** `session = await sessionCreator!()` (`chat.dart:574-575`) — it
recreates the native conversation and **re-applies the same `systemInstruction` every time**. So:

- **Across the app's per-send replays** (`clearHistory(replayHistory:)`): the facts block persists
  unchanged — it is re-injected on every session recreation. ✅
- **Across app restart / backend switch (GPU↔CPU)**: both re-run `loadModel` → `createChat`, so the
  facts block is rebuilt from current memory at that point. ✅
- **To change the facts block without a restart**: you must recreate the **chat** (a fresh
  `createChat` with a new `systemInstruction`); `clearHistory` alone re-applies the *old* block.
  Recreating the chat is cheap relative to model load (`createConversation` is ~ms; the cost is
  history re-prefill, which a **fresh conversation does not have**).

⚠ **FFI session-cache caveat** (verified, load-bearing for the design): a second `createChat` on the
same loaded model returns the **cached** native session unless the prior session is closed first
(`FfiInferenceModel.createSession` returns the existing completer). The seam must
`await chat.session.close()` before recreating a chat with a *different* `systemInstruction`. The
spike does exactly this between its phases and it works.

**Design fit**: this is the clean realization of the spec's "new facts apply from the next session,
not retroactively mid-chat." A **session = a chat creation boundary**. Inject the current facts block
when the chat is (re)created — necessarily at model load / app restart, and (cheaply) when a new
conversation opens. A fact captured mid-conversation does not mutate the running chat's system
message; it surfaces in the next conversation's block.

### 1.3 On-device confirmation (the model actually attends to the block)

A 20-fact block was planted as `systemInstruction` (no facts in any user turn). Results:

| Probe | Reply | Verdict |
|---|---|---|
| "What is my name?" | "Your name is Yossef Ebrahim." | ✅ grounded in block |
| "Where do I live?" | "You live in Cairo, Egypt (GMT+2)." | ✅ grounded |
| "What pet do I have?" | "You have a cat named Mishmish." | ✅ grounded |
| "What is my favorite color?" (NOT in block) | "I do not have information regarding your favorite color." | ✅ **no fabrication** |
| "Remind me — what is my name?" **after `clearHistory()`** | "Your name is Yossef Ebrahim." | ✅ **survives session recreation** |

The model reads the system-message facts, answers from them, declines to invent an absent fact, and
still has them after a deliberate session recreation. Q1 mechanism: **confirmed**.

## 2. Token budget (Q2) — native tokenizer (`session.sizeInTokens`)

Measured with the on-device SentencePiece tokenizer (`InferenceModelSession.sizeInTokens`, not the
app's 4-chars/token heuristic), on the compact category-grouped format proposed for the feature
(ids inline, ordered by category):

| Item | chars | tokens | tokens/fact |
|---|---|---|---|
| facts block — 10 facts | 386 | **97** | 9.7 |
| facts block — 15 facts | 551 | **138** | 9.2 |
| facts block — 20 facts | 693 | **174** | 8.7 |
| capture system instruction (R-lever) | 342 | **86** | — |
| **combined (20-fact block + capture instruction)** | 1037 | **260** | — |

The context budget (`ContextAssembler`) is **1536 tokens** (of `maxTokens: 2048`). A full 20-fact
block + the capture instruction costs **260 tokens ≈ 17%** of the budget, leaving ~1276 for
conversation history + the current turn. Per-fact cost is ~9 tokens in this format.

**Proposed hard cap (backed by the numbers):**

- **≤ 20 active facts**, **per-fact string ≤ 80 chars** (arg-validation bound — keeps facts
  canonical; the spike's captured facts were all ≤ ~55 chars).
- **assembled facts block ≤ 900 chars (~225 tokens)**; if facts exceed it, drop **oldest-first**
  (the block is assembled ordered by category then recency, so the cap trims the least-recent).
- Worst-case memory reserve = ~225 (block) + ~86 (capture instruction) = **~311 tokens ≤ ~20%** of
  the 1536 budget. `ContextAssembler` reserves this off the top (mirroring the existing 40-token
  tool-instruction reserve) so a long history can never crowd out the facts.

## 3. On-device empirical test (Q3 capture + Q4 update)

**Method**: throwaway `integration_test/spike_memory_test.dart`, run via `flutter drive` (NEVER
`flutter test integration_test/...` — wipes the model + DB). Mirrors `FlutterGemmaService`'s load
recipe, then registers two throwaway tools — `remember_fact{fact: string, category:
enum[identity,work,preferences,other]}` and `forget_fact{id: integer}` — with `ToolChoice.auto`,
`supportsFunctionCalls: true`, and a short **capture system instruction** (the reliability lever,
analogous to 004 R6). 20 fact-sharing prompts + 10 junk prompts, each in a fresh single-turn context
(`clearHistory()` between). 3 multi-turn conflict scenarios for Q4 (no clear within a scenario; the
round trip is completed so turn 2 sees a consistent context). GPU backend, exit 0.

### 3.1 Q3 results

| Metric | Result |
|---|---|
| **Capture rate (fact prompts)** | **16/20 = 80.0%** — called `remember_fact` with valid args |
| Missed (answered/obeyed in prose) | 4/20 (prompts 7, 8, 17, 18) |
| Wrong tool on a fact prompt | **0** |
| Arg quality good (≤80-char canonical fact + valid category enum) | **16/16** |
| **False positives on junk** | **0/10** |
| Hallucinated tool names | **0** |
| Parallel/multi-call turns | **0** |

**The 4 misses** — all conservative, all *instruction-shaped preferences* the model chose to **obey
now** rather than **save**:

- "I like concise answers, no fluff please." → prose
- "Please always use metric units with me." → prose
- "I'm learning Rust on the side." → "That's great! Rust is a fantastic language…"
- "I prefer that you address me formally." → "Understood. I will address you formally."

This is a clear, addressable pattern: preferences phrased as directives to the assistant
(tone/units/formatting) are under-captured. The capture instruction should **name** this class
("lasting preferences about how you should respond — tone, units, formatting — are facts worth
saving"). 80% is therefore a **refinable result with a basic instruction**, not a ceiling.

**Junk** (0 false positives): capital of France, haiku, arithmetic, translation, binary-search
explanation, "set a timer for 5 minutes", joke, Python list reverse, weather, Hamlet summary — every
one answered in prose with **no** `remember_fact` call. Tool selection is driven entirely by the
declared registry + instruction; the model does not over-capture trivia or tasks.

**Arg quality**: 16/16 produced a short canonical fact + a valid category. Voice varied slightly
("User's name is Yossef." / "Name is Yossef Ebrahim" / "user prefers dark mode") and a few category
choices were debatable-but-valid (peanut allergy → `preferences`; codes-late → `preferences`). All
were enum-valid and ≤ ~55 chars. A one-line instruction nudge ("write the fact in third person, e.g.
'prefers dark mode'") would standardize the voice.

### 3.2 Q4 update / conflict behavior — three sharp findings

| Scenario | Turn 1 | Turn 2 | Observed |
|---|---|---|---|
| **rename** | "My name is Yossef." → `remember_fact("Name is Yossef", identity)` | "Actually, call me Joe." | `forget_fact(id: 1.0)` |
| **pref-flip** | "I prefer dark mode." → `remember_fact("user prefers dark mode", preferences)` | "I prefer light mode now." | `forget_fact(id: 1.0)` |
| **restate-same** | "I live in Cairo." → `remember_fact("User lives in Cairo.", identity)` | "Just so you know, I live in Cairo." | `remember_fact("User lives in Cairo.", identity)` **again** |

Three load-bearing lessons:

1. **The model fabricates `forget_fact` ids when none are in context.** In both conflict scenarios it
   called `forget_fact(id: 1)` — but the chat had **no facts block with ids** (this was a capture-only
   context). It *guessed* id 1. This is the strongest possible evidence for the spec's design
   decision: **inject facts WITH their ids** so `forget_fact(id)` references a real row — and the
   dispatcher MUST **validate the id against actual active memory rows**, returning a structured
   error (rendered in the chip) for an unknown id rather than crashing or silently deleting the wrong
   fact. No fuzzy matching.
2. **The model re-saves duplicates.** Restating the same fact produced a second identical
   `remember_fact`. **Repository-side dedupe/supersede is mandatory** — on insert, a near-duplicate
   (same category + normalized fact, or same "subject") updates/supersedes the existing row instead
   of appending. Without it, memory fills with duplicates.
3. **Integer args arrive as doubles** (`id: 1.0`) — the exact 004 hazard. The dispatcher's
   whole-valued-double → int coercion (already built for 004) must cover `forget_fact.id`.

**Within-session correction nuance**: because new facts apply from the *next* session, a fact saved
this turn is **not** in the injected block yet, so a same-turn "actually X" can't reliably
`forget_fact(id)` it (the model guesses). The right resolution is repository dedupe/supersede on the
follow-up `remember_fact` ("name is Joe" supersedes the recent "name is Yossef" by subject), and
`forget_fact(id)` is reserved for facts the user can actually *see* (prior-session facts in the
block + the settings screen). This must be documented in the spec.

## 4. Decision gate

**PASS.** Auto-capture clears the gate on the A34:

1. **Reliable**: 80.0% capture ≥ the 70% bar, with the right failure profile — misses are
   conservative prose, **0 false positives**, **0 wrong-tool**, **0 hallucinated tools**, 16/16
   valid args. The capture instruction is a proven lever and the misses point at a specific,
   nameable gap (instruction-shaped preferences) → headroom above 80%.
2. **Injectable**: the facts block is a true native system message that grounds answers, refuses to
   fabricate absent facts, and survives session recreation (§1.3).
3. **Affordable**: a 20-fact block + capture instruction is ~260 tokens (~17% of the 1536 budget);
   capped at 20 facts / 900 chars it stays ≤ ~20% (§2).

**No fallback needed.** Proceed with **auto-capture** (not the explicit-only fallback). Capture
remains gated on the active model's `functionCalling` capability (it is built on the 004 tool
registry); fact **injection** and **manual** management are separable from it (see Carried).

### Carried into /specify and /plan (design consequences)

- **Facts block → `systemInstruction`** (native system message), composed at chat creation, ordered
  by category then recency, **with ids** (forget_fact reliability — §3.2.1). New facts apply from the
  next session; recreate the **chat** (close session first — §1.2 caveat) to refresh without restart.
- **Capture system instruction** is the reliability lever; it must explicitly cover
  instruction-shaped preferences (tone/units/formatting) and ask for short third-person facts (§3.1).
  It composes WITH the 004 tool-use instruction when both are active.
- **Repository-side dedupe/supersede is mandatory** (§3.2.2): near-duplicate `remember_fact` updates
  rather than appends; conflicting facts supersede by subject.
- **`forget_fact(id)` validates against real active rows** → unknown id is a structured `ToolFailure`
  rendered in the chip, never a crash or wrong deletion. Integer coercion covers `id` (§3.2.3).
- **Cap**: ≤ 20 active facts, per-fact ≤ 80 chars, block ≤ 900 chars (~225 tokens); reserved off the
  `ContextAssembler` budget (§2).
- **Capability gating**: `remember_fact`/`forget_fact` are registered (and auto-capture happens) only
  when `capabilities.functionCalling` is on — same structural coupling + seam-side `StateError` as
  004. **Injection of the facts block and the settings management screen are NOT gated on
  function calling** (a text-only model still benefits from injected facts; the user can always
  manage memory manually) — a /clarify point to confirm.
- **Tool-chip reuse**: `remember_fact`/`forget_fact` calls render as 004-style inline tool chips —
  capture is never silent.
- **Throwaway harness** `integration_test/spike_memory_test.dart` is DO NOT SHIP; remove before merge
  (the shipped reliability gate re-runs the 30-prompt suite per quickstart, as 004 did).

### Reproducibility notes

- Screen timeout raised to 30 min + `svc power stayon true` for the run (the 004 run-1 VM-connect
  hang); restored afterward. Run via `flutter drive --driver=test_driver/integration_test.dart
  --target=integration_test/spike_memory_test.dart -d <device>`. Model load 7.0 s, GPU, no RAM
  regression observed (same envelope as 001/003/004 chat).
- The consolidated end-of-run summary `print` was truncated by Android's per-log-line limit; the
  authoritative records are the individual `@@SPIKE@@` lines in the `flutter drive` console.
