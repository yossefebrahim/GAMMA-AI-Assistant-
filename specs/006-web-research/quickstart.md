# Quickstart — 006 Web Research device validation

On-device verification of the shipped feature. **`flutter run` / `flutter drive` ONLY — NEVER
`flutter test integration_test/...`** (it uninstalls the app and wipes the 2.4 GB model + DB). Raise
the screen timeout for long drives:

```
adb shell settings put system screen_off_timeout 1800000
adb shell svc power stayon true
# restore after:
adb shell settings put system screen_off_timeout 60000
adb shell svc power stayon false
```

Reference device: the A34 (SM-A346E, `192.168.9.2:45295`) with the installed Gemma 4 E2B
`.litertlm`. Prereqs: model installed; a tool-capable model active (default catalog model declares
function calling); a valid Tavily API key (obtain a free key at tavily.com — 1,000 credits/month,
no credit card required).

---

## How to add the Tavily key in Settings

1. Open Settings → Web Research.
2. Verify: the master toggle is OFF and the key field shows no stored key (fresh-install default,
   FR-001).
3. Read the microcopy: it must name Tavily as the search recipient, state that `fetch_page` makes a
   DIRECT request from your device to the target website (not via Tavily), and confirm the key never
   leaves the device (FR-002).
4. Tap the key field and paste your Tavily API key.
5. Save. The key is stored in Android EncryptedSharedPreferences (AES-256, Keystore-backed — FR-003).
   After saving, the field must show the key masked (not in plain text).
6. The master toggle can now be turned on. Confirm it stays off if you try to toggle it before
   saving a key (FR-005).
7. To clear the key later: tap "clear key" → the key is removed from encrypted storage, the master
   toggle turns off, and web tools become absent (FR-004).

---

## Functional walkthroughs

### V1 — Happy path: web_search (US1 / FR-010 / FR-012 / FR-013 / SC-001 / SC-007)

With a valid Tavily key stored and the global web toggle ON (or per-conversation toggle explicitly
on), send 8–10 research-worthy prompts, for example:

- "what's the latest Flutter stable release?"
- "summarize the Dart 3 migration guide"
- "what changed in the Android 15 developer preview?"

For each:
- A `WEB_SEARCH · Tavily` running chip appears before the request completes (optimistic render,
  FR-023).
- The chip transitions to success on completion.
- The model's answer is grounded in the returned search content (not fabricated from training data
  only).
- At least one tappable source URL chip appears beneath the model's final text answer (FR-013).
- Send "what is 17×23?" — no web_search chip appears (the model answers from its own knowledge,
  US1 AS-2).

### V2 — Happy path: fetch_page (US4 / FR-014 / FR-016 / FR-017)

After a `web_search` response that returned source URLs, ask the model to read one:

- "read the first result"
- "fetch https://flutter.dev/docs/get-started/install"

Expect:
- A `FETCH_PAGE · [domain]` running chip appears (e.g. `FETCH_PAGE · flutter.dev`). The domain in
  the chip is the hostname of the TARGET WEBSITE, not "Tavily" (FR-016).
- The chip transitions to success.
- The model's answer references specific content from that page.
- A tappable source URL chip for the fetched page appears beneath the answer (FR-017).
- If the extracted text exceeded 2,000 chars, the model's answer is based on the truncated excerpt
  and the chip or answer notes the truncation (FR-014 `[truncated: N items remaining]` marker).

### V3 — Settings: add, mask, edit, delete, clear-all key and toggle (US2 / FR-003 / FR-004 / FR-005)

1. Open Settings → Web Research on a fresh install. Confirm toggle off, no key stored.
2. Try to enable the toggle with no key — a clear prompt to enter the key appears and the toggle
   stays off (FR-005).
3. Enter a valid key and save — key is masked after save, NOT shown in plain text. Toggle can now
   be turned on.
4. Clear the key — key removed from storage, global toggle turns off, tools become absent (FR-004).
5. Re-add the key. Navigate away and return — the key remains masked (persistent, not shown again).

---

## Manual device script (toggle and precedence)

The steps below are written for `flutter run` interactive use. For automated runs use
`flutter drive` (see the spike harness section at the end).

### Step 1 — Toggle off: web tools structurally absent (US7 / FR-006 / SC-010)

**Setup**: global web toggle OFF, no per-conversation override. Key may or may not be stored.

1. Start a new conversation.
2. Ask: "what's the latest Flutter release?" (a research-worthy prompt).
3. **Expected**: the model answers from its own training knowledge. No `WEB_SEARCH` chip appears.
   No network call is made (FR-001, FR-006).
4. Ask: "search the web for current Android 15 features".
5. **Expected**: same — no chip, model answers from own knowledge or says it can't browse.
6. Confirm zero network calls are observed (SC-010).

_Tied to_: FR-001, FR-006, US7 AS-3, SC-010.

### Step 2 — Airplane mode: graceful degradation (US5 AS-1 / FR-020 / SC-004)

**Setup**: global web toggle ON, valid key stored. Enable airplane mode (swipe down → airplane
icon, or `adb shell cmd connectivity airplane-mode enable`).

1. Start a new conversation with web access on.
2. Ask: "what's the current Dart release?"
3. **Expected**:
   - A `WEB_SEARCH · Tavily` chip appears and transitions to a red error state.
   - The chip shows a plain-language offline reason, e.g. "offline — no connection" (FR-020).
   - The app does NOT crash, hang, or attempt a retry storm (FR-020, SC-004).
   - The model is prompted to answer from its own knowledge and produces a text reply (no crash,
     no spinner stuck indefinitely).
4. Send two more research prompts — confirm each also fails cleanly with a red offline chip. No
   retry loop fires (FR-020 "no retry" requirement).
5. Disable airplane mode and confirm web search resumes normally on the next prompt.

_Tied to_: FR-020, US5 AS-1, SC-004.

### Step 3 — Provider down / bad key: ProviderError chip (US5 AS-2 / FR-019 / SC-005)

**Setup**: deliberately enter an invalid Tavily key in Settings (e.g. `sk-invalid-test-key-12345`).
Global web toggle ON.

1. Start a new conversation.
2. Ask: "what's the latest Flutter release?"
3. **Expected**:
   - A `WEB_SEARCH · Tavily` chip appears and transitions to a red error state.
   - The error message names the reason clearly, e.g. "tavily key invalid — check Settings" or
     "provider error: unauthorized" (FR-019 `KeyInvalidError` path).
   - No partial result is used; the model answers from its own knowledge (US5 AS-2).
4. Optionally: to test HTTP 429 rate-limit path (SC-005), exhaust your Tavily free credits or use
   a seam injection in the test harness. Expect a red chip with a rate-limit message.
5. Restore a valid key in Settings and confirm the feature resumes.

_Tied to_: FR-019, US5 AS-2, SC-005.

### Step 4 — Per-conversation override precedence (US3 / FR-007 / FR-008 / FR-009)

This step validates all four meaningful cases of the three-state toggle (FR-007).

**Case 4a — Global OFF, per-conversation explicitly ON** (US3 AS-1):

1. Set global web toggle OFF in Settings.
2. Open a new conversation. Enable the per-conversation quick toggle in the composer (it starts in
   the `inherit-global` state = off, then you flip it to `explicitly-on`).
3. A visual indicator in the composer shows web access is on for this conversation.
4. Ask a research-worthy prompt. Expect a `WEB_SEARCH · Tavily` chip and a grounded answer.
5. Open a DIFFERENT new conversation (no per-conversation override). Confirm NO web chip appears
   (global default is still off).

**Case 4b — Global ON, per-conversation explicitly OFF** (US3 AS-2):

1. Set global web toggle ON in Settings.
2. Open a new conversation. Disable the per-conversation quick toggle (set to `explicitly-off`).
3. Ask a research-worthy prompt. **Expected**: no web chip — the per-conversation OFF overrides the
   global ON (FR-007).
4. Open another new conversation (no per-conversation override). Confirm web search DOES fire
   (inherits global ON).

**Case 4c — Toggle change mid-conversation (FR-032)**:

1. With a live conversation and web access on, flip the per-conversation toggle OFF.
2. Send the next prompt. **Expected**: the app recreates the chat session before the model call
   (per the 005 "close session first" session-recreation pattern — FR-032). Web tools are absent
   from the registry for this and subsequent turns in the conversation.

**Case 4d — Per-conversation override persists after restart** (US3 AS-4):

1. Set a conversation to per-conversation `explicitly-on` (global toggle OFF).
2. Kill and relaunch the app.
3. Reopen that conversation. Confirm the per-conversation toggle still shows ON and web search
   still works (override persisted in the conversation row, FR-008).

_Tied to_: FR-007, FR-008, FR-009, FR-032, US3 AS-1/2/4.

### Step 5 — Zero results (FR-033 / edge case)

**Setup**: global web toggle ON, valid key, live connectivity.

1. Ask the model an extremely niche or nonsense query designed to return no Tavily results, e.g.
   "asdfqwerty zxcvmnop current events 2026".
2. **Expected**:
   - The app does NOT crash (FR-033).
   - A success chip (NOT an error chip) appears with a "0 results" indication, e.g.
     `WEB_SEARCH · Tavily — 0 results` (FR-033).
   - The model is informed there were no results and responds from its own knowledge or suggests
     the user rephrase (FR-033).
   - No source URL chips appear beneath the answer (no results = no URLs).

_Tied to_: FR-033, edge-case "web_search returns zero results".

### Step 6 — Source URL chips are tappable (US1 AS-1 / FR-013 / FR-025 / SC-007)

1. With web access on, ask a research question that returns results (e.g. "what is Flutter?").
2. Confirm source URL chips appear beneath the model's answer.
3. Tap each source URL chip. **Expected**: the URL opens in the device's default browser
   (android_intent_plus or equivalent). Confirm the destination URL is the correct source page.
4. Confirm tapping opens the browser rather than crashing or navigating in-app.

_Tied to_: FR-013, FR-025, US1 AS-1, SC-007.

### Step 7 — Persistence across restart: metadata and URLs present, no body text (US6 / FR-024 / FR-025 / SC-008)

1. With web access on, run a `web_search` prompt (e.g. "latest Flutter release") and a
   `fetch_page` prompt (e.g. "fetch flutter.dev/docs"). Confirm both chips and source URLs appear.
2. Kill the app completely and relaunch.
3. Reopen the conversation.
4. **Expected**:
   - `WEB_SEARCH · Tavily` chip renders with the original query text and success status (FR-024).
   - `FETCH_PAGE · [domain]` chip renders with the original URL and success status (FR-024).
   - Tappable source URL chips are present and still open the browser (FR-025, SC-008).
   - The model's synthesized text answer is present.
   - **No full Tavily `content` body text** is stored or displayed — the persisted tool_result
     column contains only the query/URL and source URLs, not the snippet bodies (Decision 4,
     FR-024, SC-008).
5. If you have adb access, confirm: `adb shell "sqlite3 /data/data/<packageName>/databases/*.db \"SELECT tool_result FROM messages WHERE tool_name='web_search' LIMIT 5;\""` — the stored rows must contain only metadata (title, url, status), not full snippet bodies.

_Tied to_: FR-024, FR-025, US6 AS-1/2/3, Decision 4, SC-008.

---

## Cross-cutting gates

### V8 — Capability off: web tools structurally absent (US7 AS-1 / FR-006 / SC-009)

With a scratch build that forces `functionCalling: false` (or a non-tool-capable model
configuration):

1. Confirm NO `web_search` or `fetch_page` declarations are made (tools are structurally absent,
   not runtime-refused — FR-006).
2. Send research-worthy prompts. Confirm zero web chips appear.
3. Confirm existing text/image/audio chat is unchanged (zero behavioral regression).
4. Confirm the Settings web research toggle and the key field still render correctly (the Settings
   UI is not gated on function calling, only tool declaration is).

_Tied to_: FR-006, US7 AS-1, SC-009.

### V9 — No key stored: tools absent regardless of toggle (US7 AS-2 / FR-005 / FR-006 / SC-011)

1. Clear the Tavily key from Settings.
2. Confirm the global web toggle turns off (FR-004).
3. Try to enable the global toggle — confirm the app surfaces a clear prompt to enter a key and
   the toggle does not turn on (FR-005).
4. Send a research-worthy prompt. Confirm no web tool chips appear and no network call is made
   (FR-005 / FR-006 — tools absent, not refused).

_Tied to_: FR-004, FR-005, FR-006, US7 AS-2, SC-011.

### V10 — Raw JSON leak: LeakFilter verified (US8 / FR-026 / SC-012)

1. Force each web-tool failure path via the test seam or by sending edge-case inputs:
   - Empty or whitespace-only query (FR-031 guard).
   - Query over 400 characters (FR-031 guard).
   - Malformed URL passed to fetch_page (e.g. `not-a-url` or `ftp://example.com`, FR-015).
2. For each: confirm a red error chip appears with a plain-language reason, the model still
   produces a text reply, and NO raw `{"function_call":...}` JSON appears in the rendered text
   stream (FR-026 LeakFilter, SC-012).

_Tied to_: FR-015, FR-026, FR-027, FR-031, US8, SC-012.

### V11 — Accessibility (FR-029 / SC-013)

Run Accessibility Scanner over:
- The Settings → Web Research screen (toggle, key field, microcopy, clear-key button).
- The composer web quick-toggle.
- A completed conversation containing web_search chips and source URL chips.

Confirm: 48dp touch targets on all interactive elements, WCAG AA contrast throughout, error/delete
states use the sanctioned red (#D71921), all microcopy is lowercase per design-system voice.

_Tied to_: FR-029, SC-013.

### V12 — Network seam audit (FR-018 / SC-014 / SC-015)

1. Confirm ALL network calls for web search and fetch_page route through `NetworkResearchService`
   in `lib/infrastructure/network/`. No widget, provider, or domain class makes HTTP calls
   directly (FR-018).
2. Search the DB and logs for the Tavily API key string. Confirm it never appears in the SQLite
   conversation DB, any log file, or crash-report payload (FR-003, SC-015).

_Tied to_: FR-003, FR-018, SC-014, SC-015.

---

## Reliability gate: the A34 20-prompt harness (spike GATE B — `flutter drive`)

This is the device measurement that unblocks the spec's open `TODO(device)` thresholds in
SC-001, SC-002, and SC-003. Run it on the A34 before considering the feature shippable.

**Harness location**: `specs/006-web-research/spike-harness/` (copy into `integration_test/`
before running; mark DO NOT SHIP; remove before merge per 004/005 precedent).

```
adb shell settings put system screen_off_timeout 600000
adb shell svc power stayon true
flutter drive \
  --driver=test_driver/integration_test.dart \
  --target=integration_test/spike_web_research_test.dart \
  -d 192.168.9.2:45295 \
  2>&1 | tee spike_web_research_run.log
grep '@@WEB@@' spike_web_research_run.log
adb shell settings put system screen_off_timeout 60000
adb shell svc power stayon false
```

**What to record** (feeds SC-001, SC-002, SC-003):

| Measurement | Gate threshold | Filled after run |
|---|---|---|
| web_search single-call correct selection (T01–T08, 8 search-worthy prompts) | ≥ 6/8 (≥ 75%) | `TODO(device)` — SC-001 |
| Spurious calls on junk prompts (T17–T20, 5 prompts) | 0 spurious | SC-003 |
| Second-call-fired rate (chain signal, T09–T16) | ≤ 1/8 | SC-003 / §4 GATE B |
| `latencyToFinalAnswer_ms` per trial | `TODO(device)` — no invented number | SC-002 |
| `rawTextLeak` | 0 / 20 trials | SC-012 |
| App crash count | 0 | SC-001 |

The harness emits `@@WEB@@`-prefixed JSON lines for easy extraction. Full protocol is in
`specs/006-web-research/spike-findings.md` §4, §5, and §6 and the harness README.

After the run, fill in the `TODO(device: ...)` placeholders in SC-001 and SC-002 in `spec.md`
with the measured values.

---

## Budget verification (SC-006)

For a manual check without the harness:

1. Enable verbose logging in `NetworkResearchService` (or add a temporary assertion).
2. Run several `web_search` calls and inspect the raw tool result string before it is passed to
   `resumeWithToolResult`.
3. Confirm: the combined tool result string (JSON envelope + titles + URLs + content snippets) is
   ≤ ~1,220 chars (≤ ~305 tokens) for `web_search` in 100% of calls.
4. Run several `fetch_page` calls and confirm the tool result returned to the model is ≤ 2,000
   chars (the `ToolSpec.resultCharBound` hard limit, FR-014). Confirm the `[truncated: N items
   remaining]` marker appears when the extraction exceeded the bound.

_Tied to_: FR-011, FR-014, SC-006.
