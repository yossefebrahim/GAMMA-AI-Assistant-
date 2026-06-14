# device walkthrough V1–V15 — 006 web research (T061 / T062)

human-run, on-device field checklist for the v1 release validation of feature 006-web-research.
this is the script for the operator; you (claude) do NOT run it.

**`flutter run` / `flutter drive` ONLY — NEVER `flutter test integration_test/...`** (it uninstalls the
app and wipes the 2.4 GB model + DB).

source of truth: `../quickstart.md`, `../spec.md` (SC-001..SC-015), `../tasks.md` (T060/T061/T062).
this file maps quickstart's numbering (V1–V3, settings how-to, Steps 1–7, V8–V12, reliability gate) onto
a clean V1–V15 sequence. merges/notes are called out per item.

- **T061 covers V1–V9** (enable + key entry, web_search chip, source URL chips, per-conversation toggle,
  fetch_page chip + domain label, offline red chip, key-invalid chip, zero-results, history persistence).
- **T062 covers V10–V15** (reliability harness, airplane-mode offline degradation, zero spurious calls on
  junk, startSession toggle-change hitch timing, accessibility scanner, INTERNET permission + seam audit).

reference device: A34 (SM-A346E, `192.168.9.2:45295`). the A34 can appear twice in `adb devices` — pass
`-d` explicitly. prereqs: model installed; tool-capable model active (default catalog model declares
function calling); a valid Tavily key (free at tavily.com, 1,000 credits/month, no card).

---

## before you start — raise the screen timeout (restore at the end)

```
adb shell settings put system screen_off_timeout 1800000
adb shell svc power stayon true
# restore after the whole run:
adb shell settings put system screen_off_timeout 60000
adb shell svc power stayon false
```

(V10's `flutter drive` block raises the timeout to 600000 itself — both are fine; just remember to restore
at the very end.)

---

## V1 — enable web research + BYOK key entry  ·  US2 / FR-002 / FR-003 / FR-004 / FR-005 / SC-013, SC-015
> merges quickstart "how to add the Tavily key" + V3 (settings add/mask/edit/delete/clear).

**action**
1. fresh install. open settings → web research.
2. read the microcopy: it must name Tavily as the search recipient, state that `fetch_page` makes a
   DIRECT request from your device to the target website (not via Tavily), and confirm the key never
   leaves the device.
3. try to enable the master toggle with no key stored.
4. paste a valid Tavily key. save.
5. navigate away and return.
6. tap "clear key".

**expected**
- (1) master toggle is OFF, key field shows no stored key (fresh default, FR-001).
- (2) all three FR-002 disclosures present, lowercase, design-system voice.
- (3) a clear prompt to enter a key appears; the toggle stays OFF (FR-005).
- (4) after save the key is MASKED ("saved — tap to replace"), not plain text (FR-003); the master toggle
  can now be turned on.
- (5) the key is still masked on return — persisted, never re-shown in plain text.
- (6) key removed from encrypted storage, master toggle turns OFF, web tools become absent (FR-004).

`[ ] pass / [ ] fail`

---

## V2 — happy path web_search: chip + grounded answer  ·  US1 / FR-010 / FR-012 / FR-022 / FR-023 / SC-001
**setup**: valid key stored, global web toggle ON (or per-conversation explicitly on).

**action**
1. send 8–10 research-worthy prompts, e.g. "what's the latest Flutter stable release?", "summarize the
   Dart 3 migration guide", "what changed in the Android 15 developer preview?".
2. send "what is 17×23?".

**expected**
- (1) for each: a `WEB_SEARCH · Tavily` RUNNING chip appears before the request completes (optimistic
  render, FR-023), then transitions to SUCCESS; the model's answer is grounded in the returned search
  content (not fabricated from training only); chip names "Tavily", never a silent egress (FR-012/FR-022).
- (2) NO web_search chip — the model answers from its own knowledge (US1 AS-2). this is the no-spurious
  signal for the manual path (formal count is V12 / V10 harness).

`[ ] pass / [ ] fail`

---

## V3 — source URL chips are tappable  ·  US1 AS-1 / FR-013 / FR-025 / SC-007
**action**
1. with web on, ask a question that returns results (e.g. "what is Flutter?").
2. tap each source URL chip beneath the model's answer.

**expected**
- (1) ≥ 1 tappable source URL chip appears beneath the final text answer, one per result URL (FR-013).
- (2) tapping opens the URL in the device's default browser (android_intent_plus); destination matches
  the source page; opens the browser rather than crashing or navigating in-app (SC-007).

`[ ] pass / [ ] fail`

---

## V4 — per-conversation three-state toggle + precedence  ·  US3 / FR-007 / FR-008 / FR-009 / SC-010
> the three-state override (`inherit-global` / `explicitly-on` / `explicitly-off`); precedence is
> bidirectional over the global flag. covers quickstart Step 4 cases 4a/4b/4d here; 4c (mid-conversation
> session recreation) is split out to **V13** because it is a timing gate.

**4a — global OFF, per-conversation explicitly ON** (US3 AS-1)
- action: global toggle OFF in settings; new conversation; flip the composer quick toggle from
  `inherit-global` to `explicitly-on`; ask a research-worthy prompt; then open a DIFFERENT new
  conversation (no override) and ask one.
- expected: composer shows a visual indicator web is on for this chat; `WEB_SEARCH · Tavily` chip +
  grounded answer in the override chat; NO web chip in the other chat (global default still off).
- `[ ] pass / [ ] fail`

**4b — global ON, per-conversation explicitly OFF** (US3 AS-2)
- action: global toggle ON; new conversation; set the quick toggle to `explicitly-off`; ask a
  research-worthy prompt; then open another new conversation (no override) and ask one.
- expected: NO web chip in the explicitly-off chat (per-conversation OFF overrides global ON, FR-007);
  web search DOES fire in the no-override chat (inherits global ON).
- `[ ] pass / [ ] fail`

**4c — inherit-global is the default for a new conversation** (FR-008)
- action: with global ON, open a brand-new conversation and inspect the quick toggle WITHOUT touching it;
  ask a research-worthy prompt.
- expected: the quick toggle starts in `inherit-global` and resolves to the global default (ON here);
  web search fires without any manual flip.
- `[ ] pass / [ ] fail`

**4d — per-conversation override persists across restart** (US3 AS-4 / FR-008)
- action: set a conversation to `explicitly-on` (global OFF); kill and relaunch the app; reopen that
  conversation.
- expected: the quick toggle still shows ON and web search still works — override persisted in the
  conversation row (FR-008).
- `[ ] pass / [ ] fail`

---

## V5 — fetch_page: chip + domain label + truncation  ·  US4 / FR-014 / FR-016 / FR-017 / SC-006, SC-007
**setup**: after a `web_search` response that returned source URLs.

**action**
1. ask the model to read one, e.g. "read the first result" or "fetch https://flutter.dev/docs/get-started/install".

**expected**
- a `FETCH_PAGE · [domain]` RUNNING chip appears (e.g. `FETCH_PAGE · flutter.dev`). the domain is the
  hostname of the TARGET WEBSITE, NOT "Tavily" (FR-016) — fetch_page is a direct GET to the site.
- chip transitions to SUCCESS; the model's answer references specific content from that page.
- a tappable source URL chip for the fetched page appears beneath the answer (FR-017, SC-007).
- if the extracted text exceeded 2,000 chars, the answer is based on the truncated excerpt and the
  truncation is noted (`[truncated: N items remaining]` marker, FR-014 / SC-006).

`[ ] pass / [ ] fail`

---

## V6 — offline red chip (airplane mode)  ·  US5 AS-1 / FR-019 / FR-020 / SC-004
> full procedure lives in `./offline-airplane-mode-procedure.md` (and quickstart Step 2) — do not
> duplicate it here. this item is the pass/fail gate.

**action**: run the airplane-mode procedure with global web ON + valid key stored.

**expected (gate)**
- a `WEB_SEARCH · Tavily` chip appears and transitions to a RED error state with a plain-language offline
  reason, e.g. "offline — no connection" (FR-020).
- the app does NOT crash, hang, or fire a retry storm; no automatic retry (FR-020).
- the model is invited to answer from its own knowledge and produces a text reply.
- repeated research prompts each fail cleanly with a red offline chip; disabling airplane mode resumes
  web search on the next prompt (SC-004).

`[ ] pass / [ ] fail`

---

## V7 — key-invalid red chip  ·  US5 AS-2 / FR-019 / SC-005
**setup**: deliberately enter an invalid Tavily key in settings (e.g. `sk-invalid-test-key-12345`),
global web toggle ON.

**action**
1. new conversation; ask "what's the latest Flutter release?".
2. (optional) to exercise HTTP 429: exhaust free credits or use a seam injection — expect a rate-limit red chip.
3. restore a valid key in settings.

**expected**
- (1) a `WEB_SEARCH · Tavily` chip transitions to a RED error state naming the reason, e.g. "tavily key
  invalid — check Settings" / "provider error: unauthorized" (KeyInvalidError path, FR-019); no partial
  result is used; the model answers from its own knowledge (SC-005).
- (3) the feature resumes after a valid key is restored.

`[ ] pass / [ ] fail`

---

## V8 — web_search zero-results SUCCESS chip  ·  FR-033 / edge case
**setup**: global web toggle ON, valid key, live connectivity.

**action**
1. ask a nonsense/niche query designed to return no Tavily results, e.g.
   "asdfqwerty zxcvmnop current events 2026".

**expected**
- the app does NOT crash (FR-033).
- a SUCCESS chip (NOT an error chip) appears with a "0 results" indication, e.g.
  `WEB_SEARCH · Tavily — 0 results`.
- the model is informed there were no results and responds from its own knowledge or suggests rephrasing.
- NO source URL chips appear (no results = no URLs).

`[ ] pass / [ ] fail`

---

## V9 — history persistence across restart (metadata + URLs, NO snippet body in DB)  ·  US6 / FR-024 / FR-025 / SC-008
> merges quickstart Step 6 (tappable on reload) + Step 7 (persistence + adb sqlite spot-check).

**action**
1. with web on, run a `web_search` prompt ("latest Flutter release") and a `fetch_page` prompt
   ("fetch flutter.dev/docs"). confirm both chips + source URLs appear.
2. kill the app completely and relaunch; reopen the conversation.
3. tap a source URL chip.
4. if you have adb access, run the DB spot-check below.

**expected**
- `WEB_SEARCH · Tavily` chip re-renders with the original query text + success status (FR-024).
- `FETCH_PAGE · [domain]` chip re-renders with the original URL + success status (FR-024).
- tappable source URL chips are present and still open the browser (FR-025, SC-008).
- the model's synthesized text answer is present.
- **no full Tavily `content` body / no fetch_page extracted text** is stored or displayed — only the
  query/url, status, and source URLs (Decision 4, FR-024, SC-008).

**adb sqlite spot-check** (package id `com.example.ai_assistant`; DB name `gemma_assistant`):
```
adb shell "run-as com.example.ai_assistant sqlite3 /data/data/com.example.ai_assistant/databases/gemma_assistant \
  \"SELECT tool_result FROM messages WHERE tool_name='web_search' LIMIT 5;\""
```
the returned rows must contain only metadata (title, url, status) — NOT full snippet bodies. (if `run-as`
is blocked on a release build, use the same `SELECT` via the quickstart Step 7 path against the app DB.)

`[ ] pass / [ ] fail`

---

## V10 — reliability harness (A34 20-prompt, `flutter drive`)  ·  GATE B / SC-001 / SC-002 / SC-003 / SC-012
> unblocks the `TODO(device)` thresholds in SC-001 and SC-002. this is the **shipped** T060 harness at
> `integration_test/web_research_harness_test.dart` — it STAYS in the tree (exactly like the 005
> `integration_test/memory_reliability_test.dart`); do **not** copy it from anywhere and do **not** remove
> it before merge. it is only ever run via `flutter drive`, NEVER `flutter test integration_test/...` (that
> wipes the model + DB). (the old Phase-0 throwaway probe in `../spike-harness/` is a spec artifact only and
> is not used here.)

**action**
```
adb shell settings put system screen_off_timeout 600000
adb shell svc power stayon true
flutter drive \
  --driver=test_driver/integration_test.dart \
  --target=integration_test/web_research_harness_test.dart \
  -d 192.168.9.2:45295 \
  2>&1 | tee web_research_run.log
grep '@@WEB@@' web_research_run.log
adb shell settings put system screen_off_timeout 60000
adb shell svc power stayon false
```
the harness emits `@@WEB@@`-prefixed JSON lines (one per trial + a final `summary` line); see the file
header in `integration_test/web_research_harness_test.dart` and `../spike-findings.md` §4/§5/§6 for the
protocol. the harness declares all eight tools and scores 21 structural trials across five buckets
(8 websearch + 2 fetch + 4 device + 2 memory + 5 junk); image grounding is a skipped expected-failure
(excluded from the tally — see the vision decision memo).

**expected — record each, gate on the threshold** (fields are from the `@@WEB@@ ... "stage":"summary"` line)

| measurement (`summary` field) | gate threshold | recorded |
|---|---|---|
| `captureRate` — web_search correct selection (8 `websearch` prompts) | ≥ 0.75 (≥ 6/8) — **ASSERTED** | `TODO(device)` — SC-001 |
| `spuriousWebCalls` — web call on a `junk` prompt (5 junk prompts) | 0 — **ASSERTED** | SC-003 |
| `secondCallFiredCount` — 2nd tool call after a seeded web_search result (chain signal) | ≤ 1/8 | SC-003 / §4 GATE B |
| `fetchCorrect` / `deviceCorrect` / `memoryCorrect` — cross-surface selection | record (expect full) | surface coverage |
| `wrongToolCalls` + `hallucinatedTools` | record (expect 0) | — |
| `firstTokenMs` / `turnMs` per trial (latency) | `TODO(device)` — no invented number | SC-002 |
| `rawTextLeakCount` | 0 / 21 trials | SC-012 |
| `crashCount` | 0 | SC-001 |
| image bucket | expected-failure, excluded from tally | 002 vision gap |

the two **ASSERTED** rows fail the `flutter drive` run if missed; the rest are recorded for the gate sheet.
after the run, fill the `TODO(device: ...)` placeholders in SC-001 and SC-002 in `../spec.md` with the
measured values.

`[ ] pass / [ ] fail`

---

## V11 — airplane-mode offline degradation (full procedure)  ·  US5 / FR-020 / FR-021 / SC-004
> the full step-by-step is in `./offline-airplane-mode-procedure.md` (and quickstart Step 2) — run it in
> full here. V6 is the quick functional gate; V11 is the complete cross-cutting degradation pass
> including the web-OFF byte-identical case.

**action**: follow the airplane-mode procedure end to end, covering both web-ON and web-OFF.

**expected (gate)**
- web ON: 100% of attempts produce a red offline chip; zero network calls; no crash; no retry loop;
  model falls back to its own knowledge (SC-004).
- web OFF (global + per-conversation off): going offline behaves EXACTLY as pre-006 — no degradation,
  no new UI, zero network (FR-021, US5 AS-5).
- disabling airplane mode resumes normal web search on the next prompt.

`[ ] pass / [ ] fail`

---

## V12 — zero spurious calls on junk prompts  ·  US1 AS-2 / FR-006 / SC-003 / SC-010
> the manual counterpart to V10's harness junk-prompt count. also covers the toggle-OFF structural
> absence case (quickstart Step 1).

**action**
1. with web ON, send ≥ 5 junk / no-research prompts: arithmetic ("what is 17×23?"), chitchat
   ("how are you?"), in-context follow-ups that need no web ("rephrase that shorter").
2. set global toggle OFF (no per-conversation override) and ask research-worthy prompts.

**expected**
- (1) ZERO `web_search` / `fetch_page` chips on the junk prompts — the model answers from its own
  knowledge (SC-003).
- (2) with web off: the model answers from training knowledge; no web chip; zero network calls; tools
  structurally absent (FR-006, SC-010).

`[ ] pass / [ ] fail`

---

## V13 — startSession toggle-change hitch timing  ·  US3 / FR-032
> split out from quickstart Step 4 case 4c — this is the session-recreation timing gate (recreate the
> chat session BEFORE the next turn, per the 005 "close session first" pattern).

**action**
1. with a LIVE conversation and web access ON, flip the per-conversation quick toggle OFF.
2. send the next prompt.

**expected**
- before the model call, the app recreates the chat session (close current session first, then recreate
  with the updated tool declarations — FR-032). web tools are ABSENT from the registry for this and all
  subsequent turns in the conversation.
- a brief, bounded hitch at the toggle boundary is acceptable (session recreate); it must NOT hang, drop
  history, or produce a stale tool set. no user data is lost; conversation history replays into the new
  session normally.
- reverse direction (OFF → ON mid-conversation) likewise recreates and web tools become present.

`[ ] pass / [ ] fail`

---

## V14 — Accessibility Scanner pass on the new surfaces  ·  FR-029 / SC-013
> the code-enforceable 48dp slice is already covered in `test/widget/accessibility_test.dart`; this V item
> is the on-device Android Accessibility Scanner pass + the human contrast/voice review the test cannot do.

**action**: run Accessibility Scanner over:
- the settings → web research screen (master toggle, key field, microcopy, clear-key button).
- the composer web quick toggle.
- a completed conversation containing `web_search` chips + source URL chips (and a `fetch_page` chip).

**expected**
- 48dp touch targets on all interactive elements (matches the code floor in `accessibility_test.dart`).
- WCAG AA contrast throughout.
- error/destructive states use the sanctioned red `#D71921` only (never body text or primary buttons).
- all microcopy is lowercase per design-system voice.
- no Accessibility Scanner blocking findings on any of the three surfaces.

`[ ] pass / [ ] fail`

---

## V15 — INTERNET permission confirmed + network-seam audit (key never in DB/logs)  ·  FR-003 / FR-018 / SC-014 / SC-015
> T059 (INTERNET permission audit) + quickstart V12 (network seam + key-leak audit).

**action**
1. confirm `<uses-permission android:name="android.permission.INTERNET"/>` is present in
   `android/app/src/main/AndroidManifest.xml` (already declared for the model download — no new runtime
   prompt needed).
2. confirm ALL web-search / fetch_page network calls route through `NetworkResearchService` in
   `lib/infrastructure/network/`; no widget / provider / domain class makes HTTP calls directly
   (`bash tool/check_network_seam.sh` + `bash tool/check_plugin_seam.sh` stay green — FR-018, SC-014).
3. search the DB and logs for the Tavily key string — it must never appear in the SQLite conversation DB,
   any log file, or any crash-report payload (FR-003, SC-015). e.g.:
   ```
   adb logcat -d | grep -i "<your-tavily-key-prefix>"   # expect: no matches
   ```
   and re-use the V9 sqlite spot-check to confirm no key in `tool_args` / `tool_result`.

**expected**
- (1) INTERNET permission present; no new runtime permission prompt.
- (2) both seam guard scripts green; zero out-of-seam HTTP paths (SC-014).
- (3) the Tavily key appears in NONE of: the SQLite DB, logs, crash reports (SC-015).

`[ ] pass / [ ] fail`

---

## after the run

- restore the screen timeout (see top).
- fill the `TODO(device)` placeholders in SC-001 and SC-002 in `../spec.md` from the V10 harness table.
- mark T061 (V1–V9) and T062 (V10–V15) done in `../tasks.md` once all boxes are checked pass.
- the shipped harness `integration_test/web_research_harness_test.dart` STAYS in the tree (the T060
  deliverable, like the 005 `memory_reliability_test.dart`) — do NOT remove it before merge.
