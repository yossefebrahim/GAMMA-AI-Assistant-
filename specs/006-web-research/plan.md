# Implementation Plan: Opt-In Web Research — Search & Fetch via Tavily BYOK

**Branch**: `006-web-research` | **Date**: 2026-06-12 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `/specs/006-web-research/spec.md` (clarified 2026-06-12;
two device-measurement success-criteria TODOs remain open — SC-001/SC-002 fill after A34 harness
run) and Phase 0 spike ([spike-findings.md](spike-findings.md)) — extraction pipeline and budget
arithmetic PASSED; GATE A (provider choice) and GATE B (20-prompt A34 harness run) both
product-resolved/pending.

## Summary

Add opt-in web research to the on-device assistant: two tools (`web_search` and `fetch_page`) let
the model ground its answers in live web results. The user brings their own Tavily API key (stored
AES-256/Keystore-backed, never in the DB or logs). Web access is off by default and controlled by
a global Settings toggle plus a three-state per-conversation override. Every outbound call renders a
visible chip naming the true external recipient before the request fires. History persists tool
metadata and source URL chips (never the body text). The app degrades cleanly to pre-006 behavior
offline, with a missing key, or with both toggles off.

Technical approach — extend 004/005 rather than reshape them. The tool registry, dispatcher,
LeakFilter, `GenerationEvent` seam, `resumeWithToolResult`, `role='tool'` chip, one-round-trip
contract, and `startSession` session-recreation pattern are all reused:

- **NetworkResearchService seam.** A new `NetworkResearchService` interface owns ALL HTTP,
  search, and extraction logic (Principle VII, FR-018). The concrete `TavilyNetworkResearchService`
  (in `lib/infrastructure/network/`) calls `POST https://api.tavily.com/search` (Bearer-header
  auth, `max_results:3`, `content` field — NOT `snippet`), handles the full typed-error taxonomy
  (`OfflineError`, `KeyInvalidError`, `RateLimitError`, `ProviderError`, `FetchDomainError`,
  `ParseError`, `TimeoutError`), and drives `HtmlExtractor` for `fetch_page`. All HTTP lives
  there; no other layer may import `package:http` or `flutter_secure_storage`. The
  `check_plugin_seam.sh` script gains corresponding import-guard rules.

- **SecureKeyStore seam.** A `SecureKeyStore` interface (`lib/domain/services/`) abstracts
  `flutter_secure_storage ^10.3.1`; the concrete `FlutterSecureKeyStore` lives in
  `lib/infrastructure/network/`. The Tavily key is read at call time inside the seam and attached
  as a `Bearer` header; it never enters the SQLite DB, any log, or the model context (FR-003,
  SC-015). After initial entry the key is masked in Settings UI.

- **Tools (web_search + fetch_page).** `ToolRegistry` gains a `webTools` list alongside
  `deviceTools` (004) and `memoryTools` (005): `web_search{query: string, maxLength 400}` and
  `fetch_page{url: string}`. `SchemaValidator` gains a URL-scheme allowlist check for `fetch_page`
  (http/https only). `ToolDispatcher` gains two handlers; both call `NetworkResearchService`
  (validate → call → typed `ToolOutcome`, never throws). Tool results are hard-bounded at the
  dispatcher via `ToolSpec.resultCharBound`: `web_search` ≤ ~1,220 chars (~305 tokens, top 3
  results); `fetch_page` ≤ 2,000 chars (~500 tokens) with a `[truncated: N items remaining]`
  marker (FR-014). The field name in the tool result is `content` throughout — no internal
  renaming to "snippet" permitted (FR-010).

- **Triple gate.** `webTools` are declared to the model ONLY when
  `functionCalling && effectiveWebEnabled && hasValidKey`. The session provider composes:
  `deviceTools` (if `functionCalling`) + `memoryTools` (if `functionCalling && memoryEnabled`) +
  `webTools` (if `functionCalling && effectiveWebEnabled && hasValidKey`). The `effectiveWebEnabled`
  resolver applies the FR-007 three-state precedence: `explicitly-on` or `explicitly-off` per
  conversation overrides the global; `inherit-global` (NULL) defers to `webAccessEnabled`.
  Toggling while a session is live triggers `startSession` (005 pattern — close session →
  recreate chat — FR-032). `NetworkResearchService.search()` is also guarded by a `StateError`
  if invoked without a valid key (structural seam guard, mirrors 004/005).

- **Persistence.** Drift v5 → v6 migration adds two columns via `m.addColumn` (additive, no data
  loss): `conversations.webAccessOverride` (nullable TEXT, default NULL = inherit-global) and
  `app_settings.webAccessEnabled` (BOOL, default false). No new tables. Source URLs are stored as
  a compact JSON array inside the existing `tool_result` column (the `role='tool'` message row);
  the full Tavily `content` body and extracted page text are NOT persisted (Decision 4, FR-024).
  Migration test-seed gotcha: any prior `migration_v*_test` seed touching `conversations` or
  `app_settings` must include the two new columns (with defaults) and have its `schemaVersion`
  asserts bumped to 6 (house rule, project memory `drift-migration-test-seed-gotcha`).

- **Chips.** `web_search` renders as `WEB_SEARCH · Tavily` (names the Tavily recipient) with
  running/success/error states. `fetch_page` renders as `FETCH_PAGE · [domain]` (names the target
  website hostname — this call goes directly to the site, not through Tavily; FR-016, FR-022).
  Both use the 004 design-system chip treatment; both reuse the existing 004 `ToolChip` verbatim
  except for the label. Source URL chips appear beneath the model's final answer, one per result
  URL; tapping opens the device's default browser (android_intent_plus). Zero-result
  `web_search` calls render a success chip labelled "0 results" and no source URL chips (FR-033).
  Red error chips with plain-language messages cover all error taxonomy cases (FR-027, FR-034).

- **UI.** A `WebResearchSettingsScreen` in Settings (global toggle off by default, BYOK key
  entry + mask-after-save + clear, FR-002 microcopy naming both recipients, toggle blocked until
  key present). A per-conversation web toggle in the composer area (three-state quick toggle,
  inherits global default on new conversation, persists in conversation row — FR-008). Both reuse
  the existing settings list/section + design-system §8 patterns.

- **Context budget.** The `ContextAssembler` reserves an additional `webToolsReserveTokens ≈ 80`
  when `webTools` are declared, added to the existing 004 (~40) and 005 (~260) reserves.
  Running total with all features active: ~1,156 tokens remaining for chat history + turn (R9).

Pinned deps in [research.md](research.md) (R1–R9); data-model entities, the v5→v6 migration, and
persistence decisions in [data-model.md](data-model.md); seam / registry / dispatcher / error
contracts in [contracts/](contracts/); device validation in [quickstart.md](quickstart.md).

## Technical Context

**Language/Version**: Dart 3.12.x on Flutter stable — unchanged from 001–005.

**Primary Dependencies**: Three new direct deps (all isolated behind seams per Principle VII):
- `http: ^1.6.0` (already transitive via `background_downloader`; zero binary-size cost; lean,
  official; per-request timeout via `Future.timeout` + `abortTrigger`; two constants
  `kTavilyTimeoutMs = 10000`, `kFetchTimeoutMs = 15000`).
- `html: ^0.15.6` (pure-Dart HTML5 parser; bespoke `HtmlExtractor` heuristics validated on 10
  pages in spike §2; no readability package — both candidates rejected in R2).
- `flutter_secure_storage: ^10.3.1` (Android Keystore-backed AES/GCM key storage; minSdk 23 <
  our minSdk 29; pure Java, no native collision with flutter_gemma or sqlite3; behind
  `SecureKeyStore` seam; `encryptedSharedPreferences` option must NOT be passed — deprecated
  in 10.x).
- `flutter_gemma: ^0.15.0` (0.15.3 installed) UNCHANGED — spike findings are 0.15.3-specific;
  0.16.x remains a model-load regression on the A34. `connectivity_plus` NOT added (R5).

**Storage**: drift over app-private SQLite. Schema bumps to **v6**: additive `m.addColumn` only —
`conversations.webAccessOverride` (nullable TEXT, default NULL) + `app_settings.webAccessEnabled`
(BOOL, default false). No new tables. Source URLs inside existing `tool_result` column as compact
JSON. Full snippet/extracted body text is NOT persisted (Decision 4).

**Testing**: `flutter_test` unit + widget against fakes — `NetworkResearchService` fake (Tavily
call / fetch_page / all error paths), `SecureKeyStore` fake (read/write/clear), `HtmlExtractor`
unit tests against the 11 HTML fixtures in `specs/006-web-research/fixtures/`, `ToolRegistry`
web-tools triple-gate + spec shape, `SchemaValidator` URL-scheme allowlist + maxLength on query,
dispatcher web handlers (search success/zero-results/error types, fetch success/truncation/error
types, URL validation), `EffectiveWebToggle` resolver (all 6 combinations of global × per-convo
state), `ContextAssembler` web-tools reserve, controller (search chip, fetch chip, toggle→
startSession, key-clear→tools-absent, offline error chip), seeded **v5 file DB** v5→v6 migration
test (both new columns, correct defaults), web research settings screen widget (toggle off by
default, key mask/clear, microcopy present + names Tavily + names direct-fetch, toggle blocked
without key), per-conversation toggle widget + persistence, source URL chip render + tap + history
load, a11y. No device/plugin/network in tests (Principle VII). Device verification via
[quickstart.md](quickstart.md) — **`flutter run`/`flutter drive` only**.

**Target Platform**: Android, arm64-v8a, API 29+ (unchanged). New permissions required:
`INTERNET` (already declared for model download — confirm it is present; no new Android manifest
addition if so). No new runtime prompts; no new user-facing Android permissions.

**Performance Goals**: `web_search` + answer e2e latency: `TODO(device: fill after A34 harness
run — SC-002)`; tool result sizes guaranteed within the handler-enforced ceilings (web_search ≤
~1,220 chars, fetch_page ≤ 2,000 chars); `startSession` on toggle change adds only a ~ms chat
recreation (no re-mmap, identical to 005 R1). Budget arithmetic holds: ~1,156 tokens remaining
for chat + turn with all features active (R9).

**Constraints**: opt-in, off by default (FR-001, Principle I); Tavily key never in DB/logs/model
context (FR-003, SC-015); ALL http in `NetworkResearchService` seam (`check_plugin_seam.sh` +
`check_network_seam.sh` both stay green, SC-014); one tool call per user turn (seam contract,
spike §4.3); tool declarations structurally absent when any gate condition is false — never refused
at runtime (FR-006); every outbound call names its true recipient in a chip before the request
fires (FR-022); fetch_page direct to target site, NOT via Tavily (FR-016); `fetch_page`
tool-result bound is **2,000 chars** — NOT 1,500 (FR-014 authoritative; spec's 2,000-char figure
supersedes the spike's draft 1,500-char sketch); `content` field name never renamed to `snippet`
in any serialization layer (FR-010); offline → typed error chip, no retry (FR-020); raw tool-call
JSON never rendered (004 LeakFilter, FR-026); full snippet/extracted text never persisted (FR-024);
red reserved for error/destructive only; 48dp/AA on all new surfaces (Principle VI); exactly one
model active, no new models or seam sessions beyond the cheap chat recreation (Principle VIII).

**Scale/Scope**: single local user; two new tools; one new `NetworkResearchService` seam + one new
`SecureKeyStore` seam; one new settings screen + one composer quick-toggle; two additive migration
columns; `HtmlExtractor` class; typed error hierarchy; provider wiring. No new layers. Three new
packages (all seam-isolated). The `fetch_page` internal extraction budget is ~4,000 tokens;
the tool-result bound returned to the model is 2,000 chars (authoritative).

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.* Constitution **v2.0.0**.
Legend: ✅ satisfied by design · ⚠ implementation caution (carried into tasks/quickstart).

| # | Principle | Gate — how this plan satisfies it | Status |
|---|-----------|-----------------------------------|--------|
| I | Privacy Is the Product (opt-in egress safeguards) | **This is the first feature to use opt-in egress under v2.0.0 Principle I. Each safeguard is explicitly verified:** (a) **Opt-in toggle off by default** — `webAccessEnabled` defaults to false in `app_settings`; `webAccessOverride` defaults to NULL (inherit-global) in conversation rows; no egress occurs until the user explicitly enables the toggle (FR-001). (b) **Visible chip naming true recipient** — `web_search` chips show `WEB_SEARCH · Tavily` (recipient = Tavily API) at running state, before the request completes; `fetch_page` chips show `FETCH_PAGE · [domain]` (recipient = target website, which is NOT Tavily — the distinction is mandatory under FR-016/FR-022; the user is told the device contacts the target website directly). No silent network call is possible because tools are structurally absent from the registry when web access is off (FR-006). (c) **Offline degradation** — tools absent → pre-006 behavior; tools present but no connectivity → typed `OfflineError`, red chip, no retry, model answers from own knowledge (FR-020, Principle II). The app never breaks offline regardless of toggle state (SC-004). (d) **Auditable persistence** — every tool call is persisted as a `role='tool'` message row with query/url, status, and source URL list (FR-024). Source URL chips survive app restarts and render independently of key/toggle state (FR-025). The full Tavily `content` body and extracted page text are intentionally NOT persisted (Decision 4). (e) **Named recipient** — `web_search` names "Tavily" in both the chip AND the Settings microcopy (FR-002); `fetch_page` names the target-website domain in the chip (`FETCH_PAGE · flutter.dev`) AND the Settings microcopy explicitly discloses "when you fetch a page, your device contacts that website directly — not tavily" (FR-002 mandatory copy requirement). Both recipients are individually named per egress path. (f) **Key security** — BYOK key stored in `flutter_secure_storage ^10.3.1` (Android Keystore-backed AES/GCM); key NEVER written to SQLite DB, any log, crash report, or model context (FR-003, SC-015). `check_network_seam.sh` and `check_plugin_seam.sh` both stay green (SC-014). | ✅ |
| I | Privacy — key never in DB/logs/context | The `SecureKeyStore` seam is the only importer of `flutter_secure_storage`; no widget, provider, or domain class reads the key directly. The key is forwarded to the `Authorization: Bearer` header inside `TavilyNetworkResearchService` only. The 004 LeakFilter + `tool_result` persistence schema (metadata only, no key) ensure the key never surfaces in conversation history. | ✅ |
| II | Offline-First | Core chat, memory, and all pre-006 features continue to function with zero connectivity — web egress is an enhancement, never a prerequisite. When web tools are declared but no connectivity is present, `InternetAddress.lookup` fails immediately, `OfflineError` is returned, a red chip is rendered, and the model answers from its own knowledge — no hang, no retry, no crash (FR-020, SC-004). Airplane-mode pass is device validation step V14. | ✅ |
| III | Capability-Driven UX | Web tools are declared strictly via the triple gate: `functionCalling && effectiveWebEnabled && hasValidKey`. The capability `functionCalling` is data from the model catalog (same structural coupling as 004/005); the other two flags are user preferences. Tools are structurally absent from the registry when any gate is false — not refused at runtime (FR-006). The `effectiveWebEnabled` resolver is a pure function of the three-state per-conversation override and the global flag (FR-007). | ✅ |
| IV | Responsive & Cancellable | Web tool round-trips reuse the existing 004 streamed tool turn + stop path. Network timeouts are enforced per-request (`kTavilyTimeoutMs = 10000`, `kFetchTimeoutMs = 15000`) with `Future.timeout` wrapping `abortTrigger` completion — the request is aborted, not just abandoned, on timeout. `startSession` on toggle change adds only a ~ms chat recreation (no re-mmap). The UI remains interactive during the in-flight chip's running state. | ⚠ Verify `startSession` on web-toggle change adds no perceptible hitch — quickstart V12 |
| V | Graceful Degradation | Full typed-error taxonomy (OfflineError, KeyInvalidError, RateLimitError, ProviderError, FetchDomainError, ParseError, TimeoutError) maps to distinct plain-language red chips. Zero-result web_search renders a success chip "0 results" (FR-033). Fetch of JS-rendered or binary resources returns what was extracted with an honest chip. Invalid args (empty query, over-length query, non-http(s) URL) are caught at the dispatcher before any network call (FR-031, FR-015). No path crashes the turn. | ⚠ Implement the full error taxonomy matrix — contracts/network_research_service.md |
| VI | Dark-First & Accessible | All new chips and settings elements use centralized design tokens. Destructive actions (key clear, toggle off with side-effect) use the sanctioned red. Error chips use red. All new interactive surfaces ≥ 48dp touch-target; Settings microcopy meets AA contrast. Accessibility Scanner pass is quickstart V15. | ⚠ Accessibility Scanner pass — quickstart V15 |
| VII | Testable Through a Plugin Seam | `NetworkResearchService` is an abstract interface; its fake (`FakeNetworkResearchService`) is the test double for all unit + widget tests. `SecureKeyStore` is an abstract interface with a `FakeSecureKeyStore`. `HtmlExtractor` is pure Dart (no plugin import). No widget, provider, or domain class imports `package:http`, `flutter_secure_storage`, or `package:html` directly — all confined to `lib/infrastructure/network/`. Plugin-seam shell guard updated for both new packages. flutter_gemma stays behind `GemmaService`. | ✅ |
| VIII | Resource Hygiene | No new model or long-lived session beyond the cheap chat recreation on toggle change. Network connections are short-lived (one-shot POST/GET with timeout + abort). `SecureKeyStore` writes a single string; no file on disk. `HtmlExtractor` operates in a single synchronous pass over a DOM tree and does not retain references. Source URL chips are bounded (≤ 3 per web_search call). | ✅ |
| IX | Lean Scope | Exactly the spec slice: two tools, snippets-only single-call design (spike §4.4 — intra-turn chaining is out of scope), BYOK Tavily only (no Wikipedia fallback, no multi-provider), one-round-trip-per-turn contract unchanged. Three new packages chosen for zero-overlap and minimum binary cost (R1–R3). No sync/export/analytics/proxy/backend. | ✅ |
| X | Design Identity | `web_search` and `fetch_page` chips reuse the 004 §8 `ToolChip` treatment verbatim. Source URL chips follow the design-system link/chip pattern. Settings screen reuses the existing list/section pattern. Red only on destructive/error. Lowercase microcopy. Centralized tokens throughout. | ✅ |
| — | Technology & Platform Constraints | Stack extended minimally: three seam-isolated packages (lean, official, seam-isolated). SQLite + drift unchanged. INTERNET permission already declared (model download). No new Android permissions. No new native-code packages that could collide with flutter_gemma FFI. | ✅ |
| — | Privacy gate (v2.0.0 Development Workflow) | Content-bearing calls are behind an opt-in toggle (off by default) ✅; visibly indicated at call time (chip names recipient before request fires) ✅; offline-degrading ✅; named recipient per egress path (Tavily for search; target-website domain for fetch) ✅; auditable (tool row persisted with metadata) ✅. All five criteria met. | ✅ |

**Gate result**: PASS. No principle is violated; three ⚠ items are device-verification cautions
carried into quickstart/tasks. **Complexity Tracking is therefore empty.**

## Post-Phase-0 Spike Re-Check

Evaluated against the Phase 0 spike findings (spike-findings.md):

- **I (egress safeguards)**: every named safeguard maps 1:1 to a spec requirement (FR-001 through
  FR-034). The spike confirms the tool chip architecture and the `WEB_SEARCH · Tavily` /
  `FETCH_PAGE · [domain]` distinction was designed from the start. `check_network_seam.sh` remains
  the audit mechanism.
- **II (offline)**: spike §4.3/§4.4 source inspection confirms no mid-turn chaining — the
  one-round-trip contract means no opportunity for a half-executed chain to leave the device in a
  broken state offline.
- **III (capability as data)**: the triple gate is data-driven (functionCalling from catalog, flags
  from settings); no per-model `if` branches.
- **IV/V (responsive/graceful)**: full timeout/abort path confirmed (R1); error taxonomy complete
  per spike §1.2 provider error codes + §2 fetch error types (R4, R5).
- **VII/VIII (seam/hygiene)**: confirmed by R8 (`lib/infrastructure/network/` layout) and R3
  (pure-Java `flutter_secure_storage`, no native conflict). `check_plugin_seam.sh` audit path
  documented (R8).
- **IX (lean)**: spike §4.5 formally rules out intra-turn chaining; `fetch_page` is cross-turn
  user-driven (Decision 2), keeping the seam contract unchanged.

**Re-check result**: PASS — unchanged from the pre-spike gate; three ⚠ device cautions tracked
in quickstart V12/V14/V15.

## Project Structure

### Documentation (this feature)

```text
specs/006-web-research/
├── spike-findings.md        # Phase 0 spike (§1–§4 PASSED; §5 device TODO pending)
├── plan.md                  # This file
├── research.md              # R1–R9 (pinned deps + locked design decisions)
├── data-model.md            # v5→v6 migration, error taxonomy, tool-result schemas, toggle resolution
├── quickstart.md            # Device validation V1–V15
├── contracts/
│   ├── network_research_service.md    # search() / fetchPage() / error taxonomy / fake contract
│   ├── secure_key_store.md            # readTavilyKey() / writeTavilyKey() / clearTavilyKey() / hasValidKey() / fake contract
│   └── web_research_tools.md          # webTools specs, URL-scheme check, result bounds, handlers, gating contract
├── fixtures/                # 11 HTML fixture files for HtmlExtractor unit tests (spike corpus)
├── spike-harness/           # spike_web_research_test.dart + README (DO NOT SHIP; remove before merge)
├── checklists/requirements.md
└── tasks.md                 # Phase 2 (/speckit-tasks)
```

### Source Code (repository root) — changes layered on the existing 004/005 tree

```text
lib/
├── core/
│   └── tools/
│       ├── tool_registry.dart          # CHANGED — + webTools list (web_search + fetch_page specs)
│       └── schema_validator.dart       # CHANGED — + URL-scheme allowlist check (http/https only)
├── domain/
│   ├── entities/
│   │   ├── app_settings.dart           # CHANGED — + webAccessEnabled (bool, default false)
│   │   └── conversation.dart           # CHANGED — + webAccessOverride (nullable enum: inherit/on/off)
│   └── services/
│       ├── gemma_service.dart          # unchanged interface — startSession() already present from 005
│       └── secure_key_store.dart       # NEW — SecureKeyStore interface (no plugin import)
├── data/
│   ├── db/
│   │   ├── tables.dart                 # CHANGED — webAccessOverride column + webAccessEnabled column
│   │   └── app_database.dart           # CHANGED — schemaVersion 6, v5→v6 migration
│   └── repositories/
│       └── settings_repository.dart    # CHANGED — read/write webAccessEnabled + key-clear side-effect
├── infrastructure/
│   ├── gemma/
│   │   └── flutter_gemma_service.dart  # unchanged — startSession() already present from 005
│   ├── media/
│   └── network/                        # NEW directory
│       ├── network_research_service.dart         # abstract interface (domain import-safe)
│       ├── tavily_network_research_service.dart  # concrete impl; imports http only
│       ├── html_extractor.dart                   # pure Dart extraction pipeline (no plugin imports)
│       ├── research_errors.dart                  # typed error classes (OfflineError, ProviderError, …)
│       └── flutter_secure_key_store.dart         # concrete SecureKeyStore impl; imports flutter_secure_storage only
│   └── tools/
├── features/
│   ├── chat/
│   │   ├── chat_providers.dart         # CHANGED — webTools into triple-gate composition; effectiveWebEnabled
│   │   ├── chat_controller.dart        # CHANGED — startSession on web-toggle change; source URL chip dispatch
│   │   ├── context_assembler.dart      # CHANGED — + webToolsReserveTokens (~80) when webTools declared
│   │   ├── tool_handler_providers.dart # CHANGED — web_search + fetch_page handlers → NetworkResearchService
│   │   └── widgets/
│   │       └── web_toggle_button.dart  # NEW — three-state per-conversation web quick toggle in composer
│   └── settings/
│       ├── web_research_screen.dart    # NEW — global toggle (off by default), BYOK key entry/mask/clear,
│       │                               #       FR-002 microcopy, toggle blocked without key
│       ├── web_research_controller.dart # NEW — key read/write/clear, toggle actions, key-clear→toggle-off
│       └── settings_screen.dart        # CHANGED — entry row → web research screen
├── app/router.dart                     # CHANGED — route to the web research settings screen
test/
├── unit/  (NetworkResearchService fake: search/fetch/all error paths; SecureKeyStore fake;
│          HtmlExtractor × 11 fixtures; ToolRegistry webTools triple-gate; SchemaValidator URL
│          scheme + maxLength; ToolDispatcher web handlers success/zero/error/truncation/URL-
│          validation; EffectiveWebToggle resolver × 6 combinations; ContextAssembler web reserve;
│          research_errors taxonomy mapping)
├── widget/ (web research settings screen: toggle off by default, key mask/clear, microcopy
│           names Tavily + names direct-fetch, toggle blocked without key; per-conversation
│           web toggle persistence; source URL chip render + tap + history load; web tool chip
│           running/success/error states; capability-off regression; a11y)
└── data/  (v5→v6 seeded-file migration test: both new columns, correct defaults;
│          webAccessOverride NULL + overrides; prior migration_v*_test seeds updated with
│          new columns + schemaVersion bumped to 6 per house rule)
integration_test/  (reliability harness — 20-prompt suite; flutter drive; quickstart V10/V11)
specs/006-web-research/fixtures/  (11 HTML fixture files: news-bbc-1.html, news-guardian-1.html,
                                    docs-mdn-1.html, docs-dart-1.html, wikipedia-1.html,
                                    wikipedia-2.html, blog-overreacted-1.html, blog-jvns-1.html,
                                    blog-fowler-1.html, gov-data-1.html, gov-nist-1.html —
                                    same corpus as spike §2; binary/non-HTML ParseError test case
                                    is SYNTHESISED in-code in html_extractor_test.dart, no binary
                                    fixture file on disk)
```

**Structure Decision**: same layered single-app structure as 001–005. The only structural novelty
is `lib/infrastructure/network/` (a new sub-directory of the existing `infrastructure/` layer),
`lib/domain/services/secure_key_store.dart` (a second seam interface alongside `gemma_service`),
and `lib/features/settings/web_research_screen.dart` (a second feature screen inside the existing
settings feature). All other changes are extensions to existing files. No new plugin confinement
zone is needed for `package:http` and `package:html` (pure-Dart, no native code) beyond the
import-guard rule in `check_plugin_seam.sh`.

## Complexity Tracking

> No constitutional violations — table intentionally empty (see Constitution Check). The two
> judgment calls are: (1) bespoke `HtmlExtractor` heuristics (5 rules, no readability package)
> chosen to avoid an unmaintained native-FFI dep (R2); (2) `InternetAddress.lookup` connectivity
> probe instead of `connectivity_plus` chosen to avoid a Gradle constraint conflict and because
> `connectivity_plus` does not detect internet reachability anyway (R5). Both are documented in
> research.md with the rejected alternatives.
