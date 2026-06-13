# Phase 0 Spike Findings — Web Research (provider selection + content extraction + chain feasibility)

**Feature**: 006-web-research | **Date**: 2026-06-12 | **Device**: Samsung A34 (SM-A346E,
Dimensity 1080, 7.3 GiB usable RAM) | **Stack under test**: flutter_gemma 0.15.3 (pinned
`^0.15.0`) + `gemma-4-e2b.litertlm` | **Backend**: GPU (LiteRT OpenCL delegate)

**What this spike covers**: Four investigation streams — (1) search provider evaluation (live API
probes + ToS audit), (2) content extraction across 10 diverse page categories (actual curl fetches,
measured HTML sizes, estimated token counts), (3) multi-step tool-chain feasibility via plugin source
inspection (the 004/005 async-path history-omission hazard), and (4) context budget arithmetic.
Streams 1–3 are fully settled here from source inspection and live probes. End-to-end latency (§5)
and multi-step chain reliability % (§4 device TODO) require the A34; those are the two open device
measurements that gate the next phase.

**DECISION GATE STATUS**: Two gates require human decision. **GATE A (product)**: provider choice
— Tavily (free, AI-optimized, no attribution required) vs Brave (independent index, privacy brand
alignment, `POWERED BY BRAVE` UI obligation, no genuine free tier). **GATE B (architecture)**: chain
feasibility — source inspection strongly favours snippets-only single-call design; final numeric
confirmation is a `TODO (device)` 20-prompt run. The full device validation protocol is in §6 and
the harness at `specs/006-web-research/spike-harness/`.

---

## §1  Search provider

### 1.1 Provider landscape (as of June 2026)

Two providers are **dead** and must not be used:

| Provider | Status |
|---|---|
| Bing Search API / Azure | **RETIRED Aug 11 2025** — HTTP 410 Gone. Replacement (Azure AI Agents Grounding) requires Azure infra + $35/1,000 transactions. Do not use. |
| Google Programmable Search Engine (CSE) | **DEPRECATED for new users Jan 2026** — full-web JSON API unavailable to new signups; new engines are domain-restricted (≤50 domains). Sunset Jan 1, 2027. Do not build on this. |

Two keyless options were **live-probed**:

| Provider | Result |
|---|---|
| DuckDuckGo Instant Answer API (`api.duckduckgo.com/?format=json`) | **Probed live**. `AbstractText`, `AbstractURL`, `Answer`, `RelatedTopics` ALL EMPTY for a general informational query (`flutter+android+development`). Returns data only for unambiguous named-entity lookups. Production state metadata showed `"offline"` on one probe. This is not a web search API — it is a knowledge-graph lookup. Useless for AI assistant augmentation. |
| DuckDuckGo HTML/Lite scraping (`lite.duckduckgo.com/lite/`) | **Probed live**. Returned 10 real results with titles, URLs, and snippets. No CAPTCHA in this environment. BUT: DDG `robots.txt` **explicitly disallows `/lite` and `/html`** (confirmed live). Against ToS, fragile HTML structure (no stable CSS class names), real IP-ban risk in production. **Do not ship.** |

Wikipedia MediaWiki Search API was live-probed as a **zero-friction factual fallback** (not a full
web search provider):

- Probed: `en.wikipedia.org/w/api.php?action=query&list=search&srsearch=flutter+android+development&srlimit=5&format=json`
- Returns valid JSON: `title`, `pageid`, `snippet` (HTML-tagged), `size`, `wordcount`, `timestamp`; 609 total hits for that query.
- No URLs in results; must construct as `https://en.wikipedia.org/wiki/{title}`.
- ToS risk: **NONE** — Wikimedia explicitly encourages API use. No key. No rate-limit concern at conversational volume.
- **Role**: encyclopedic/factual complement only. Cannot search the general web, current events, or product/store queries. Useful as a no-onboarding fallback for the user who will not paste a key.

### 1.2 BYOK provider tradeoffs

All viable full-web search options require a user-supplied BYOK key stored in Android
`EncryptedSharedPreferences` (AES-256, Android Keystore). Key is never committed to the repo;
revocable from the provider dashboard.

| Provider | Free tier | Cost after free | Attribution required | ToS risk | AI-optimized output |
|---|---|---|---|---|---|
| **Tavily** | **1,000 credits/month, no credit card, no time limit** (verified May 2026) | $0.008/credit (pay-as-you-go); $30/month for 4k credits | None found in documentation | **VERY LOW** — explicitly designed for AI agent/RAG embedding | **Yes** — `content` field returns pre-extracted clean page text; designed for LLM consumption |
| **Brave Search** | No genuine free tier as of Feb 2026. $5/month plan includes ~1,000 queries/month via credits; credit card required from day 1 | $5/1,000 queries (Search), $4/1,000 (Answers) | **YES** — `POWERED BY BRAVE` + logo must appear in app or project about page; confirmed from ToS | LOW (BYOK, independent index, no Google downstream exposure) | No — returns structured SERP JSON (title, url, description, age); no pre-extracted content |
| SerpAPI | ~100 searches/month (confirmed on official page) | $25/month for 1,000; no pay-as-you-go | No attribution requirement | MEDIUM — scrapes Google server-side; Google has litigated scraping; downstream ToS exposure | No — rich SERP JSON but no pre-extracted content |

### 1.3 DECISION GATE A (product): provider choice

**Recommendation: Tavily Search API (BYOK).**

Tavily is the only option that satisfies all hard constraints simultaneously:
- No backend, no embedded paid key in the binary (BYOK — user is the API contract party).
- Genuinely free 1,000 credits/month with no credit card.
- `content` field returns pre-extracted clean page text optimized for LLM consumption — reduces the need for a separate URL-fetch step and compresses the tool-result size naturally.
- Explicitly designed for AI agent embedding; no attribution requirement found.
- BYOK key lives in Android EncryptedSharedPreferences/Keystore; never in the repo.

**Brave is a reasonable alternative** if the product owner values the independent index and
privacy-brand alignment. The cost: (a) no genuine free tier (credit card day 1, ~1,000 queries/month
soft limit), and (b) a required `POWERED BY BRAVE` UI label in the app — a real UI obligation that
must be designed in.

**Third path worth considering**: ship Wikipedia MediaWiki API as a zero-friction free fallback for
factual/encyclopedic queries (no onboarding, no key, ToS-clean), plus optional BYOK Tavily for full
web search. Users who will not paste a key still get something useful for factual lookups without any
ToS violation.

**Decision needed from product owner**: Tavily vs Brave vs Tavily + Wikipedia fallback. The
architecture is the same for all three; only the provider implementation changes.

---

## §2  Content extraction

### 2.1 Live extraction results (10 pages, actual curl fetches)

Token counts are **estimated (chars ÷ 4)** — `tiktoken` was not available in the Python probe
environment. Char÷4 is accurate to ±20% for clean prose; it overestimates raw HTML (tag syntax
tokenizes more compactly than raw chars suggest — a 72 KB BBC file would be ~40K tiktoken tokens,
not 72K). Extraction quality (which DOM region matched, paragraph counts) is **measured exactly**.

| URL | Category | Raw HTML (est. tokens) | Extracted (est. tokens) | Compression | Quality |
|---|---|---|---|---|---|
| bbc.com/news (article 1) | news | ~72,600 | **1,006** | 72× | Good — `<article>` boundary captured all 25 paragraphs; nav/footer/JS React bundles fully excluded |
| bbc.com/news (article 2) | news | ~71,300 | **853** | 84× | Good — same BBC structure; 20 body paragraphs; related-story cards stripped |
| developer.mozilla.org/en-US/docs/… | docs | ~46,500 | **676** | 69× | Fair — `<main>` captured 12 content items; browser-compat tables dropped (good); code-example CSS leaks as text (minor) |
| dart.dev/language/concurrency | docs | ~40,000 | **3,719** | 11× | Good — `<main>` captured full Dart concurrency doc (59 items); one promo banner leaked (minor) |
| en.wikipedia.org/wiki/Dart_(programming_language) | wikipedia | ~95,300 | **3,373** | 28× | Good — p-only strategy from `<main>` extracts 47 body paragraphs; avoids ~9K spurious tokens from 200+ sidebar/TOC `<li>` items |
| en.wikipedia.org/wiki/Large_language_model | wikipedia | ~172,100 | **12,615** | 14× | Good — p-only yields 112 paragraphs; discards 910 sidebar/category `<li>` items (~24K tokens avoided); inline `[1]` citation brackets pass through (minor noise) |
| overreacted.io/a-complete-guide-to-useeffect/ | blog (long) | ~188,200 | **15,233** | 12× | Good — `<article>` precisely wraps all 257 paragraph+list items; Gatsby static site with clean semantic HTML; essentially lossless |
| jvns.ca/blog/2022/04/12/… | blog (short) | ~4,360 | **559** | 8× | Good — `<article>` captured all 38 content items; blog uses minimal HTML; extraction essentially complete |
| data.gov/climate/1/ | gov (hub) | ~31,300 | **641** | 49× | Fair — hub/index with sparse body text; `<main>` yielded 10 items describing climate categories; low count reflects true page sparsity |
| nist.gov/artificial-intelligence | gov (no landmark) | ~24,700 | **901** | 27× | Fair — Drupal CMS, no `<main>`/`<article>`; fallback extracted p+li from stripped body; 3-4 `.gov` trust-banner items included at top; core NIST AI description captured |

**No complete extraction failure** across 10 pages. Worst case (NIST) still recovered the core
content via fallback. Three originally targeted URLs were 404s or JS-only (Guardian, AP News, The
Register) and were substituted with live curl-accessible pages.

**Planning number: median ~954 tokens/page** (estimated). Category breakdowns:
- News articles: 853–1,006 tokens — naturally compact; fit easily in a 4K budget.
- Short reference docs / gov hub pages: 559–901 tokens.
- Long-form blog posts: 559–15,233 tokens — high variance; long-form hits 12K–15K and requires hard truncation.
- Wikipedia articles: 3,373–12,615 tokens — the p-only strategy is mandatory (p+li inflates 2× on the LLM article: 24,864 p+li vs 12,615 p-only).

### 2.2 Dart extraction pipeline design

Using the `html` package (`html: ^0.15.4`). Key decisions from the spike:

**Priority-order DOM selection** (pick first match):
1. `article` — strongest signal; used by BBC, blogs.
2. `main` — second signal; used by Wikipedia, MDN, Dart docs, data.gov.
3. `[role="main"]` — legacy fallback.
4. Class/id heuristics: `#content`, `#main-content`, `.article-body`, `.entry-content`, `.post-body`, `.story-body`.
5. Whole `document.body` as last resort.

**Wikipedia p-only detection**: detect via `rawHtml.contains('wikipedia.org')` → extract `<p>` only, skip `<li>`. Measured impact: 12,615 tokens p-only vs ~24,864 tokens p+li on the LLM article — the `<li>` items are sidebar/TOC noise, not body content.

**Link-density guard**: if a candidate item has >50% of its character length in `<a>` text, discard it — eliminates nav-list items that slip past the tag filter.

**Hard token-budget truncation**: budget constant `kMaxExtractedTokens = 4000` covers 8/10 pages fully; 2 (long blog + long Wikipedia) get truncated. Use `item.length ~/ 4` for budget accumulation. Truncate by stopping at item boundaries (not mid-word); preserve the first item always (contains the lede); append `[truncated: N items remaining]` for transparency.

**Boilerplate removal** (mutate DOM before traversal): remove by tag — `script`, `style`, `noscript`, `iframe`, `svg`, `form`, `nav`, `footer`, `header`, `aside`. Remove elements whose class/id matches noise patterns: `advertisement`, `ad-`, `cookie`, `share-`, `related-`, `sidebar`, `breadcrumb`.

### 2.3 Measured vs estimated

| Fact | Status |
|---|---|
| Raw HTML byte sizes | **MEASURED** exactly (via `wc -c`) |
| Paragraph counts per page | **MEASURED** exactly (regex on the fetched HTML) |
| Which DOM region matched (article/main/fallback) | **MEASURED** exactly (confirmed per page) |
| All token counts | **ESTIMATED** (chars ÷ 4); accurate to ±20% for clean prose; overestimates raw HTML |
| Quality labels (good/fair) | **MEASURED** (manual inspection of 200-char samples per page) |
| Compression ratios | **DERIVED** from estimated token counts — same ±20% caveat |

---

## §3  Context budget strategy

### 3.1 The budget

Gemma 4 E2B on our stack uses `maxTokens: 2048` with `ContextAssembler` reserving **1536 tokens**
for conversation (512 held for the model's own output). The 005 memory block consumes an additional
fixed slice at chat creation:

| Slot | Tokens (measured unless noted) |
|---|---|
| E2B full context | 2048 |
| Output reserve | 512 |
| **Available for input** | **1536** |
| Memory facts block (20 facts, measured on device) | 174 |
| Memory capture system instruction (measured) | 86 |
| Tool declarations (2 new tools: `web_search` + `fetch_url`, estimated) | ~80 |
| Existing 004 tool system instruction (measured, 004 spike) | ~40 |
| **Remaining for chat history + current turn** | **~1156** |

Practical working budget for a web-research tool result + chat history: **~1,000–1,100 tokens**.

### 3.2 Approach A: snippets-only single call

The Tavily `content` field already returns pre-extracted clean page text. A single `web_search(query)
→ {results: [{title, url, content, score}]}` tool call with the top 3 results at ~300 chars of
content each costs approximately:

| Item | Est. tokens |
|---|---|
| Tool result JSON envelope | ~20 |
| 3 result titles + URLs | ~60 |
| 3 × ~300-char content snippets | ~225 |
| **Total tool result** | **~305 tokens** |

This fits comfortably in the ~1,000-token budget alongside a multi-turn chat history (2–3 prior
turns ≈ 200–400 tokens) and leaves ~300–500 tokens for the model's reasoning.

This approach requires **zero changes to the existing 004/005 seam** — one tool call, one round-trip,
one `resumeWithToolResult`. The model receives a complete grounded result and generates the final
answer in one pass.

### 3.3 Approach B: fetch + on-device summarization of one page

After a `web_search` call, the model would call `fetch_url(url)` to retrieve the full extracted text
of one page. From §2, the median extracted page is ~954 tokens; a hard truncation at 4,000 tokens is
applied.

| Item | Est. tokens |
|---|---|
| Search tool result (step 1) | ~305 |
| Fetch tool result at 4K truncation (step 2) | up to 4,000 |
| **Total tool results** | **~4,305** |

This **exceeds the full 1536-token available budget** by 3×. It would also require a second tool
round-trip within one user turn — see §4 for why this is architecturally unsupported.

**Even with aggressive truncation** (fetch result capped at 800 tokens), approach B costs ~1,100
tokens in tool results alone, leaving ~0–55 tokens for chat history. Infeasible at E2B scale.

### 3.4 Recommendation

**Default: Approach A (snippets-only single call)**. The Tavily `content` field is already
LLM-optimized and typically provides 200–500 tokens of pre-extracted context per result. Returning
3 top results fits the budget. Approach B (fetch a full page) is arithmetically ruled out at 2048
tokens — it would crowd out both the memory block and all chat history.

**`TODO (device)`** — [ ] Measure summarization latency on A34: feed a ~500-token canned page
excerpt into the model (text-only, no tools) and time first-token latency + total time to summary.
This is the latency floor for approach B even if the budget were sufficient. See harness block B in
`specs/006-web-research/spike-harness/spike_web_research_test.dart`.

---

## §4  Multi-step tool chains

### 4.1 What the plugin API supports (source inspection)

On the flutter_gemma 0.15.3 / Gemma 4 E2B / Android LiteRT-LM (FFI) path, tool-result feed-back
works as follows. After `generateChatResponseAsync()` streams to completion and yields the final
`FunctionCallResponse` event, the consumer calls `chat.addQuery(Message.toolResponse(toolName:,
response:))` to inject the result as a user-role plain-text `<tool_response>…</tool_response>` block,
then calls `chat.generateChatResponseAsync()` again on the same `InferenceChat` object. The plugin
does not loop automatically; the consumer drives the loop. This exactly matches
`GemmaService.resumeWithToolResult()` (`lib/infrastructure/gemma/flutter_gemma_service.dart` lines
407–461).

The feed-back medium at the native layer is a **plain-text user-role block**, not an OpenAI-style
`role:"tool"` turn. The LiteRT-LM SDK renders it into the Gemma 4 chat template on the next generate
call. The `SdkResponseParser.buildToolResponseJson` serialiser (`extensions.dart:61-72, 91-99`) is
dead code in 0.15.3 and is never called on the streaming path.

### 4.2 The decisive hazard: history omission on the async streaming path

Source inspection of `~/.pub-cache/hosted/pub.dev/flutter_gemma-0.15.3/lib/core/chat.dart` reveals
a **confirmed plugin bug on the async streaming path**:

- **Sync path** (`generateChatResponse()`, lines 163–170): when a tool call is detected, the
  assistant's tool-call turn is correctly written to both `_fullHistory` and `_modelHistory`:
  `_fullHistory.add(toolCallMessage); _modelHistory.add(toolCallMessage)`.
- **Async streaming path** (`generateChatResponseAsync()`, lines 395–414): when a `FunctionCallResponse`
  is detected from `lastRawResponse` at end-of-stream, `emittedFunctionCall` is set `true`, and the
  call is yielded — but the history-append block **for the gemma4 case is missing**. The assistant's
  tool-call turn is NOT written to `_fullHistory` or `_modelHistory`.

This was identified in the 004 spike (`specs/004-function-calling/spike-findings.md §1.3`) as the
single most important hazard: "the streaming gemma4 branch NEVER writes the assistant's tool-call
turn to the plugin-side chat history."

**Consequence for chaining**: if the consumer feeds back tool result 1 and re-generates, the model's
context is `[replayed history] + [tool_response_1]` — but the preceding `[assistant → tool_call_1]`
turn is absent. The model must re-derive with incomplete context. Even if the app's DB-replay
mechanism (`_replayMessages()`, lines 475–493) could compensate, it covers between-turn history
reconstruction only — intermediate calls that have not yet been committed to the DB are invisible to
it. At mid-turn, intermediate calls are not persisted yet (the controller finalizes the row only
after the full turn completes).

### 4.3 One-round-trip limit enforced at three independent layers

The current 004/005 seam enforces one tool round-trip per user turn by construction:

1. `_awaitingToolResult` in `FlutterGemmaService` is cleared and `resumeWithToolResult` throws
   `StateError` if called a second time in the same turn.
2. The controller chips-and-skips a second `ToolCallRequested` on the resumed stream (FR-006/FR-024
   — the second call is rendered as a chip but not executed).
3. `generate()` marks the session dirty (`_sessionTurns = null`) after any tool turn, forcing a full
   DB-replay on the NEXT user turn's `generate()` call — not mid-turn.

### 4.4 Context budget ceiling for chaining

The 005 memory block + tool overhead already consumes ~380 tokens of the 1,536-token input budget
(§3.1). A two-hop chain (search → fetch) would need to fit:
- Turn 1 tool call + result: ~305 tokens (search)
- Turn 2 tool call + result: ~950 tokens (fetch, median page)
- System instruction + memory block: ~380 tokens

Total: ~1,635 tokens — **exceeds the full input budget**. Even at aggressive truncation (fetch
result at 500 tokens), the working budget for chat history is ~0–250 tokens: marginal for reliable
multi-step reasoning at E2B scale.

### 4.5 Chain feasibility verdict and degrade design

**HIGH RISK — do not attempt multi-step intra-turn chaining with the current seam on
flutter_gemma 0.15.3.** Three independent blockers:

1. **Plugin bug** (confirmed source inspection): the async streaming path omits the assistant's
   tool-call turn from `_modelHistory`. Mid-turn chaining cannot use the DB-replay workaround.
2. **Seam contract** (enforced by design): one round-trip per user turn. A second `ToolCallRequested`
   on the resumed stream is chipped-and-skipped, not executed. Supporting chaining requires a
   while-loop around `resumeWithToolResult`, persistence of intermediate turns inside the loop, and
   a `clearHistory(replayHistory:)` replay between each hop — each replay costs ~2–8 s on A34 from
   the 004/003 prefill measurements, adding ~4–16 s overhead for a two-hop chain.
3. **Context budget** (arithmetic): a two-hop chain's combined tool results exceed the full available
   input budget at E2B's 2048-token context.

**Degrade design — snippets-only single call**: combine search + summarize into ONE tool call.
Declare a single `web_search_and_summarize(query: string) → {results: [{title, url, snippet, score}]}`
tool. The Dart handler does any multi-hop work (search API → optional content extraction from
Tavily's `content` field) and returns a pre-processed bounded text excerpt as the tool result. The
model makes exactly ONE call, receives the summary in one tool-response block, and generates the
final answer. Zero seam changes. Fits the existing one-round-trip-per-turn contract.

The `ToolSpec.resultCharBound` default (2,000 chars) enforced by `ToolDispatcher._applyBound` is
the natural ceiling; pre-truncate at the handler level to ~1,500 chars before returning, leaving
room for the JSON envelope.

**Constitution compliance (Principle I, v2.0.0)**: any web egress is an off-device user-content
flow. Requirements: opt-in, off-by-default, visibly indicated (network-activity indicator or badge
in the tool chip), offline-degrading (tool returns `{error: "offline"}` when connectivity is absent),
auditable (tool call + result persisted in conversation DB per the 004 tool-turn persistence),
named-recipient (the user sees which provider is called in the tool chip, e.g.
`WEB_SEARCH · Tavily`).

**`TODO (device)`** — [ ] Run the 20-prompt tool-chain reliability protocol on A34 via
`flutter drive`. Record: first-call rate (X/20), correct tool selection, arg quality, second-call
fired (yes/no, the key chaining signal), grounded follow-up (yes/no), raw text leak. Full protocol
in §6 and harness block A+C in `specs/006-web-research/spike-harness/spike_web_research_test.dart`.

### 4.6 DECISION GATE B (architecture): chains reliable? else degrade to snippets-only

| Gate | Threshold | Verdict |
|---|---|---|
| Chain-viable | T09–T16 ≥ 4/8 second-call-fired AND ≥ 4/8 grounded-on-second-result AND 0 chip-and-skip firings AND latency ≤ 30 s | Requires seam redesign and plugin-bug workaround |
| **Snippets-only confirmed** | T01–T08 ≥ 6/8 correct single-call rate AND T09–T16 ≤ 1/8 second-call-fired AND T17–T20 0 spurious calls | Validates degrade design; proceed with zero seam changes |

Source inspection already makes the architecture call strongly: three independent blockers (plugin
bug + seam contract + budget arithmetic) align on the snippets-only design. The device run provides
the numeric capture-rate and e2e-latency confirmation needed before spec-writing.

**`TODO (device)`** — [ ] Run 20-prompt harness on A34 and record gate numbers.

---

## §5  End-to-end latency

**`TODO (device)`** — All latency numbers require the physical A34.

Items to measure (harness block B for summarization, block A+C for e2e tool-chain):

| Measurement | Description |
|---|---|
| [ ] `firstTokenMs` (summarization) | Time from `addQueryChunk` to first `TextResponse` token, for 125 / 250 / 500-token text inputs |
| [ ] `totalMs` (summarization) | Time to last token for same three text lengths — this is the latency floor for any "fetch + summarize" approach |
| [ ] `latencyToFirstCallEvent_ms` | Per-trial time from send to first `FunctionCallResponse` event (search-worthy prompts) |
| [ ] `latencyToFinalAnswer_ms` | Per-trial time from send to last token of the model's answer (full e2e including one tool round-trip) |
| [ ] `rawTextLeak` | Whether raw tool-call JSON appeared in the text channel (the 004 100%-leak hazard must be confirmed re-absent or mitigated) |

Until these numbers are in, no latency claims appear in this document.

**Context**: the 004 spike showed main-thread prefill blocks the Android UI thread. Full-history
replay costs ~2–8 s on A34. A raised screen timeout (`adb shell settings put system
screen_off_timeout 600000 && adb shell svc power stayon true`) is required before long drive runs
and must be restored afterward.

---

## §6  Device harness

Harness location: `specs/006-web-research/spike-harness/`

| File | Description |
|---|---|
| `spike_web_research_test.dart` | Self-contained flutter_drive integration test. Block B: summarization latency (3 text lengths, timed). Block A+C: 25-trial tool-chain reliability (20 search-worthy + 5 junk prompts); records `emitted1stCall`, `chainedToFetch`, `stalled`, `looped`, `finalAnswerPresent`, `answerGrounded`, e2e latency breakdown; emits `@@WEB@@`-prefixed JSON lines for easy extraction. |
| `README.md` | Exact run instructions, including screen-timeout commands, copy-first workflow, `flutter drive` command with `tee` variant, `grep '@@WEB@@'` extraction commands, and blank result tables for gates A/B/C. |

**NEVER run `flutter test integration_test/...`** — it uninstalls the app and wipes the downloaded
model + DB. Use `flutter drive` only.

Run command:
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

Copy the harness into `integration_test/` before running (it is not wired in by default). Mark DO
NOT SHIP; remove before merge per the 004/005 precedent.

---

## GATE STATUS

| Gate | Type | Status | Unblocked by |
|---|---|---|---|
| §2 Extraction pipeline design | Technical | **PASSED** — Dart pipeline designed, signal priority confirmed, Wikipedia p-only mandatory | Live curl probes on 10 pages |
| §1 Provider landscape | Technical | **PASSED** — Bing and Google CSE dead; DDG keyless unusable or ToS-violating; Tavily recommended | Live probes + ToS audit |
| §3 Budget arithmetic (snippets-only) | Technical | **PASSED** — ~305-token tool result fits the ~1,000-token working budget with room for 2–3 turns of chat history | Arithmetic from measured memory tokens (005) + estimated tool-result sizes |
| §4 Chain feasibility (source inspection) | Technical | **PASSED** — three independent blockers confirmed; degrade to snippets-only single-call is the decision | Plugin source inspection + 004/005 spike findings |
| **GATE A** | **Product** | **PENDING — human decision** | Provider choice: Tavily vs Brave vs Tavily+Wikipedia fallback |
| **GATE B** | **Architecture** | **PENDING — device run** | 20-prompt harness on A34: single-call rate, second-call-fired rate, e2e latency |
| §5 Summarization latency | Device | **PENDING** | Harness block B on A34 (3 text lengths, first-token + total-time) |
| §5 E2E tool-chain latency | Device | **PENDING** | Harness block A+C on A34 (per-trial `latencyToFinalAnswer_ms`) |

**The two measurements that unblock spec-writing**: (1) the human provider decision (GATE A) and
(2) the A34 20-prompt reliability run (GATE B). Source inspection already makes the snippets-only
architecture call with high confidence; the device run confirms capture rate and latency numbers for
the spec's acceptance criteria.
