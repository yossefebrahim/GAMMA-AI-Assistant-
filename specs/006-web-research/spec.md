# Feature Specification: Opt-In Web Research — Search & Fetch via Tavily BYOK

**Feature Branch**: `006-web-research`

**Created**: 2026-06-12

**Status**: Draft — locked decisions recorded 2026-06-12; two device-measurement TODOs remain open

**Input**: User description: "Opt-in web search augmentation for the on-device Gemma assistant. The
user brings their own Tavily API key (BYOK, stored encrypted on-device). Two tools — web_search and
fetch_page — let the model ground its answers in live web results. Off by default; a Settings master
toggle plus a per-conversation quick toggle give the user full control. Every outbound call is visibly
named in a tool chip. Answers show tappable source URL chips. History persists the call metadata and
sources. Degrades gracefully offline. Grounded in the Phase 0 spike (snippets-only, one call per
turn)."

---

## Clarifications

### Locked decisions — 2026-06-12 (product owner, not re-asked)

- **Decision 1 — Provider: Tavily BYOK.** The user pastes their own Tavily Search API key in
  Settings. The key is stored in Android EncryptedSharedPreferences (Keystore-backed), is never
  committed to the APK/repo, and is never written to conversation history, logs, or the SQLite DB.
  Tavily returns AI-optimized JSON with fields `title`, `url`, `content` (pre-extracted text
  excerpt), and `score`. No attribution requirement. → FR-003, FR-004, FR-005, FR-022.

- **Decision 2 — Tool surface: two tools, each one call per turn.** `web_search(query)` returns
  ranked results (`{title, url, content, score}` — where `content` is Tavily's field name).
  `fetch_page(url)` returns readable extracted text,
  hard-truncated to the token budget. The model calls ONE tool per turn; intra-turn
  search→fetch chaining is spike-blocked (plugin history-omission bug + seam one-round-trip
  contract + budget arithmetic — see spike §4). Cross-turn chaining is user-driven ("read the 2nd
  result"). → FR-006, FR-007, FR-010, FR-011; Out of Scope.

- **Decision 3 — Toggle scope and precedence.** Two independent toggles:
  - **Global Settings toggle** (off by default): the master switch for web access across the whole
    app. When off, web tools are absent from the registry regardless of any per-conversation state.
  - **Per-conversation quick toggle** (in the composer): overrides the global default for a single
    conversation only. Global off + per-convo on ⇒ web access works for that conversation; the global
    default remains off for all other conversations. Global on + per-convo off ⇒ no web access for
    that conversation.
  - **Per-conversation toggle is THREE-STATE** (`inherit-global` / `explicitly-on` /
    `explicitly-off`), stored as a nullable enum in the conversation row (NULL = inherit-global).
    This is NOT a simple boolean. The effective toggle resolves to: per-conversation value if set
    (either direction), otherwise global default. An explicit per-conversation OFF overrides a
    global ON; an explicit per-conversation ON overrides a global OFF. See FR-006/FR-007 for the
    authoritative precedence rule.
  - Both toggle states persist in the conversation row. → FR-006, FR-007, FR-008.

- **Decision 4 — Persistence: metadata + source URLs only.** Persist the tool call (query or url),
  status (running/success/error), synthesized answer reference, and tappable source URL chips. Do NOT
  persist the full Tavily `content` body or fetch_page extracted text. URLs remain re-fetchable. →
  FR-020.

### Resolved by Phase 0 spike evidence (not re-asked — see spike-findings.md)

- **Snippets-only is the only viable strategy at E2B context.** After memory block + tool
  declarations + system instruction overhead, ~1,156 tokens remain. Three Tavily snippets (~305 tok)
  fits; a full-page fetch+answer chain exceeds the full budget by 3×. The `fetch_page` tool
  operates under two distinct bounds (see FR-014 for the authoritative distinction):
  (a) the extraction pipeline may retain up to ~4,000 tokens of readable text INTERNALLY (spike
  §2.2 kMaxExtractedTokens), but (b) the tool result returned to the model is hard-bounded at
  2,000 chars (~500 tokens) via `ToolSpec.resultCharBound`. The spec's authoritative contract is the
  2,000-char tool-result bound; the internal extraction limit is an implementation detail only.
  `fetch_page` is for explicit single-page reads, not chained post-search summarization.
  → FR-011, FR-014, FR-023.

- **Multi-step intra-turn chaining is architecturally non-viable** on flutter_gemma 0.15.3: plugin
  async-path history-omission bug + seam one-round-trip-per-turn contract + budget arithmetic all
  block it independently. The spec does not design for it. → Out of Scope, FR-024.

- **Constitution v2.0.0 Principle I governs all egress.** Opt-in, off by default, visibly indicated
  at egress time (tool chip naming Tavily), offline-degrading, auditable (persisted), named recipient.
  → FR-001, FR-002, FR-021.

### Residual open items

- **[NEEDS CLARIFICATION — SC-device-pending]** Quantitative success criteria for single-call
  capture rate and e2e latency reference `TODO(device)` — the A34 20-prompt harness run (spike §4,
  §5) has not yet been executed. Thresholds in SC-001, SC-002, SC-006 are marked
  `TODO(device: fill after harness run)`.

- **[NEEDS CLARIFICATION — Wikipedia fallback]** The spike recommended considering a zero-friction
  Wikipedia MediaWiki API fallback for users who do not paste a Tavily key (no onboarding, ToS-clean,
  encyclopedic/factual queries only). The product owner did not decide on this. This spec treats the
  Wikipedia path as out of scope for v1 but records it here for the plan phase.

---

## User Scenarios & Testing *(mandatory)*

### User Story 1 — Enable web research and get a grounded answer (Priority: P1)

A user who has pasted a Tavily key and enabled web research asks a question that benefits from live
information — "what's the latest Flutter release?", "summarize the Dart 3.5 migration guide". The
model calls `web_search(query)`, the tool fetches Tavily results, and the model answers from the
returned snippets. A tool chip shows `WEB_SEARCH · Tavily` with the query and status. Tappable
source URL chips appear beneath the response. No silent network call; the user always sees exactly
what query was sent and to whom.

**Why this priority**: This is the feature's core happy path — grounded answers from a live search.
It is the end-to-end value proposition and the lowest-risk P1 slice (one tool call, one turn, all
other mechanisms follow from it).

**Independent Test**: With a valid Tavily key set, global web toggle on (or per-conversation toggle
on), and a tool-capable model active, send 8–10 web-research-worthy prompts; verify each produces a
`WEB_SEARCH · Tavily` chip, a grounded text answer, and tappable source URL chips.

**Acceptance Scenarios**:

1. **Given** a Tavily key is stored, web access is enabled (global or per-conversation), and a
   tool-capable model is active, **When** the user asks "what's the latest Flutter release?", **Then**
   a `WEB_SEARCH · Tavily` running chip appears, transitions to success, the model's answer cites
   search result content, and ≥ 1 tappable source URL chip appears below the response.

2. **Given** the same setup, **When** the user asks "what is 17×23?", **Then** no web_search call is
   made (the model answers from its own knowledge) and no tool chip appears.

3. **Given** the same setup, **When** `web_search` returns results with a non-empty `content` field
   (Tavily's pre-extracted text), **Then** the final answer is grounded in at least one result's
   content and the source URL chips correspond to the returned results.

4. **Given** web access is off (global toggle off AND no per-conversation override), **When** the
   user asks any question, **Then** no web tool is declared or called; the model answers from its
   own knowledge with no tool chip.

---

### User Story 2 — Opt in to web research and understand the privacy implications (Priority: P1)

A new user opens Settings and sees the web research section for the first time. The toggle copy
plainly states what will leave the device and who receives it. The user makes an informed opt-in
decision: they paste their Tavily API key and flip the toggle on. The UI confirms the key is stored
(not shown after entry). The user understands that turning this on will send their search queries to
Tavily's servers, and that fetching a page makes a DIRECT request from their device to that target
website (not via Tavily).

**Why this priority**: Constitution v2.0.0 Principle I makes the informed opt-in moment a hard
requirement, not a polish item. Privacy copy and key management form the trust contract; they must
exist before the feature is usable.

**Independent Test**: Install the app fresh; navigate to Settings; verify the web research toggle is
off, the microcopy names Tavily and describes what leaves the device, the key entry field is present,
and the toggle cannot be turned on without a key (or gracefully prompts for one).

**Acceptance Scenarios**:

1. **Given** the app is freshly installed, **When** the user opens Settings → Web Research, **Then**
   the master toggle is off, the key field shows no stored key, and the toggle copy reads (lowercase,
   design-system voice) something equivalent to: "search queries are sent to tavily's servers. when
   you fetch a page, your device contacts that website directly — not tavily. your key never leaves
   your device." (exact copy TBD per design; MUST name Tavily for search, MUST disclose the direct
   target-website contact for fetch_page, MUST state the key stays on device — per FR-002).

2. **Given** the web research settings screen is open, **When** the user enters a valid Tavily key
   and saves, **Then** the key is stored in EncryptedSharedPreferences, is NOT shown again in plain
   text (masked after save), is NOT written to the SQLite conversation DB or any log, and the toggle
   can now be turned on.

3. **Given** no Tavily key is stored, **When** the user attempts to turn the master toggle on,
   **Then** a clear prompt to enter a key appears and the toggle remains off until a key is saved.

4. **Given** a key is stored, **When** the user taps "clear key", **Then** the key is removed from
   EncryptedSharedPreferences, the toggle turns off, and web tools behave as if no key is set.

---

### User Story 3 — Use the per-conversation toggle to enable web research for one chat (Priority: P2)

A user who keeps web research off globally wants to enable it for a specific conversation without
changing their global preference. The composer shows a web-access quick toggle. Turning it on for
that conversation grants web access for that chat only; all other conversations remain unaffected.
The composer clearly indicates when web access is active for the current conversation.

**Why this priority**: The per-conversation override is what makes the global-off default usable for
power users who want selective web access. It depends on US1 (the core web search path) and on US2
(the key already being set).

**Independent Test**: With global web toggle off and a valid key stored, open a new conversation,
enable the per-conversation toggle, send a web-research-worthy prompt, verify a web_search chip
appears; open a different conversation, verify no web chip appears (global default is off).

**Acceptance Scenarios**:

1. **Given** the global toggle is off and a valid key is stored, **When** the user enables the
   per-conversation toggle in the composer, **Then** a visual indicator shows web access is on for
   this conversation, the web tools become active for this conversation, and other open or new
   conversations remain web-off.

2. **Given** the global toggle is on, **When** the user disables the per-conversation toggle,
   **Then** web tools are absent for this conversation regardless of the global setting.

3. **Given** the per-conversation web toggle is on and the user sends a web-research prompt, **When**
   the response is generated, **Then** the tool chip and source chips appear as in US1 Scenario 1.

4. **Given** a conversation with per-conversation web access enabled, **When** the user closes and
   reopens that conversation, **Then** the per-conversation toggle state persists (the conversation
   remembers its override).

---

### User Story 4 — Read a specific page when the model suggests it (Priority: P2)

After a `web_search` response, the user asks the model to read one of the returned URLs — "read
the second result" or "fetch https://example.com/docs". The model calls `fetch_page(url)`, the tool
fetches and extracts readable text (hard-truncated to the token budget), and the model answers from
that content. A `FETCH_PAGE · [domain]` chip (e.g. `FETCH_PAGE · flutter.dev`) shows the URL and
status. The response shows a source chip for the fetched URL. Note: this call goes DIRECTLY to the
target website, not via Tavily.

**Why this priority**: `fetch_page` completes the two-tool surface and serves the "I want the full
article" use case. It is lower priority than `web_search` because it is an explicit cross-turn
user action (the user names the URL), not automatic, and the core value is already delivered by
snippets in US1.

**Independent Test**: After a web_search result, explicitly ask the model to fetch one of the
returned URLs; verify a `FETCH_PAGE · [domain]` chip appears (hostname matches the fetched URL),
the response references specific content from that page, and a source chip for the URL is shown.

**Acceptance Scenarios**:

1. **Given** web access is on and a prior `web_search` result is in context, **When** the user says
   "read the first result", **Then** the model calls `fetch_page(url)`, a `FETCH_PAGE · [domain]`
   running chip appears (e.g. `FETCH_PAGE · flutter.dev`), the model's answer is grounded in the
   page's extracted text, and a source chip for the fetched URL appears.

2. **Given** the model calls `fetch_page` on a page whose extracted text exceeds the token budget,
   **When** the result is processed, **Then** the text is hard-truncated at the handler level
   (≤ 2,000 chars per `ToolSpec.resultCharBound`) and the tool result includes a
   `[truncated: N items remaining]` indicator; the model still generates a coherent answer from the
   truncated excerpt.

3. **Given** `fetch_page` is called, **When** the extraction succeeds but the page has minimal
   content (e.g. a redirect or near-empty page), **Then** the tool returns what was found and the
   model answers honestly that the page had little content.

---

### User Story 5 — Offline or provider failure degrades cleanly (Priority: P1)

The device is in airplane mode, or the Tavily key has expired / hit its rate limit, or Tavily
returns a 5xx. The web tool call fails cleanly: a red error chip records the failure with a plain-
language reason (offline / key invalid / rate limit / provider error). The model is invited to answer
from its own knowledge. No crash, no retry storm, no raw JSON visible.

**Why this priority**: Constitution Principles I and II make graceful offline degradation a hard
requirement. The failure surface is always possible and must be safe before the feature ships.

**Independent Test**: With airplane mode enabled, send a web-research-worthy prompt with web access
on; verify a red error chip appears naming "offline", no network call is attempted, the model
answers from its own knowledge, and the app does not crash. Repeat with a deliberately bad key to
verify the "key invalid" error path.

**Acceptance Scenarios**:

1. **Given** web access is on and the device has no connectivity, **When** the user sends a prompt
   that triggers `web_search`, **Then** the tool returns an offline error, a red `WEB_SEARCH · Tavily`
   error chip appears with plain-language text (e.g. "offline — no connection"), the model is invited
   to answer from its own knowledge, and no retry is attempted automatically.

2. **Given** the stored Tavily key is invalid or revoked, **When** `web_search` is called, **Then**
   a red error chip appears (e.g. "tavily key invalid — check Settings"), the model answers from its
   own knowledge, and no partial result is used.

3. **Given** Tavily returns an HTTP 429 (rate limit), **When** the tool result is processed, **Then**
   a red error chip explains the rate limit, no automatic retry occurs, and the model answers from
   its own knowledge.

4. **Given** Tavily returns a 5xx server error or the request times out, **When** the tool result is
   processed, **Then** a red error chip records the failure, no crash occurs, and the model falls back
   to its own knowledge.

5. **Given** web access is off (global and per-conversation), **When** the device goes offline,
   **Then** the app behaves exactly as it did before this feature — no degradation, no change.

---

### User Story 6 — Web research history persists and renders correctly (Priority: P2)

A conversation containing `web_search` and `fetch_page` tool chips and source URL chips is closed
and reopened. The chips render in place with their query/url, status, and source URLs. The full
Tavily snippet bodies and extracted page text are NOT stored (per Decision 4). Source URLs are
tappable and link to the original pages.

**Why this priority**: History fidelity is a trust requirement — the user needs to know what the
assistant searched and where it got its answers. It mirrors 004/005 tool chip persistence and reuses
those patterns directly.

**Independent Test**: Generate a web_search response with source chips; close and reopen the app;
verify the chips and source URLs render, the query text is correct, tapping a source URL opens the
browser, and no full snippet text was persisted.

**Acceptance Scenarios**:

1. **Given** a conversation containing web_search and source chips, **When** the user closes and
   reopens the app, **Then** the chips render in place with the original query, success status, and
   tappable source URLs intact.

2. **Given** the same conversation, **When** the user taps a source URL chip, **Then** the URL
   opens in the device's default browser (android_intent_plus or equivalent).

3. **Given** the conversation's stored data, **When** inspected, **Then** the tool_args and
   tool_result columns contain only the query/url and status; the full Tavily `content` body and
   extracted page text are absent.

4. **Given** a web_search error chip in history, **When** the conversation is reopened, **Then**
   the error chip renders with the original error reason (offline / key invalid / etc.).

---

### User Story 7 — Web tools are absent when capability or key is missing (Priority: P2)

A non-tool-capable model is active, or the user has not entered a Tavily key, or the toggles are
both off. In all cases, `web_search` and `fetch_page` are NOT declared to the model — they are
structurally absent from the registry, not refused at runtime. The chat behaves exactly as it did
before this feature. No silent tool failure.

**Why this priority**: Structural gating (tools absent from the registry) is the constitution-safe
path and mirrors the 004/005 pattern exactly. It protects existing chat flows from regression.

**Independent Test**: With a non-tool-capable model, or with no key set, or with both toggles off,
send prompts that would otherwise trigger web search; verify zero web tool chips appear, zero network
calls are made, and behavior is identical to pre-006.

**Acceptance Scenarios**:

1. **Given** the active model does NOT declare function calling, **When** any prompt is sent,
   **Then** no web tools are declared, no web chip appears, and chat behavior is byte-for-byte
   identical to pre-006.

2. **Given** the active model DOES declare function calling BUT no Tavily key is stored, **When**
   any prompt is sent, **Then** the web tools are absent from the registry (same effect as toggle
   off); the model behaves as if web research does not exist.

3. **Given** a valid key and tool-capable model, but both global toggle and per-conversation toggle
   are off, **When** any prompt is sent, **Then** the web tools are absent from the registry — not
   refused, absent.

4. **Given** a conversation history containing web chips from a prior session (e.g. key previously
   set), **When** the conversation is reopened under any model or capability state, **Then** the
   historical web chips still render in place (history outlives capability, per 004/005 precedent).

---

### User Story 8 — Raw tool-call text never renders; failures are honest chips (Priority: P3)

The 004 LeakFilter applies unchanged. If the model emits raw JSON tool-call syntax into the stream,
none of it renders as text — only the parsed chip. Invalid tool args (missing query, invalid url
format), handler errors, and malformed results all degrade to red error chips with plain-language
reasons. The assistant still produces a text reply.

**Why this priority**: This is defense-in-depth against the 004 raw-JSON-leak hazard and prevents
confusing raw machine text from appearing to users. It is inherited behavior from 004/005; the
same seam covers it.

**Independent Test**: Force each failure path via test seam (missing query arg, malformed url,
handler exception); verify red error chip + text reply + no raw JSON rendered for each.

**Acceptance Scenarios**:

1. **Given** `web_search` is called without a query arg or with an empty query, **When** the
   dispatcher validates it, **Then** a red error chip records the validation failure, the search is
   not attempted, and the model replies in text.

2. **Given** `fetch_page` is called with a malformed or non-HTTP(S) URL, **When** the dispatcher
   validates it, **Then** a red error chip records the reason and no fetch is attempted.

3. **Given** the model emits raw tool-call JSON into the text stream, **When** rendered, **Then** the
   LeakFilter suppresses it entirely — no raw `{"function_call":...}` text is visible.

4. **Given** any web tool call that fails at the handler level (network exception, parse failure),
   **When** the failure is returned, **Then** a red chip records it, no crash occurs, and the model
   still produces a text reply.

---

### Edge Cases

- **No key set + toggle turned on via per-conversation override**: web tools remain absent (no key =
  no tools, regardless of toggle state). A prompt in the composer area explains the key requirement.
- **Key set but toggle off globally and no per-conversation override**: web tools are absent from the
  registry; no call is made; no indication in the chat UI (web is just not available).
- **web_search returns zero results**: the tool returns an empty results array; the model is informed
  there were no results and answers from its own knowledge; a success chip with "0 results" is shown.
- **Tavily `content` field is empty**: fall back to title + url only; the token budget arithmetic
  still holds; the model indicates limited context is available.
- **fetch_page called on a page with JS-only rendering**: the Dart HTML parser receives a near-empty
  HTML body; extraction returns what it can (title, any static text) and flags it; the model answers
  honestly.
- **fetch_page on a non-HTML resource (PDF, binary)**: the extractor detects content-type mismatch
  and returns an error chip rather than garbage text.
- **Very long query string**: bounded at the handler level (e.g. ≤ 400 chars); over-length → red
  error chip, no call made.
- **Model calls web_search AND fetch_page in the same turn**: the seam's one-round-trip contract
  means the second call is chipped-and-skipped, consistent with 004 §4.3 behavior. The chip records
  "call skipped — one tool per turn".
- **Per-conversation toggle state in a new conversation**: inherits the current global default; the
  quick toggle starts in the global default state and can be overridden.
- **History chips with no active key**: source URL chips still render and tap to open browser; the
  missing key only affects new searches, not rendering of historical results.
- **Rate limit hit mid-conversation**: subsequent web tool calls in the same conversation also fail
  with the rate-limit error chip until the limit resets; the model continues answering from its own
  knowledge in the meantime.
- **Very large Tavily response (more than 3 results)**: the handler limits to top 3 results before
  constructing the tool result, to stay within the token budget.

---

## Requirements *(mandatory)*

### Functional Requirements

**Opt-in & Privacy (Constitution v2.0.0 Principle I)**

- **FR-001**: Web research MUST be OFF by default (global toggle default state = off). No search
  query or URL MUST leave the device unless the user has explicitly enabled web access via the global
  or per-conversation toggle and a valid API key is stored.

- **FR-002**: The Settings web research section MUST display plain-language microcopy (lowercase,
  design-system voice) that names BOTH external recipients and describes precisely what leaves the
  device to each one. The copy MUST state: (a) search queries are sent to Tavily's servers (via
  the Tavily Search API); (b) when you fetch a page, your device makes a DIRECT HTTP request to
  that page's website — the target website receives your IP address and request, and this request
  does NOT go through Tavily; (c) the user's API key never leaves the device. Exact copy is a
  design artifact; these content requirements are mandatory and non-negotiable under Constitution
  v2.0.0 Principle I (named recipient per egress path).

- **FR-003**: The user's Tavily API key MUST be stored in Android EncryptedSharedPreferences
  (AES-256, Keystore-backed). The key MUST NOT appear in the SQLite conversation DB, logs, crash
  reports, or any persisted file. After initial entry, the key MUST be masked in the UI (not shown
  in plain text).

- **FR-004**: The key MUST be clearable by the user. Clearing the key MUST remove it from
  EncryptedSharedPreferences and return web tool availability to "no key — tools absent" state;
  the global toggle MUST also turn off when the key is cleared.

- **FR-005**: A missing or empty key MUST make the web tools behave exactly as if the toggle were
  off: no tools are declared, no network call is made. When the user enables a toggle without a
  key, the app MUST surface a clear, actionable prompt to enter the key (not a silent no-op or a
  crash).

**Double gating — toggle + capability**

- **FR-006**: Web tools (`web_search`, `fetch_page`) MUST be declared to the model ONLY when ALL
  of the following are true simultaneously: (a) the active model's `capabilities.functionCalling`
  is true, (b) a valid Tavily key is stored, AND (c) the EFFECTIVE web access toggle resolves to
  ON for the current conversation (see FR-007 for the three-state resolution rule). If any
  condition is false, the tools are ABSENT from the registry (not refused at runtime — structurally
  absent, consistent with the 004 capability-seam `StateError` guard pattern). The condition is a
  three-way AND, NOT a two-boolean OR over global and per-conversation flags.

- **FR-007**: The per-conversation toggle is THREE-STATE: `inherit-global` (NULL, default for new
  conversations) / `explicitly-on` / `explicitly-off`. The EFFECTIVE toggle is resolved as follows:
  - If the per-conversation override is `explicitly-on`: web access is ENABLED for that
    conversation, regardless of the global toggle value.
  - If the per-conversation override is `explicitly-off`: web access is DISABLED for that
    conversation, regardless of the global toggle value. An explicit per-conversation OFF
    OVERRIDES a global ON.
  - If the per-conversation override is `inherit-global` (NULL): the global `webAccessEnabled`
    flag applies.
  This is NOT a two-boolean OR. The global toggle is the default that applies only when no
  per-conversation override is set. The global toggle CANNOT be bypassed by the per-conversation
  state — the global toggle is the default, and the per-conversation override supersedes it
  bidirectionally (on OR off). The per-conversation quick toggle in the UI represents this
  three-state enum, not a simple boolean.

- **FR-008**: The per-conversation quick toggle MUST be accessible from the composer area without
  navigating to Settings. Its initial state for a new conversation MUST inherit the current global
  default. Its state MUST persist in the conversation row and survive app restarts.

- **FR-009**: Toggling web access off (global or per-conversation) while in a conversation MUST
  make the tools absent from the registry immediately (at the next model-call boundary). No
  mid-generation tool calls are retroactively revoked; the toggle applies from the next user turn.

**Tool surface — web_search**

- **FR-010**: `web_search(query: string)` MUST call the Tavily Search API with the user-supplied
  key and return the top ≤ 3 results. Tavily's response schema uses the field name `content` (NOT
  `snippet`) for the pre-extracted text excerpt. The tool result exposed to the model uses the
  normalized schema `{title, url, content, score}`, mapping directly from Tavily's `content` field.
  No internal renaming to "snippet" is permitted; any serialization layer MUST use `content` as the
  key to avoid ambiguity. The handler MUST limit results to 3 before constructing the tool result
  to stay within the token budget.

- **FR-011**: The combined tool result for `web_search` MUST fit within a pre-truncation budget of
  ≤ ~305 tokens (approximately 1,220 chars including JSON envelope + 3 titles/URLs + ~300 chars of
  `content` per result). The handler MUST apply content-length guards before returning.

- **FR-012**: Every `web_search` call MUST render as a `WEB_SEARCH · Tavily` tool chip in the
  004 design-system treatment, showing the query string, with running/success/error states. The chip
  MUST name the recipient ("Tavily") — no silent network egress.

- **FR-013**: A successful `web_search` response MUST produce ≥ 1 tappable source URL chip beneath
  the model's final text answer, one per result URL returned. Tapping a source chip MUST open the
  URL in the device's default browser.

**Tool surface — fetch_page**

- **FR-014**: `fetch_page(url: string)` MUST accept an HTTP or HTTPS URL, fetch the page via the
  NetworkResearchService, and extract readable text using the Dart HTML pipeline (priority-order DOM
  selection: article > main > [role="main"] > class/id heuristics > body; boilerplate removal;
  Wikipedia p-only; link-density guard). **Two distinct bounds apply — both are required:**
  (a) **Internal extraction limit**: the pipeline MAY retain up to ~4,000 tokens of readable text
  internally (per spike §2.2 `kMaxExtractedTokens`) before applying the tool-result bound.
  (b) **Tool-result bound (authoritative)**: the text returned to the model as the `fetch_page`
  tool result MUST be hard-truncated to ≤ 2,000 chars (~500 tokens) via `ToolSpec.resultCharBound`.
  This 2,000-char figure supersedes the draft 1,500-char figure that appeared in earlier planning
  notes. A `[truncated: N items remaining]` marker MUST be appended when truncation occurs. An
  implementer MUST NOT use 1,500 chars as the tool-result bound.

- **FR-015**: `fetch_page` MUST validate the url arg: non-HTTP(S) schemes, empty or malformed URLs
  MUST produce a validation error chip without making a network call.

- **FR-016**: Every `fetch_page` call MUST render as a `FETCH_PAGE · [domain]` tool chip (where
  `[domain]` is the hostname extracted from the requested URL, e.g. `FETCH_PAGE · flutter.dev`)
  showing the URL (truncated for display if long), with running/success/error states. The chip MUST
  name the actual target website — NOT "Tavily" — because `fetch_page` makes a direct HTTP GET to
  the target site, bypassing Tavily entirely.

- **FR-017**: A successful `fetch_page` response MUST produce a tappable source URL chip for the
  fetched page beneath the model's final text answer.

**Network service seam**

- **FR-018**: ALL HTTP/search/extraction logic MUST be owned by a single `NetworkResearchService`
  (or equivalent) seam in `lib/infrastructure/network/`. No other layer (widget, provider, domain
  class) may make network calls directly. This mirrors the GemmaService discipline (Principle VII).

- **FR-019**: The network service MUST surface typed errors for all failure modes:
  - `OfflineError` — no connectivity detected before or during the call
  - `KeyInvalidError` — HTTP 401/403 from Tavily (bad or expired key); subtype of `ProviderError`
  - `RateLimitError` — HTTP 429 from Tavily; subtype of `ProviderError`
  - `ProviderError` — any other 4xx/5xx from Tavily's API (covers the above subtypes)
  - `FetchDomainError` — DNS/TCP/TLS failure or non-2xx HTTP response from the TARGET WEBSITE
    during `fetch_page` (distinct from `ProviderError` — this is not a Tavily failure)
  - `TimeoutError` — request exceeds the configured timeout (either Tavily or target website)
  - `ExtractionError` (`ParseError`) — fetch_page fetch succeeded but HTML parsing produced no
    usable content
  Each error type MUST map to a distinct plain-language message shown in the red error chip. See
  FR-034 for the complete authoritative error taxonomy including the `FetchDomainError` rationale.

**Offline degradation**

- **FR-020**: When connectivity is absent (Principle II), a web tool call MUST return an `OfflineError`
  immediately (no retry). The model MUST be given a prompt to answer from its own knowledge.
  The app MUST NOT crash, hang, or enter a retry loop.

- **FR-021**: With web access off (any combination of toggles, missing key, or non-tool-capable
  model), the app MUST function identically to pre-006 — no behavioral change, no network calls,
  no new UI elements.

**Visible indication (Constitution Principle I)**

- **FR-022**: Every web tool call MUST render a chip that names the TRUE external recipient before
  or at the moment the network call is made. No web egress may be silent. Specifically:
  `web_search` chips name "Tavily" (the call goes to Tavily's API); `fetch_page` chips name the
  target website's hostname (the call goes directly to that site, not Tavily). The chip MUST
  transition to success or error on completion. This directly implements Constitution v2.0.0
  Principle I (named recipient per egress path).

- **FR-023**: The chip's running state MUST be visible before the request completes (optimistic
  render), so the user always knows a network call is in progress.

**Persistence (Decision 4)**

- **FR-024**: Tool calls MUST be persisted in the conversation history using the 004 tool-turn
  persistence schema (`role='tool'`, `tool_name`, `tool_args`, `tool_status`, `tool_result`
  columns). The `tool_args` MUST contain the query or url. The `tool_result` MUST contain status
  and source URL list. The full Tavily `content` bodies and fetch_page extracted text MUST NOT be
  persisted in the DB.

- **FR-025**: Source URL chips MUST be persisted in the conversation and render correctly on
  history load, with tappable links intact, regardless of the current web access toggle state or
  key availability.

**LeakFilter and failure handling**

- **FR-026**: The 004 LeakFilter MUST apply to `web_search` and `fetch_page` tool calls — raw
  machine-format tool-call JSON MUST NOT render as text in the chat stream.

- **FR-027**: Any invalid tool call (bad args, validation failure, handler exception) MUST
  produce a red error chip with a plain-language reason + an honest text reply from the model.
  No crash, no silent loss.

- **FR-028**: A second tool call emitted by the model within a single user turn MUST follow the
  004 chip-and-skip behavior (chip rendered, not executed), consistent with the seam's
  one-round-trip contract.

**Design system**

- **FR-029**: All new UI (web tool chips, source URL chips, Settings toggle + microcopy, composer
  quick toggle) MUST use centralized design tokens (no hardcoded colors/fonts). Destructive or
  error states use the sanctioned red (#D71921). Microcopy is lowercase. Interactive elements meet
  the 48dp touch-target and WCAG AA contrast floors (Principle VI).

**Drift schema migration**

- **FR-030**: A new drift migration (schema version 5→6) MUST be added that:
  (a) adds a nullable `webAccessOverride` column (enum: `inherit` | `on` | `off`, stored as TEXT,
  default NULL) to the conversation table — NULL means "inherit global"; and
  (b) adds a `webAccessEnabled` boolean flag (default false) to the app_settings table.
  The migration MUST be additive and idempotent (no data loss on existing rows). Existing
  conversation rows MUST default to NULL (inherit-global) and existing app_settings rows MUST
  default to false. The migration MUST be covered by a `migration_v5_test.dart` seed file
  (seeding the v5 schema) and a corresponding migration test that verifies v5→v6 applies cleanly
  and defaults are correct.
  **Migration test-seed gotcha (house rule)**: any prior `migration_v*_test` seed that touches the
  conversation table or the app_settings table MUST be updated to include the new columns (with
  their appropriate defaults) AND the `schemaVersion` asserts in those tests MUST be bumped to
  match. Failure to do this silently breaks older seeds (per drift migration test-seed gotcha in
  project memory). The `@TableIndex` annotation for any new index MUST include an explicit
  `m.createIndex` call in the migration step.

**Query-length guard**

- **FR-031**: `web_search` MUST reject queries that are empty, whitespace-only, or longer than 400
  characters BEFORE any network call is made. A rejected query MUST produce a red error chip with
  a plain-language reason (e.g. "query too long — max 400 characters" or "query is empty"), and
  the Tavily API MUST NOT be contacted. This guard is applied at the dispatcher/handler level, not
  the model-call level, and is separate from the general invalid-arg handling in FR-027.

**Mid-conversation toggle change — session recreation required**

- **FR-032**: Toggling web access on or off for an ALREADY-OPEN conversation (where a LiteRT-LM
  session is live) MUST take effect by RECREATING the chat session before the next tool call is
  made. Tool declarations are baked into the LiteRT-LM session at creation time (analogous to the
  005 facts-refresh session-recreation precedent in `spec.md §Clarifications`). A simple in-place
  toggle MUST NOT be silently applied to a live session, as the tool declaration set would be
  stale. The required behavior: when the user changes the per-conversation web toggle while a
  session is open, the app MUST close the current session (per the 005 "close session first"
  pattern) and recreate it with the updated tool declarations before the next user turn is
  processed. No user data is lost; conversation history is replayed into the new session normally.

**web_search zero-results handling**

- **FR-033**: A successful `web_search` call that returns 0 results (empty results array from
  Tavily) MUST NOT crash, silently hang, or produce an error chip. Instead: a success chip MUST
  render indicating "0 results" (e.g. `WEB_SEARCH · Tavily — 0 results`), and the tool result
  payload given to the model MUST be an empty results array with a clear message such as
  "no results found — answering from own knowledge". The model MUST be able to respond from its
  own knowledge or suggest the user rephrase the query. No source URL chips appear for a
  zero-result call.

**Error taxonomy — fetch_page target-site errors**

- **FR-034**: The typed error taxonomy in the `NetworkResearchService` seam (see FR-019) MUST
  include a distinct `FetchDomainError` type for failures that occur when contacting the TARGET
  WEBSITE during a `fetch_page` call (e.g. DNS resolution failure, TCP/TLS handshake failure, or a
  non-2xx HTTP response from the target site). `FetchDomainError` is SEPARATE from `ProviderError`
  (which covers Tavily 4xx/5xx responses). The complete error taxonomy for this feature is:
  - `OfflineError` — no connectivity detected before or during any network call
  - `ProviderError` — bad/expired key (HTTP 401/403), rate-limit (HTTP 429), or any other
    Tavily 4xx/5xx response during `web_search` (covers `KeyInvalidError` and `RateLimitError`
    as subtypes; see FR-019 for the subtype breakdown)
  - `FetchDomainError` — DNS/TCP/TLS failure or non-2xx response from the TARGET WEBSITE
    during `fetch_page` (not a Tavily error)
  - `ParseError` (equivalent to `ExtractionError` in FR-019) — fetch_page succeeded but the
    HTML extraction pipeline produced no usable content
  - `TimeoutError` — any request exceeded the configured timeout
  Each error type MUST map to a distinct plain-language message in the red error chip, and MUST
  clearly distinguish Tavily failures from target-website failures to the user.

---

### Key Entities *(include if feature involves data)*

- **Web search tool call**: one invocation of `web_search` — `tool_name` ("web_search"),
  `tool_args` (query string), `tool_status` (running/success/error), `tool_result` (list of
  `{title, url}` plus error type/message). The in-flight tool result schema (exposed to the model)
  is `{title, url, content, score}` where `content` maps directly from Tavily's `content` field.
  Persisted as a `role='tool'` message row in the conversations DB. The full `content` body is NOT
  persisted — only `{title, url}` metadata is stored.

- **Fetch page tool call**: one invocation of `fetch_page` — `tool_name` ("fetch_page"),
  `tool_args` (url), `tool_status`, `tool_result` (status + source url + extraction notes, NOT
  the extracted body text).

- **Source URL chip**: a rendered, tappable URL associated with a completed `web_search` or
  `fetch_page` result. Persisted as part of the tool result metadata.

- **Tavily API key**: a user-supplied string stored in Android EncryptedSharedPreferences.
  Never persisted in SQLite, never logged, never shown in plain text after initial entry.

- **Web access toggle state**: two persisted flags — (a) global `webAccessEnabled` (default false)
  in the app settings row; (b) per-conversation `webAccessOverride` (null/inherit | on | off) in
  the conversation row.

- **NetworkResearchService**: the seam that owns ALL HTTP calls for this feature (search,
  fetch, extraction). Testable via a fake/mock — no widget or provider may call it directly.

- **App settings (existing)**: gains a persisted `webAccessEnabled` flag (default false).

- **Conversation (existing)**: gains a `webAccessOverride` field (nullable enum:
  inherit/on/off) in the conversation row.

---

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: On a scripted ≥ 20-prompt evaluation suite (fact-seeking, current-events, and
  explicit fetch prompts), the shipped feature achieves `TODO(device: fill after A34 harness run —
  target ≥ 75% correct web_search tool selection on research-worthy prompts)` with zero crashes —
  on the reference A34 device. Reference: spike §4 GATE B threshold (≥ 6/8 single-call rate from
  the 20-prompt harness; device run pending).

- **SC-002**: E2E latency (send → final answer rendered) for a `web_search` + answer turn is
  `TODO(device: fill after A34 harness run — §5 latencyToFinalAnswer_ms measurement)`. The spec
  does not invent a number before the device run.

- **SC-003**: Zero spurious `web_search` / `fetch_page` calls on ≥ 5 junk/no-research prompts
  (arithmetic, chitchat, in-context questions) — parity with the spike §4 GATE B no-spurious-call
  threshold.

- **SC-004**: With airplane mode enabled, 100% of web tool call attempts produce a red error chip
  with the "offline" reason, zero network calls are observed, and the app does not crash.

- **SC-005**: With an invalid Tavily key, 100% of `web_search` / `fetch_page` calls produce a red
  error chip with a key-invalid reason. No partial result is used.

- **SC-006**: The combined tool result for `web_search` stays within ≤ ~1,220 chars (≤ ~305 tokens)
  in 100% of calls; `fetch_page` tool results (as returned to the model) stay within ≤ 2,000 chars
  (~500 tokens) — the `ToolSpec.resultCharBound` hard limit — in 100% of calls. The internal
  extraction pipeline may hold more text before applying this bound; the measurable criterion is the
  tool result size. Verified by handler-level content-length guards.

- **SC-007**: 100% of completed `web_search` and `fetch_page` calls produce ≥ 1 tappable source
  URL chip, and tapping opens the URL in the default browser in 100% of trials.

- **SC-008**: After closing and reopening the app, 100% of web tool chips and source URL chips
  render in place with correct query/url and status; no full snippet body text is found in the
  persisted DB rows.

- **SC-009**: With function calling off (non-tool-capable model configuration), zero web tool
  declarations are made and zero web chips appear; existing chat regression pass shows zero
  behavioral change.

- **SC-010**: With both toggles off (global off, no per-conversation override), zero web tool
  declarations and zero network calls are observed across any prompt type.

- **SC-011**: After clearing the API key, zero web tool declarations and zero network calls are
  observed; the global toggle returns to off state.

- **SC-012**: Raw tool-call JSON never appears in the rendered text stream for any web tool call
  — LeakFilter verified in 100% of trials.

- **SC-013**: Every new interactive element passes the 48dp touch-target and AA contrast audit
  before release (Principle VI).

- **SC-014**: A code/network audit confirms ALL network calls from this feature go through the
  `NetworkResearchService` seam and zero other code paths make HTTP calls for search or fetch;
  `check_network_seam.sh` (or equivalent) stays green.

- **SC-015**: A code/network audit confirms the Tavily API key is never written to the SQLite
  DB, any log file, or any crash-reporting path.

---

## Assumptions

- **Spike tool name superseded**: spike §4.5 sketched a single `web_search_and_summarize` tool as
  a combined alternative. That sketch is SUPERSEDED by the locked two-tool decision (`web_search` +
  `fetch_page`, Decision 2 above). Readers of both docs should use this spec's two-tool design as
  the authoritative contract; the spike's single-tool sketch is historical only.

- flutter_gemma 0.15.3 on the A34 behaves consistently with the spike: one tool call per turn,
  async-path history-omission bug present, `resumeWithToolResult` seam unchanged. Any plugin version
  bump requires re-running the spike gate.

- The A34 20-prompt harness run (spike §4/§5 `TODO(device)`) will confirm the snippets-only
  single-call architecture before implementation begins. Success criteria with `TODO(device)`
  markers will be filled in after that run.

- The Tavily API is reachable from a standard Android device with a user-supplied key. Tavily's
  `content` field provides pre-extracted clean text; the spec does not depend on a secondary
  Tavily fetch-extract endpoint.

- The existing `ContextAssembler` budget arithmetic from the spike (§3) holds: ~1,156 tokens
  remain after memory block + tool declarations + system instruction. The two web tools add ~80
  tokens of declarations, which is accounted for.

- The `html` Dart package (`^0.15.6`) can parse static HTML from mainstream pages without a
  JavaScript runtime. JS-rendered pages (which return near-empty HTML bodies) are out of scope.

- The existing 004/005 tool-chip UI, `role='tool'` message persistence, LeakFilter, and
  dispatcher schema validation are reused without structural changes. `web_search` and
  `fetch_page` are added to the existing ToolRegistry.

- English-language prompts are the testing baseline (consistent with 001–005).

- The reference device (Samsung A34) and installed Gemma 4 E2B artifact remain the verification
  baseline.

---

## Dependencies

- **Phase 0 spike (partially PASSED)** — `specs/006-web-research/spike-findings.md`:
  - PASSED: provider landscape, extraction pipeline design, budget arithmetic (snippets-only),
    chain feasibility (source inspection).
  - PENDING: A34 20-prompt harness run (GATE B, §4/§5 `TODO(device)`) — required before
    implementation begins to fill SC-001/SC-002.

- **004 (function calling)**: ToolRegistry, ToolDispatcher, strict schema validator,
  `GenerationEvent` / `resumeWithToolResult` seam, seam-side capability `StateError` gate,
  LeakFilter, `role='tool'` message kind + tool chip, one-round-trip-per-turn contract. All
  reused directly. `web_search` and `fetch_page` are added to the existing registry.

- **005 (memory)**: facts block token consumption in the budget arithmetic; `memoryEnabled`
  gating pattern mirrored for web access toggle gating.

- **001–003**: conversation persistence + drift migration pattern, streaming/stop, context
  assembly, capability-gating-as-data, history-outlives-capability rendering.

- **App settings mechanism**: the global `webAccessEnabled` flag reuses the persisted
  single-row app-settings mechanism (like `themeMode`, `memoryEnabled`).

- **Conversation schema (existing)**: gains a `webAccessOverride` column (nullable) via a new
  drift migration (schema version 5→6 or next available).

- **Design system** (`.specify/memory/design-system.md`): tool-chip treatment, settings-row
  treatment, source URL chip design.

- **Android EncryptedSharedPreferences / Keystore**: for BYOK key storage (existing Android
  platform APIs; no new dependency needed if `flutter_secure_storage` or equivalent is already
  in the tree; add it if not).

- **Dart `html` package** (`^0.15.6`): HTML parsing for `fetch_page` extraction pipeline.

- **HTTP client**: a standard Dart HTTP client for the NetworkResearchService (e.g. `http`
  package, already likely present; confirm before adding a new dep).

---

## Out of Scope

- **Intra-turn search→fetch chaining**: spike-blocked by three independent constraints (plugin
  async-path history-omission bug + seam one-round-trip contract + context budget arithmetic).
  The model makes ONE tool call per turn; cross-turn chaining is user-driven. This is a hard
  constraint, not a deferral.

- **Full browsing agent**: multi-page crawling, link-following, recursive fetch, or any
  autonomous multi-step web navigation.

- **JavaScript-rendered pages**: the Dart HTML parser works on static HTML. Pages that require
  a JS runtime to produce their body content may return near-empty extraction results. No
  headless browser is included.

- **File downloads**: `fetch_page` targets readable HTML text pages only. PDFs, binary files,
  and non-HTML resources return an extraction error.

- **Image search**: web_search returns text results only; no image URLs or image search mode.

- **Multi-provider routing**: one provider (Tavily BYOK) in v1. No provider fallback, no
  provider switching UI, no Wikipedia fallback (decision deferred — see Clarifications residual).

- **Cloud sync, analytics, or telemetry**: no conversation data, queries, or results leave the
  device except via the explicit opted-in Tavily API call. No crash-reporting of query content.

- **Server-side proxy**: the Tavily call is direct from the device (BYOK). No backend, no
  reverse proxy, no Anthropic-side API aggregation.

- **Non-Android platforms** (Principle IX).

- **Brave Search, SerpAPI, or any other provider** beyond Tavily in v1 (spike §1 decision).

- **Per-conversation memory profiles**: out of scope (established in 005).

- **RAG, embeddings, or vector stores**: out of scope (constitution Principle IX boundary).
