# Feature Specification: Function Calling — Local Device Tools

**Feature Branch**: `004-function-calling`

**Created**: 2026-06-10

**Status**: Draft — clarifications resolved 2026-06-10

**Input**: User description: "Natural-language invocation of local device tools (function calling) — the assistant can use a small registry of LOCAL, on-device tools when the user asks for something a tool can do: set_theme, get_device_info, set_timer, summarize_clipboard. The model decides when to call; every call is VISIBLE in the conversation as an inline tool chip in design-system style — no silent execution. Tool-use affordances and behavior are gated by a functionCalling capability flag on the model catalog entry. Tool calls and results persist in conversation history and are replayed into the model context. Hallucinated tools or invalid arguments degrade to a visible error chip plus a normal text response — never a crash, never silent loss. Out of scope: external/network tools, multi-step autonomous chains, switch_backend (pending clarify). Phase 0 spike (spike-findings.md) verified function calling works reliably end-to-end on the reference device (83.3% correct-call rate, zero hallucinated tools, zero spurious calls)."

## Clarifications

### Session 2026-06-10

- **Q: Confirmation policy for state-changing tools (`set_theme`, `set_timer`) — auto-execute or
  inline confirm?** → **A: Auto-execute.** All four v1 tools execute immediately on a valid call;
  the tool chip is the visibility safeguard. Rationale: both mutations are low-risk and instantly
  reversible (theme toggles back; a timer can be cancelled in the clock app), and the spike
  measured zero spurious calls in 20 trials — an extra tap would erase the "just ask" value
  without adding real protection. → FR-016.
- **Q: `set_timer` mechanism — in-app countdown or system clock hand-off?** → **A: System clock
  hand-off, silent (skip-UI).** The timer is handed to the device's clock app without leaving the
  conversation; it survives the app being killed and rings on the lock screen. An in-app
  countdown would die with the app process unless this slice built alarm/notification
  infrastructure it didn't budget. → FR-015.
- **Q: Should `switch_backend` be exposed as a callable tool?** → **A: No — keep excluded.**
  Backend selection is infrastructure; a model-triggered switch would unload/reload the model
  (~12 s, can fail over from GPU) on a casual phrase. Excluded from this feature's scope (not
  merely deferred). → Out of Scope.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Ask a device question, watch the assistant use a tool (Priority: P1)

A user asks the assistant something only the device can answer — "how much battery do I have
left?", "what phone is this?", "how much free storage is there?". The assistant recognizes the
request, invokes its `get_device_info` tool, and a small tool chip appears inline in the
conversation — tool name, what it asked for, and a quiet result line — followed by a normal
streamed reply grounded in the real values ("You're at 83% battery…"). Nothing happens silently:
the user can always see that a tool ran, what it was given, and what came back.

**Why this priority**: This is the feature — the visible call→execute→answer loop. Every other
story builds on this round trip. It is also the lowest-risk tool (read-only, no side effects,
no permissions), so it proves the loop end-to-end first.

**Independent Test**: With a tool-capable model active, ask 5–10 phrasings of device questions;
verify each produces a visible tool chip and a final answer containing the real device values.
Delivers standalone value: the assistant can answer device questions it previously could not.

**Acceptance Scenarios**:

1. **Given** a conversation with a tool-capable model, **When** the user sends "what's my battery
   level?", **Then** a tool chip for the device-info tool appears in the conversation, followed by
   a streamed assistant reply whose figures match the device's actual state.
2. **Given** the same setup, **When** the user sends a request the tool can serve only partially
   ("which android version is this?"), **Then** the chip appears and the reply contains the
   correct value drawn from the tool result.
3. **Given** the assistant decides no tool is needed ("write a haiku about rain"), **When** the
   reply generates, **Then** no tool chip appears and the reply is ordinary text.
4. **Given** a tool call is in progress, **When** the result returns, **Then** the chip shows the
   completed state (never an eternal spinner) and the conversation continues into the final
   answer without user action.

---

### User Story 2 - Change the app theme by asking (Priority: P2)

A user says "switch to light mode" (or "go dark again"). The assistant invokes `set_theme`; the
app's theme changes immediately (auto-execute per Clarifications Q1 — the chip is the visibility
safeguard); a tool chip records the action and its outcome in the conversation. The theme change
behaves exactly as if made from settings — it persists across restarts.

**Why this priority**: First state-changing tool — it proves tools can *do* things, not just
read things, and it exercises the confirmation policy decision. Theme is the safest possible
mutation (instantly visible, trivially reversible).

**Independent Test**: Ask for a theme switch in several phrasings; verify the theme visibly
changes, the chip records it, the setting persists across an app restart, and asking for the
already-active theme is handled gracefully.

**Acceptance Scenarios**:

1. **Given** the app is in dark theme, **When** the user sends "switch to light theme", **Then**
   the app switches to light theme immediately, a tool chip records the action and success, and
   the assistant's reply acknowledges the change.
2. **Given** the app is already in dark theme, **When** the user asks for dark theme, **Then** the
   tool reports the theme was already active (idempotent success — no error), and the reply says
   so.
3. **Given** the theme was changed via the tool, **When** the app is killed and relaunched,
   **Then** the chosen theme is still active (same persistence as a settings change).

---

### User Story 3 - Tools appear only for models that can use them (Priority: P2)

Tool behavior is driven by the active model's declared capabilities. With a tool-capable model,
the assistant may call tools. With a model that lacks the capability, the assistant never
attempts a call, no tool-related UI appears for new turns — and the app behaves exactly as it did
before this feature. Tool chips already saved in past conversations still render regardless of
the current model.

**Why this priority**: Capability honesty is a constitutional principle (capabilities are data,
never hardcoded) and the established pattern of the two prior feature slices. It also protects
every existing user flow from regression when tools are off.

**Independent Test**: Run the same prompts against a capability-on and a capability-off
configuration; verify calls happen only when the flag is on, and that history chips render under
both.

**Acceptance Scenarios**:

1. **Given** the active model declares the function-calling capability, **When** the user asks a
   device question, **Then** the assistant may produce a tool call.
2. **Given** the active model does NOT declare the capability, **When** the user asks the same
   question, **Then** the assistant answers in plain text only — no tool call is attempted, no
   tool chip is created, and generation behaves exactly as today.
3. **Given** a conversation containing tool chips from an earlier session, **When** it is opened
   while a non-tool-capable model is active, **Then** the saved chips still render in place.

---

### User Story 4 - Set a timer by asking (Priority: P2)

A user says "set a timer for 5 minutes". The assistant invokes `set_timer` with the requested
duration; the timer is handed to the device's clock app silently — the user stays in the
conversation, and the timer survives the app being killed and rings on the lock screen
(Clarifications Q2). The tool chip records what was set and for how long; the assistant's reply
confirms the hand-off honestly ("a 5-minute timer is running in your clock app").

**Why this priority**: The second state-changing tool, with a real-world side effect and a
duration argument — it exercises argument extraction from natural language ("five minutes",
"90 seconds", "an hour and a half") more than any other tool in the set.

**Independent Test**: Ask for timers in varied phrasings and durations; verify the parsed
duration matches the request, the chip records it, and the device's clock app demonstrably holds
the running timer.

**Acceptance Scenarios**:

1. **Given** a tool-capable model, **When** the user sends "set a timer for 5 minutes", **Then**
   a 5-minute timer starts in the device's clock app without leaving the conversation, and the
   chip records tool, duration, and success.
2. **Given** the user phrases the duration in words ("a quarter of an hour"), **When** the call is
   made, **Then** the started timer matches the intended duration.
3. **Given** the user asks for an unreasonable duration (zero, negative, or absurdly long),
   **When** the tool validates it, **Then** it declines with a structured error shown in the chip
   and the assistant replies honestly that no timer was set.

---

### User Story 5 - Summarize what's on the clipboard (Priority: P3)

A user copies a long article or message elsewhere on the phone, returns to the app, and says
"summarize my clipboard". The assistant invokes `summarize_clipboard`; the tool reads the
clipboard **at that moment, while the app is in the foreground** (a platform restriction —
modern Android only exposes the clipboard to the focused app), and the assistant streams a
summary of the text. If the clipboard is empty or holds non-text content, the chip shows a
structured "nothing to summarize" error and the assistant says so. The user should know that the
platform may show its own "app read the clipboard" notice — that notice is the system being
honest, matching this feature's own visibility principle.

**Why this priority**: Highest-value read-only tool, but it depends on content the user prepares
outside the app and carries platform constraints — riskier to demo than the device-info loop, so
it lands after the core stories.

**Independent Test**: Copy text in another app, ask for a summary, verify the summary reflects
the copied text; clear the clipboard and verify the structured error path.

**Acceptance Scenarios**:

1. **Given** text on the clipboard, **When** the user asks for a clipboard summary, **Then** the
   chip records the tool ran and the assistant streams a summary grounded in the copied text.
2. **Given** an empty clipboard (or image-only content), **When** the tool runs, **Then** the chip
   shows a structured error state ("clipboard empty / not text") and the assistant replies
   honestly, with no crash and no fabricated summary.
3. **Given** an extremely long clipboard text, **When** the tool reads it, **Then** the content is
   bounded to a documented limit before summarization (truncated, with the truncation noted in the
   tool result) so generation remains responsive.
4. **Given** the clipboard contains sensitive text, **When** the tool runs, **Then** the content
   is processed entirely on-device and never leaves the phone (the same guarantee as every other
   message).

---

### User Story 6 - Tool turns survive restarts and feed follow-ups (Priority: P3)

Tool calls and their results are part of the conversation, not transient UI. After killing and
relaunching the app, reopening the conversation shows the tool chips exactly where they happened.
Follow-up questions keep working against earlier tool results ("and how much was the free
storage again?") because tool turns are replayed into the model's context like any other turn.

**Why this priority**: Persistence and context fidelity make tools trustworthy rather than a
party trick, but they only matter once the core loop (US1) and at least one tool exist.

**Independent Test**: Run a tool turn, restart the app, verify the chip renders from history;
ask a follow-up that requires the earlier result and verify the answer uses it without
re-calling the tool unnecessarily.

**Acceptance Scenarios**:

1. **Given** a conversation with a completed tool turn, **When** the app is killed and
   relaunched and the conversation reopened, **Then** the tool chip renders in place with its
   name, arguments, and result state.
2. **Given** an earlier device-info tool result in the conversation, **When** the user asks a
   text follow-up about one of its values, **Then** the assistant can answer from the
   conversation context (the tool turn was replayed to the model).
3. **Given** a conversation is deleted, **When** deletion completes, **Then** its tool turns are
   removed with it (no orphaned records).

---

### User Story 7 - Honest failure: bad calls degrade visibly, never crash (Priority: P3)

When the model attempts something invalid — a tool that doesn't exist, arguments that don't fit
the tool's schema, or a second call where only one is allowed — the system never crashes and
never swallows the event. The attempt is recorded as a visible error chip (what was attempted,
why it failed) and the assistant still produces a normal text reply. The raw machine-format
text that the model emits while calling tools is never shown to the user (the spike measured
this leak on 100% of calls — suppressing it is a hard requirement, not polish).

**Why this priority**: The spike showed the failure profile is conservative (zero hallucinated
tools in 20 trials), so this is defense-in-depth — but the cost of failing here is a crash or
silent data loss in a shipped conversation, so it must be specified now and tested deliberately.

**Independent Test**: Force the failure paths through a test seam (fake model emitting a bogus
tool name / malformed arguments / an extra call); verify error chip + text reply + no crash for
each.

**Acceptance Scenarios**:

1. **Given** the model calls a tool name that is not registered, **When** the call is processed,
   **Then** an error chip records the attempted name and "unknown tool", the assistant is informed
   and produces a text reply, and the app does not crash.
2. **Given** the model calls a registered tool with arguments that fail validation, **When** the
   call is processed, **Then** the tool does NOT execute, an error chip records the validation
   failure, and the assistant is informed and replies in text.
3. **Given** any tool turn, **When** the model emits raw machine-format call text into the
   visible stream, **Then** none of it is rendered to the user — the user sees only the chip and
   normal prose.
4. **Given** a tool executes but fails internally (e.g., clipboard unavailable), **When** the
   result returns, **Then** the chip shows the error state and the assistant's reply reflects the
   failure honestly — never a fabricated success.
5. **Given** the user taps stop while a tool turn is in flight, **When** generation halts,
   **Then** the conversation is left in a consistent, rendered state (chip reflects what actually
   happened; no half-executed invisible work).

---

### Edge Cases

- **Model requests a second tool call after receiving the first result** (one round trip per
  turn is the contract): the follow-up call is not executed; it is surfaced as an error chip
  ("only one tool call per turn") and generation finishes as text. The spike observed 0/10
  extra calls, so this is rare-path hardening.
- **Model emits multiple parallel calls in a single response**: only the first is honored; the
  rest are recorded in one error chip. (Spike observed 0/20 parallel turns.)
- **The two prompts in twelve where the model should call but answers in prose** (spike: misses
  are conservative): acceptable behavior — the reply is still a normal answer; nothing to
  surface. Reliability target lives in Success Criteria, not per-turn UI.
- **Tool turn in flight when the app is backgrounded**: execution completes or fails on return;
  the chip must end in a terminal state either way (never frozen "running" in history).
- **set_theme to the already-active theme**: idempotent success, not an error (US2/AS2).
- **Timer already running when a second timer is requested**: the system clock app stacks
  timers natively (Q2 resolution) — each request hands off a new timer; no replace-or-reject
  logic in the app.
- **No clock app can accept the timer hand-off**: structured error in the chip, honest reply
  (FR-015) — never a silent no-op.
- **Clipboard changes between the user's request and tool execution**: the tool reads whatever
  is present at execution time — the chip's recorded result is the truth of what was read.
- **Attachment + tool turn**: a message carrying an image or voice clip may still trigger a tool
  call; attachment handling is unchanged (tool turns add to, never replace, existing message
  behavior).
- **Very long tool results**: bounded before they enter the model context so a tool result can
  never crowd the conversation out of its context budget.
- **Capability flag off, persisted chips on screen**: chips are render-only history; no
  interactive tool affordances are offered (mirrors how audio chips render under a text-only
  model).

## Requirements *(mandatory)*

### Functional Requirements

**Invocation & visibility**

- **FR-001**: When a tool-capable model is active, the assistant MUST be able to invoke any
  registered tool in response to a natural-language request, deciding per turn whether a tool is
  needed (no slash commands, no special syntax).
- **FR-002**: Every tool invocation MUST be visible in the conversation as an inline tool chip
  showing the tool's name, its key arguments, and its outcome state (running → success or error).
  Silent execution is prohibited.
- **FR-003**: The tool chip MUST follow the design system's function-call treatment: monochrome,
  uppercase mono tag (e.g., `TOOL · SET_THEME`), result as a quiet system line — never a colored
  banner; the accent color appears only for error states per the accent discipline.
- **FR-004**: The raw machine-format text the model emits while calling a tool MUST never be
  rendered to the user — not in the streaming bubble, not in history (spike: this leak occurs on
  100% of calls and MUST be suppressed structurally, not cosmetically).
- **FR-005**: After a successful tool execution, the assistant MUST produce a final
  natural-language reply grounded in the tool's result, streamed like any other reply.
- **FR-006**: At most ONE tool round trip is allowed per user turn: one call, one result, then a
  text completion. Additional or parallel calls in the same turn MUST NOT execute and MUST be
  surfaced per FR-024.

**Registry & capability gating**

- **FR-007**: The set of available tools MUST come from a single registry — each entry declaring
  the tool's name, human description, argument schema, and read-only vs state-changing class.
  The v1 registry is exactly: `get_device_info`, `summarize_clipboard` (read-only), `set_theme`,
  `set_timer` (state-changing).
- **FR-008**: Tool availability MUST be gated by a function-calling capability flag on the model
  catalog entry, flowing as data through the established capability path (catalog → model load →
  capability state → behavior). No hardcoded per-model branches.
- **FR-009**: When the active model lacks the capability, the system MUST NOT declare tools to
  the model, MUST NOT attempt calls, and the chat experience MUST be byte-for-byte the existing
  behavior (zero regression with the flag off).
- **FR-010**: Tool chips persisted in history MUST render regardless of the currently active
  model's capabilities (history outlives capability, as with image/audio attachments).
- **FR-011**: The system MUST refuse (as an internal programming-error guard, not a user-visible
  state) any attempt to engage tools while the capability is off at the service boundary — the
  established seam-side gate pattern (the runtime silently mishandles the ungated case; the spike
  confirmed this hazard).

**Per-tool behavior**

- **FR-012**: `get_device_info` MUST return the device's model name, OS version, total and
  available memory, battery level, and available storage as a structured result; it MUST be
  read-only and require no runtime permissions. Results SHOULD be supersets (the full info map)
  rather than narrowly filtered slices (spike trial 10: the model extracts what it needs).
- **FR-013**: `summarize_clipboard` MUST read the clipboard only at execution time while the app
  holds focus (platform constraint: modern Android restricts clipboard access to the focused
  foreground app — this constraint MUST be documented in the tool's description so the model can
  explain it). Empty or non-text clipboard MUST produce a structured error result, not a crash or
  a fabricated summary. Clipboard text MUST be bounded to a documented maximum before entering
  the model context, with truncation recorded in the result. The platform's own
  clipboard-access notice (shown by the OS on modern Android) is expected and acceptable.
- **FR-014**: `set_theme` MUST switch the app between dark and light theme with exactly the same
  effect and persistence as the equivalent settings change; requesting the already-active theme
  MUST report idempotent success.
- **FR-015**: `set_timer` MUST hand the requested countdown to the device's clock app silently
  (no foreground switch — the user stays in the conversation; Clarifications Q2), so the timer
  survives the app's death and rings on the lock screen. It MUST validate duration bounds
  (positive, within a documented maximum) and decline out-of-range requests with a structured
  error. If the device has no app able to accept the timer, the tool MUST return a structured
  error (rendered in the chip) rather than failing silently — the assistant's reply reflects it.
- **FR-016**: All four v1 tools auto-execute on a valid call (Clarifications Q1) — the tool chip
  is the visibility safeguard; no inline confirmation step exists in this slice. The registry
  still records each tool's read-only vs state-changing class (FR-007) so a future policy change
  is a data change, not a redesign.
- **FR-017**: Every tool MUST execute entirely on-device with no network access (Principle I);
  tool results, including clipboard content, MUST never leave the device.

**Persistence & context**

- **FR-018**: Tool calls and tool results MUST be persisted as part of conversation history with
  a distinct message kind (alongside the existing user/assistant kinds), surviving app restarts
  and rendering in place when a conversation reopens.
- **FR-019**: Persisted tool turns MUST be included when conversation context is rebuilt for the
  model (session recreation, follow-up turns), so the model can reference earlier tool results;
  the app's own history is the source of truth for replay (the runtime's internal history omits
  tool turns — spike §1.3).
- **FR-020**: Deleting a conversation MUST delete its tool turns with it.
- **FR-021**: Tool turns MUST count against the conversation's context budget like other turns,
  with results bounded (FR-013) so a single tool turn cannot exhaust the budget.

**Failure behavior**

- **FR-022**: A call naming an unregistered tool MUST NOT crash and MUST NOT vanish: it produces
  a visible error chip (attempted name, "unknown tool") and the model is informed so it completes
  the turn in text.
- **FR-023**: Arguments failing schema validation MUST prevent execution and produce a visible
  error chip with the validation reason; the model is informed and completes in text.
- **FR-024**: Extra calls beyond the one-per-turn contract (FR-006) MUST be recorded in an error
  chip and skipped.
- **FR-025**: A tool that fails during execution MUST return a structured error that renders in
  the chip and informs the model — the assistant's reply MUST be able to acknowledge the failure
  honestly (never fabricated success).
- **FR-026**: Stopping generation during a tool turn MUST leave the conversation in a consistent
  state: the chip reflects what actually happened (executed / not executed / error) and no
  invisible side effect occurs after stop.

**Responsiveness, accessibility, design**

- **FR-027**: The interface MUST remain responsive during tool execution and the surrounding
  generation (existing streaming/cancel guarantees apply to tool turns; stop remains available).
- **FR-028**: Any new interactive element introduced by this feature MUST meet the 48dp
  touch-target and WCAG AA contrast floor; tool-chip text MUST use AA-passing tokens (chips are
  essential content — never below the secondary-text contrast tier). (Post-clarification, the
  chip itself is expected to be the only new surface — it is non-interactive in v1.)
- **FR-029**: All new UI MUST use centralized design tokens (no hardcoded colors/fonts) and the
  established motion language (dot-matrix/pulse motifs for the chip's running state, mechanical
  150–250ms transitions).

### Key Entities *(include if feature involves data)*

- **Tool Definition**: a registry entry — unique name, human-readable description (also the
  model's guidance for when to use it), argument schema, read-only vs state-changing class.
  Static in v1 (four entries); not user-editable.
- **Tool Invocation**: one attempted call within a conversation — which tool, the arguments as
  requested by the model, validation outcome, execution outcome (success / structured error /
  skipped), and its position in the conversation flow. Persisted as a distinct message kind.
- **Tool Result**: the structured outcome attached to an invocation — the data returned (or the
  error), bounded in size, fed back to the model and rendered as the chip's quiet result line.
- **Conversation (existing)**: gains tool turns among its messages; deletion cascade covers them.
- **Model catalog entry (existing)**: gains the function-calling capability flag.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: On the scripted 20-prompt evaluation suite from the Phase 0 spike (12 should-call,
  5 plain-text, 3 unregistered-tool probes), the shipped feature achieves **≥ 80% correct-call
  rate** on the should-call set and **zero** crashes — measured on the reference baseline device
  (current-generation 8 GB arm64-v8a phone).
- **SC-002**: **Zero** spurious tool calls on the plain-text prompts and **zero** invented tool
  names on the unregistered-tool probes of that suite (parity with the spike's measured floor).
- **SC-003**: 100% of executed tool calls render a visible chip with name, key arguments, and a
  terminal outcome state; **zero** raw machine-format call text is visible to the user in any
  observed tool turn.
- **SC-004**: In a forced-failure test pass (unknown tool, invalid arguments, failing tool,
  stop-mid-turn), 100% of cases end with a visible error chip and a coherent text reply; zero
  crashes, zero silently lost turns.
- **SC-005**: A device question answered via `get_device_info` completes — send to final
  grounded answer, including the tool round trip — in **under 20 seconds** on the baseline
  device (spike measured ~2s to call + 1.6–15.4s resume).
- **SC-006**: After killing and relaunching the app, 100% of tool chips in a previously saved
  conversation render in place with their outcome states, and a follow-up question referencing an
  earlier tool result is answered correctly without re-invoking the tool.
- **SC-007**: With a non-tool-capable model configuration, a regression pass over the existing
  chat flows (text, image, audio) shows **zero** behavioral change, and zero tool calls are
  attempted across the 20-prompt suite.
- **SC-008**: With connectivity disabled (airplane mode), all four tools execute successfully
  end-to-end (clipboard summarization included); zero network requests are observed during tool
  turns.
- **SC-009**: A theme change made via `set_theme` persists across an app restart in 100% of
  trials, identically to a settings-screen change.
- **SC-010**: Every new interactive element passes the 48dp touch-target audit and AA contrast
  check before release (accessibility gate, Principle VI).
- **SC-011**: In moderated usability testing (≥ 8 participants), at least 90% can correctly state
  *what the assistant did* after a tool turn (tool visibility comprehension — the chip
  communicates), and 100% of participants who asked for a device fact received an answer
  containing the true value.

## Assumptions

- The Phase 0 spike's measured behavior holds: ~83% correct-call floor with no tool-use
  instruction, conservative misses (prose instead of call), zero hallucinated tools, zero
  malformed arguments, single calls per turn, results grounded after the round trip. A brief
  tool-use system instruction is the expected reliability lever to clear SC-001's 80% bar with
  margin; the spec does not depend on it exceeding the spike floor.
- The reliability target applies to clearly-tool-suited phrasings (the evaluation suite), not to
  every conceivable phrasing; conservative misses degrade to ordinary correct prose, which is
  acceptable behavior (Edge Cases).
- One model is active at a time (existing constraint); tool capability follows the active model's
  catalog entry. The current catalog has a single model (Gemma 4 E2B), which gains the flag per
  the spike.
- Tool results are textual/structured data of modest size; the clipboard bound and result bounds
  keep tool turns inside the existing context budget without redesigning context assembly.
- Battery level and storage figures are point-in-time readings taken at execution; staleness
  across a long conversation is expected and acceptable (each new call re-reads).
- The platform's clipboard-read notice (Android 12+) is system behavior outside the app's
  control; it aligns with, rather than conflicts with, this feature's visibility principle.
- English-language prompts are the testing baseline (consistent with 001–003).

## Dependencies

- **Phase 0 spike (PASSED)** — `specs/004-function-calling/spike-findings.md`: verified API path,
  reliability floor, failure profile, leak hazard, and the persistence/replay requirement on the
  reference device.
- **001 (model download + streaming chat)**: conversation persistence, streaming pipeline, stop
  control, context assembly — tool turns ride all of them.
- **002/003 (image/audio input)**: the established capability-gating pattern (catalog →
  capability → affordance), the seam-side programming-error gate, and the
  history-outlives-capability rendering rule that tool chips reuse.
- **Design system** (`.specify/memory/design-system.md` §8): the function-call chip treatment is
  already specified there (mono uppercase tag, quiet result line, no colored banner).
- **Theme switching**: `set_theme` reuses the existing user-controllable, persisted theme
  mechanism (Constitution Principle VI).

## Out of Scope

- **External or network-backed tools** of any kind (web search, weather, messaging) — Principle I
  (on-device only) excludes them categorically, not provisionally.
- **Multi-step autonomous tool chains**: one tool round trip per user turn; the model answers
  after at most one call. Chaining (call → call → call without user turns) is a future,
  deliberate decision.
- **`switch_backend` as a tool** — backend selection is infrastructure, and exposing it to
  casual natural language has reliability/memory consequences (a model-triggered switch would
  unload/reload the model). EXCLUDED — confirmed in Clarifications (2026-06-10), not merely
  deferred.
- **User-defined or third-party tools** (a tool marketplace, plugins): the registry is static and
  ships with the app.
- **Proactive tool use** (the assistant volunteering tool actions unprompted in an otherwise
  unrelated conversation).
- **Confirmation flows of any kind** (inline confirm, undo affordances): all v1 tools
  auto-execute per Clarifications Q1; a future confirmation policy is enabled by the registry's
  read-only/state-changing classes but not built in this slice.
- **Tool use inside multimodal turns being specially optimized** — attachments and tools may
  coexist (Edge Cases) but no tool consumes image/audio content in v1 (no "describe my screenshot"
  tool).
- **Non-Android platforms** (Principle IX).
