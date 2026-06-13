# Tasks — 006 Web Research

**Input**: [plan.md](plan.md), [spec.md](spec.md), [data-model.md](data-model.md),
[contracts/](contracts/), [spike-findings.md](spike-findings.md).

Conventions: `[P]` = parallelizable (different files, no dependency on an unfinished task in the
same phase). Each task names its file(s) and the FR(s) it satisfies. Device tasks use `flutter run`
/ `flutter drive` ONLY — NEVER `flutter test integration_test/...` (wipes the model + DB). Tests
are written before/with their implementation (house TDD pattern). Story phases (US1–US8) are
independently testable slices; the Foundational phase blocks all of them.

---

## Phase 1 — Setup

- [x] **T001** Confirm that `http: ^1.6.0` is either already transitive (via `background_downloader`)
  or add it as an explicit dep; add `html: ^0.15.6`; add `flutter_secure_storage: ^10.3.1`.
  Sanity-run `flutter pub get` + `tool/check_plugin_seam.sh` (must stay green). Record exact
  resolved versions. *(pubspec.yaml — research R1–R3; plan §Technical Context)*

- [x] **T002** [P] Remove the Phase 0 throwaway harness
  `integration_test/spike-harness/spike_web_research_test.dart` (DO NOT SHIP; spike findings
  captured in spike-findings.md). The shipped reliability harness is created in T060.
  *(specs/006-web-research/spike-harness/)*

---

## Phase 2 — Foundational (BLOCKS every user story)

### Domain entities (parallelizable)

- [x] **T003** [P] `WebSearchResult` value object: `title`, `url`, `content` (NOT renamed to
  `snippet` — FR-010), `score`. *(lib/domain/entities/web_search_result.dart; data-model §1)*

- [x] **T004** [P] `FetchResult` value object: `url`, `extractedText`, `wasTruncated`. (`domain`
  is NOT a field — it is derived at chip-render time via `Uri.parse(url).host`.)
  *(lib/domain/entities/fetch_result.dart; data-model §1, contracts/network_research_service.md)*

- [x] **T005** [P] `WebAccessOverride` enum (`inherit` / `on` / `off`) + `effectiveWebEnabled(bool
  globalEnabled)` method; `null`-to-`inherit` coercion documented. *(lib/domain/entities/
  web_access_override.dart; data-model §1, FR-007)*

- [x] **T006** [P] Extend `AppSettings` with `webAccessEnabled` (`bool`, default `false`) +
  `copyWith`/eq/hash. *(lib/domain/entities/app_settings.dart; data-model §1, FR-001)*

- [x] **T007** [P] Extend `Conversation` entity with `webAccessOverride`
  (`WebAccessOverride?`, default `null` = `inherit`). *(lib/domain/entities/conversation.dart;
  data-model §1, FR-007)*

### Seam interfaces (parallelizable)

- [x] **T008** [P] `SecureKeyStore` interface: `readTavilyKey()`, `writeTavilyKey(String)`,
  `clearTavilyKey()`, `hasValidKey()`. No `flutter_secure_storage` import here — pure Dart.
  *(lib/domain/services/secure_key_store.dart; contracts/secure_key_store.md, FR-003)*

- [x] **T009** [P] `NetworkResearchService` interface: `search(String query)`, `fetchPage(String url)`.
  No `package:http` import — pure Dart. *(lib/domain/services/network_research_service.dart;
  contracts/network_research_service.md, FR-018)*

### Error taxonomy

- [x] **T010** [P] `ResearchError` sealed hierarchy: `OfflineError`, `ProviderError` +
  `KeyInvalidError` + `RateLimitError` + `HttpError`, `FetchDomainError`, `ParseError`,
  `TimeoutError`. *(lib/infrastructure/network/research_errors.dart; data-model §4, FR-019,
  FR-034)*

### Drift schema migration

- [x] **T011** Add `webAccessOverride` (nullable TEXT) column to `Conversations` table and
  `webAccessEnabled` (BOOL, default false) column to `AppSettingsTable`.
  *(lib/data/db/tables.dart; data-model §2, FR-030)*

- [x] **T012** Bump `schemaVersion` 5 → 6 and add the `from < 6` migration block:
  `m.addColumn(conversations, conversations.webAccessOverride)` +
  `m.addColumn(appSettingsTable, appSettingsTable.webAccessEnabled)`. Run
  `dart run build_runner build`. *(lib/data/db/app_database.dart, app_database.g.dart;
  data-model §2, FR-030)*

- [x] **T013** **Migration test — v5 → v6** — seed a real v5 file DB (conversations + messages +
  model_installs + app_settings WITH `memory_enabled` + memories + both indexes), open at v6:
  (1) existing conversation rows have `web_access_override = null`; (2) app_settings row has
  `web_access_enabled = false`; (3) memories rows untouched; (4) a new conversation row with
  `web_access_override = 'on'` round-trips; (5) `null` round-trips as `null`; (6) setting
  `web_access_enabled = true` persists; (7) `db.schemaVersion == 6`.
  **Seed-gotcha**: update ALL prior `migration_v*_test` seeds that touch `conversations` or
  `app_settings_table` — add the two new columns with defaults AND bump their `schemaVersion`
  asserts to 6 (`migration_v4_to_v5_test.dart`, `migration_v3_to_v4_test.dart`,
  `migration_v2_to_v3_test.dart`, `migration_v1_to_v2_test.dart`).
  *(test/data/migration_v5_to_v6_test.dart + update four prior seeds; data-model §5)*

### Network constants + infrastructure stubs

- [x] **T014** [P] `network_constants.dart`: `kTavilyTimeoutMs = 10000`, `kFetchTimeoutMs = 15000`,
  `kConnectivityTimeoutMs = 3000`, `kMaxExtractedTokens = 4000`, `kFetchResultCharBound = 2000`,
  `kMaxSearchResults = 3`. *(lib/infrastructure/network/network_constants.dart;
  contracts/network_research_service.md)*

**Checkpoint**: Foundation complete — entities, seam interfaces, error taxonomy, migration done.
Domain-layer work and test doubles can now proceed in parallel.

---

## Phase 3 — US7: Infrastructure seams + test doubles (Priority: P2 — blocks US1–US6)

> Built before the tool surface because every handler test and gating test depends on working fakes.

- [x] **T015** [P] `FakeSecureKeyStore` test double: in-memory `String? _storedKey`; all four
  interface methods with synchronous `Future.value` returns; `clearWasCalled` flag.
  *(test/helpers/fake_secure_key_store.dart; contracts/secure_key_store.md, Principle VII)*

- [x] **T016** [P] `FakeNetworkResearchService` test double: configurable stubs
  `stubSearch(query, result)` / `stubSearchError(query, error)` / `stubFetch(url, result)` /
  `stubFetchError(url, error)`; call logs `searchCallLog`, `fetchCallLog`; throws `TimeoutError`
  when configured. No `package:http`. *(test/helpers/fake_network_research_service.dart;
  contracts/network_research_service.md, Principle VII)*

- [x] **T017** [P] `secureKeyStoreProvider` (`Provider<SecureKeyStore>`; implementation =
  `FlutterSecureKeyStore`) + `networkResearchServiceProvider` (`Provider<NetworkResearchService>`;
  implementation = `TavilyNetworkResearchService`) — stubs overridden in tests.
  *(lib/infrastructure/network/flutter_secure_key_store.dart,
  lib/infrastructure/network/tavily_network_research_service.dart — STUBS only, real impl
  in T022–T023; provider registration in lib/features/... providers)*

- [x] **T018** [P] **SecureKeyStore unit tests**: write-then-read round-trip; `hasValidKey` after
  write/clear; idempotent clear; `clearWasCalled` flag; no key in exceptions. Run against
  `FakeSecureKeyStore`. *(test/unit/secure_key_store_test.dart; contracts/secure_key_store.md)*

**Checkpoint**: Fakes ready — all unit/widget tests can use `FakeNetworkResearchService` and
`FakeSecureKeyStore` without any real network or Keystore calls.

---

## Phase 4 — US7: SchemaValidator + ToolRegistry web tools (blocks US1, US4, US7)

- [x] **T019** [P] **SchemaValidator unit tests** — new `format: uri` keyword: valid HTTP/HTTPS
  URLs pass; non-URI strings, URIs with no scheme, non-http(s) schemes fail with distinct messages
  ("not a valid URI" vs "scheme must be http or https"); `maxLength` on `url`; existing 004/005
  tests still pass. *(test/unit/schema_validator_test.dart; contracts/web_research_tools.md)*

- [x] **T020** [P] Extend `SchemaValidator` with `format: uri` keyword (validate with `Uri.tryParse`
  + `hasScheme` + `hasAuthority` check; scheme-allowlist check is a SEPARATE step).
  *(lib/core/tools/schema_validator.dart; contracts/web_research_tools.md, FR-015)*

- [x] **T021** Add `webTools` list (`web_search` + `fetch_page` `ToolSpec`s) to `ToolRegistry`;
  update `specs` = `deviceTools + memoryTools + webTools`. `web_search`: `query` (string,
  minLength 1, maxLength 400, required). `fetch_page`: `url` (string, format uri, maxLength 2048,
  required). Both `resultCharBound: 2000`. Update registry-sanity test: 8 tools total, unique
  names, every schema self-validates, `kind` set, `content` field name present in `web_search`
  description (FR-010). *(lib/core/tools/tool_registry.dart; contracts/web_research_tools.md,
  FR-010, FR-011, FR-014)*

**Checkpoint**: Tool specs in registry; schema validator covers URL format — dispatcher handlers
can be wired.

---

## Phase 5 — US1 + US4: HtmlExtractor + NetworkResearchService concrete impl (Priority: P1 + P2)

### HtmlExtractor (pure Dart, parallelizable)

- [x] **T022** [P] **HtmlExtractor unit tests** against all 11 saved fixtures in
  `specs/006-web-research/fixtures/` (news-bbc-1.html, news-guardian-1.html, docs-mdn-1.html,
  docs-dart-1.html, wikipedia-1.html, wikipedia-2.html, blog-overreacted-1.html,
  blog-jvns-1.html, blog-fowler-1.html, gov-data-1.html, gov-nist-1.html): (a) extraction
  quality — readable text present, boilerplate absent, correct priority-order selection (`article
  > main > [role="main"] > class/id heuristics > body`); (b) Wikipedia rule — `p`-only
  extraction (no navboxes/infoboxes); (c) hard-truncation at `kFetchResultCharBound = 2000`
  chars: output ≤ 2000 chars with `[truncated: N items remaining]` appended; (d) binary/non-HTML
  content-type → `ParseError` — this test case is SYNTHESISED in-code (a fake `application/pdf`
  response body is constructed inline in the test; there is NO binary fixture file on disk).
  *(test/unit/html_extractor_test.dart; contracts/network_research_service.md guarantee 5,
  FR-014, SC-006)*

- [x] **T023** [P] `HtmlExtractor` class: priority-order DOM selection; boilerplate removal;
  Wikipedia p-only heuristic; link-density guard; applies `kMaxExtractedTokens` ceiling
  internally; hard-truncates final output to `kFetchResultCharBound` with marker; detects
  non-HTML content-type → throws `ParseError`. Pure Dart — NO plugin imports.
  *(lib/infrastructure/network/html_extractor.dart; data-model §1, FR-014, SC-006)*

### NetworkResearchService concrete implementation

- [x] **T024** [P] **NetworkResearchService integration tests** (against `FakeNetworkResearchService`
  + mocked HTTP): `search()` success path — returns ≤ 3 `SearchResult`s with `content` field
  (not `snippet`); zero-results array; `KeyInvalidError` on 401/403; `RateLimitError` on 429;
  `ProviderError` on 500; `OfflineError` on `SocketException`; `TimeoutError` on deadline.
  `fetchPage()` success — `FetchResult` with text ≤ 2000 chars; `FetchDomainError` on target-site
  non-2xx; `ParseError` on empty extraction; `TimeoutError`. Pre-flight `InternetAddress.lookup`
  failure → `OfflineError` before HTTP call. *(test/unit/network_research_service_test.dart;
  contracts/network_research_service.md; FR-019, FR-034)*

- [x] **T025** `TavilyNetworkResearchService` concrete impl: `search()` — pre-flight
  `InternetAddress.lookup` + POST `https://api.tavily.com/search` (Bearer header, `max_results:3`,
  `content` field — NOT `snippet`, FR-010), parse top 3 results, full typed-error mapping.
  `fetchPage()` — pre-flight + GET target URL (direct, NOT via Tavily), feed response body to
  `HtmlExtractor`, typed-error mapping. `kTavilyTimeoutMs` + `kFetchTimeoutMs` via
  `Future.timeout` + abort trigger. `StateError` guard when no valid key. Imports `package:http`
  ONLY in this file. *(lib/infrastructure/network/tavily_network_research_service.dart;
  contracts/network_research_service.md, FR-010, FR-018, FR-020)*

- [x] **T026** `FlutterSecureKeyStore` concrete impl: all four interface methods backed by
  `flutter_secure_storage`; no `encryptedSharedPreferences: true` (deprecated in 10.x); key never
  logged; exceptions caught, key string not exposed. Imports `flutter_secure_storage` ONLY in this
  file. *(lib/infrastructure/network/flutter_secure_key_store.dart; contracts/secure_key_store.md,
  FR-003, SC-015)*

- [x] **T027** [P] **Plugin-seam guard update**: extend `tool/check_plugin_seam.sh` (or equivalent)
  with import-guard rules for `package:http`, `flutter_secure_storage`, and `package:html` —
  these three packages must be imported ONLY within `lib/infrastructure/network/`. Add analogous
  rules to `tool/check_network_seam.sh`. Confirm both scripts are green after T025–T026.
  *(tool/check_plugin_seam.sh, tool/check_network_seam.sh; FR-018, SC-014, Principle VII)*

**Checkpoint**: Extraction pipeline and concrete seam implementations complete. Handler and gating
tests can now run end-to-end.

---

## Phase 6 — US1: web_search handler + gating + chip (Priority: P1) MVP write loop

- [x] **T028** [P] **Dispatcher handler unit tests** (using `FakeNetworkResearchService` +
  `FakeSecureKeyStore`):
  - `web_search` success → `ToolSuccess` with JSON `{results:[{title,url,content,score},...]}`;
    `content` field name not `snippet` (FR-010); combined result ≤ 2000 chars.
  - `web_search` zero results → `ToolSuccess` with `{results:[],note:"no results found..."}`;
    success chip, no source URLs (FR-033).
  - `web_search` invalid args: empty query → `ToolInvalidArgs("query is empty")`; >400-char
    query → `ToolInvalidArgs("query too long...")`; absent `query` key → `ToolInvalidArgs`.
  - `web_search` `OfflineError` → `ToolFailure("offline — no connection")`.
  - `web_search` `KeyInvalidError` → `ToolFailure("tavily key invalid — check Settings")`.
  - `web_search` `RateLimitError` → `ToolFailure("tavily limit reached...")`.
  - `web_search` `ProviderError(503)` → `ToolFailure("provider error (HTTP 503)")`.
  - `web_search` `TimeoutError` → `ToolFailure("request timed out — try again")`.
  - `web_search` `StateError` when no key → propagated as `ToolFailure`.
  - Congruence: when triple gate is true, handler map covers `web_search`; when false, absent.
  *(test/unit/tool_dispatcher_web_search_test.dart; contracts/web_research_tools.md, FR-010,
  FR-011, FR-027, FR-031, FR-033)*

- [x] **T029** [P] **Triple-gate unit tests** — `EffectiveWebToggle` resolver (all 6 combinations of
  global × per-conversation state): `inherit+global-on=true`, `inherit+global-off=false`,
  `explicitly-on+global-off=true`, `explicitly-on+global-on=true`, `explicitly-off+global-on=false`,
  `explicitly-off+global-off=false`. Tools absent when `functionCalling=false`; absent when no key
  regardless of toggles; absent when `effectiveWebEnabled=false`; present only when all three true.
  *(test/unit/effective_web_toggle_test.dart; data-model §1, FR-006, FR-007, SC-009, SC-010)*

- [x] **T030** Bind `web_search` handler to `NetworkResearchService.search()` in
  `toolHandlersProvider`; `StateError` structural guard when `hasValidKey() == false`.
  *(lib/features/chat/tool_handler_providers.dart; contracts/web_research_tools.md, FR-006)*

- [x] **T031** Compose `declaredTools` in the session provider: add `webTools` to the triple-gate
  branch (`functionCalling && effectiveWebEnabled && hasValidKey`). Add
  `webAccessEnabledProvider` (Notifier over `app_settings.webAccessEnabled`). Add
  `conversationWebOverrideProvider(conversationId)` family provider.
  *(lib/features/chat/chat_providers.dart; data-model §6, FR-006, FR-007)*

- [x] **T032** [P] `ContextAssembler`: add `webToolsReserveTokens = 80` when `webTools` are
  declared; extend reserve-math tests to assert running total with all three feature reserves
  active (~1,156 tokens remaining). *(lib/features/chat/context_assembler.dart, test/unit/;
  data-model §7, plan §Context budget)*

- [x] **T033** [P] Chip summary text for `web_search`: running chip `WEB_SEARCH · Tavily`;
  success chip `3 results for "<query>"`; zero-results chip `0 results`; error chip uses
  plain-language reason. Source URL chips dispatch below the response (one per result URL);
  tapping opens browser via `android_intent_plus`. *(lib/features/chat/chat_controller.dart;
  FR-012, FR-013, FR-022, FR-023, FR-033)*

- [x] **T034** [P] **Widget test** (using `FakeNetworkResearchService`): a `web_search` chip renders
  with running → success transition; source URL chips appear beneath the model reply; tapping a
  source chip calls the browser intent; zero-results renders a success chip with "0 results" and
  no source chips; an error prompt renders the red error chip + text reply (US1 AS1–AS4;
  SC-007, SC-012). *(test/widget/web_search_chip_test.dart; FR-012, FR-013, FR-033)*

**Checkpoint**: US1 complete — `web_search` tool registered, gated, handler bound, chips rendering,
source URLs tappable. MVP search loop is end-to-end.

---

## Phase 7 — US4: fetch_page handler + chip (Priority: P2)

- [x] **T035** [P] **Dispatcher handler unit tests** for `fetch_page`:
  - Success path → `ToolSuccess` with `{url,text,truncated:false}`; text ≤ 2000 chars.
  - Truncation path → text ends with `[truncated: N items remaining]`; `truncated:true`;
    result ≤ 2000 chars (FR-014, SC-006).
  - URL validation: malformed URL → `ToolInvalidArgs("url is not a valid URI")`;
    non-http(s) scheme → `ToolInvalidArgs("url scheme must be http or https")`;
    >2048-char URL → `ToolInvalidArgs("url too long...")`; absent `url` → `ToolInvalidArgs`.
  - `FetchDomainError("flutter.dev")` → `ToolFailure("could not reach flutter.dev...")`.
  - `ParseError` → `ToolFailure("could not extract text from page")`.
  - `OfflineError` → `ToolFailure("offline — no connection")`.
  - `TimeoutError` → `ToolFailure("request timed out — try again")`.
  *(test/unit/tool_dispatcher_fetch_page_test.dart; contracts/web_research_tools.md, FR-014,
  FR-015, FR-027, FR-034)*

- [x] **T036** Bind `fetch_page` handler to `NetworkResearchService.fetchPage()` in
  `toolHandlersProvider`. *(lib/features/chat/tool_handler_providers.dart; FR-006)*

- [x] **T037** [P] Chip summary text for `fetch_page`: running chip `FETCH_PAGE · [domain]`
  (domain = `Uri.parse(url).host`); success chip `fetched [domain]`; error chip; one source URL
  chip for the fetched page. *(lib/features/chat/chat_controller.dart; FR-016, FR-017, FR-022,
  FR-023)*

- [x] **T038** [P] **Widget test**: a `fetch_page` chip shows the correct domain in the chip label
  (e.g. `FETCH_PAGE · flutter.dev`); success renders text answer + one source URL chip; truncation
  path renders `truncated:true` without crash; `FetchDomainError` renders a red chip naming the
  domain; malformed URL arg renders a validation error chip (US4 AS1–AS3).
  *(test/widget/fetch_page_chip_test.dart; FR-016, FR-027)*

**Checkpoint**: US4 complete — `fetch_page` tool registered, handler bound, chips rendering with
correct domain label, truncation handled.

---

## Phase 8 — US2: Settings — BYOK key entry + global toggle (Priority: P1)

> US2 depends on T008 (`SecureKeyStore` interface) and T026 (`FlutterSecureKeyStore` impl). It
> is independent of the chat controller path, so it can be developed in parallel with Phase 7.

- [x] **T039** [P] Extend `SettingsRepository` with `readWebAccessEnabled()`, `setWebAccessEnabled(bool)`,
  and key-clear side-effect (set global toggle to false when key cleared, FR-004).
  *(lib/data/repositories/settings_repository.dart; data-model §6, FR-004)*

- [x] **T040** [P] `WebResearchController` — actions: `saveKey(String)`, `clearKey()` (clears key +
  sets `webAccessEnabled = false` + calls `startSession` without web tools if a session is live —
  FR-004, FR-032), `setGlobalToggle(bool)` (rejects if no key, FR-005). Surfaces `hasKey` stream
  via `hasValidKey()` (not the raw key value — FR-003 masking).
  *(lib/features/settings/web_research_controller.dart; contracts/secure_key_store.md, FR-003,
  FR-004, FR-005)*

- [x] **T041** `WebResearchSettingsScreen`: global toggle (off by default, blocked without a key —
  FR-005); BYOK key entry field + save; masked after save ("saved — tap to replace"); clear-key
  button; FR-002 microcopy: (a) "search queries are sent to tavily's servers", (b) "when you
  fetch a page, your device contacts that website directly — not tavily", (c) "your key never
  leaves your device" (exact copy per design; all three statements mandatory, lowercase,
  design-system voice). Design-system §8 tokens, 48dp/AA. *(lib/features/settings/
  web_research_screen.dart; FR-002, FR-003, FR-004, FR-005, FR-029, SC-013)*

- [x] **T042** Settings entry row → web research screen + route.
  *(lib/features/settings/settings_screen.dart, lib/app/router.dart; FR-008)*

- [x] **T043** [P] **Widget + a11y tests** for `WebResearchSettingsScreen`:
  - Fresh install: toggle is off, no key shown.
  - Key entry + save → key masked ("saved — tap to replace"), toggle now enabled.
  - Attempting to enable toggle without a key → prompt to enter key, toggle stays off (FR-005).
  - Clear key → key field resets, toggle turns off (FR-004).
  - Microcopy test: all three FR-002 disclosure strings are present in the rendered tree.
  - 48dp touch targets + AA contrast on all new elements (SC-013).
  *(test/widget/web_research_settings_test.dart; FR-002, FR-003, FR-004, FR-005, SC-013)*

**Checkpoint**: US2 complete — BYOK key management, global toggle, privacy microcopy all functional
and tested.

---

## Phase 9 — US3: Per-conversation quick toggle (Priority: P2)

> Depends on T031 (`conversationWebOverrideProvider`) and T042 (settings route exists).

- [x] **T044** [P] `WebToggleButton` widget — three-state quick toggle in the composer; initial state
  inherits global default for new conversations; tapping cycles through `inherit→on→off→inherit`
  (or `on/off` shortcut per design); shows a visual indicator when web access is active for the
  conversation. *(lib/features/chat/widgets/web_toggle_button.dart; FR-008, FR-029)*

- [x] **T045** Wire per-conversation toggle: toggling `webAccessOverride` calls
  `GemmaService.startSession(systemInstruction: ...)` (with updated `declaredTools`) BEFORE the
  next user turn (FR-032, same `startSession` pattern as 005 facts-refresh). Persist override in
  the conversation row via `conversationWebOverrideProvider`.
  *(lib/features/chat/chat_controller.dart; FR-008, FR-009, FR-032)*

- [x] **T046** [P] **Widget test** for `WebToggleButton`: global-off + per-convo toggle on → web
  tools active for this conversation; global-on + per-convo toggle off → web tools absent;
  toggle state persists across fake app restart (history load). Mid-conversation toggle change
  → `FakeGemmaService.startSession` called once (FR-032).
  *(test/widget/web_toggle_button_test.dart; FR-007, FR-008, FR-009, FR-032)*

**Checkpoint**: US3 complete — per-conversation three-state toggle persists, session recreation
on change verified.

---

## Phase 10 — US5: Offline degradation + error surface (Priority: P1)

- [x] **T047** [P] **Offline + error taxonomy mapping tests** (with `FakeNetworkResearchService`
  configured to throw each `ResearchError` subtype): each error type produces a distinct
  plain-language red chip message, no crash, no retry (FR-020, SC-004, SC-005). Verify
  `FetchDomainError` message names the domain (distinct from `ProviderError` message — FR-034,
  Constitution Principle I). *(test/unit/error_chip_mapping_test.dart; FR-019, FR-027, FR-034)*

- [x] **T048** [P] **Widget test** — offline scenario: web access on, `OfflineError` thrown →
  red `WEB_SEARCH · Tavily` error chip + plain-language "offline" reason; model still produces
  text reply; no raw JSON rendered; no crash. Invalid key scenario: `KeyInvalidError` → distinct
  red chip message. (US5 AS1–AS4; SC-004, SC-005, SC-012).
  *(test/widget/web_error_chip_test.dart; FR-019, FR-020, FR-027)*

**Checkpoint**: US5 complete — all error taxonomy paths produce correct red chips, offline scenario
safe.

---

## Phase 11 — US6: History persistence + source URL chip rendering (Priority: P2)

- [x] **T049** [P] **Persistence schema tests**: after a `web_search` tool turn, the persisted
  `tool_args` contains only the query string; the `tool_result` column contains `{results:[...],
  sourceUrls:[...]}` with `{title, url}` metadata per result only — the Tavily `content` snippet
  body is computed transiently in-session and NEVER written to the DB (FR-024, SC-008,
  Decision 4). After `fetch_page`, `tool_result` contains `{url, truncated, sourceUrls}` only
  — the extracted body text (`extractedText`) is computed transiently in-session and NEVER written
  to the DB; only the final URL, truncation flag, and source URL are persisted (Decision 4). Error
  rows: `{error:"..."}` only, no key string (FR-003, SC-015). *(test/unit/
  web_tool_persistence_test.dart; data-model §3, FR-024, FR-025)*

- [x] **T050** [P] **Widget test — history load**: a conversation with `web_search` and `fetch_page`
  chips; close + reopen (simulate history load); chips render with correct query/url and status;
  source URL chips are present and tappable (opens browser intent); no full snippet body in the
  rendered content; error chips re-render with original reason; web chips render regardless of
  current web toggle state (FR-025, SC-008). *(test/widget/web_history_chip_test.dart;
  FR-024, FR-025, SC-007, SC-008)*

**Checkpoint**: US6 complete — history fidelity verified, source URL chips survive restart.

---

## Phase 12 — US7 + US8: Gating regression + LeakFilter (Priority: P2 + P3)

- [x] **T051** [P] **Gating regression tests**: (a) `functionCalling = false` → zero web tools
  declared, zero network calls, chat behavior byte-for-byte identical to pre-006 (SC-009);
  (b) no key stored → web tools absent regardless of toggle state (SC-011); (c) both toggles off →
  zero tools, zero network (SC-010); (d) history chips from a prior session render in place under
  any capability state (US7 AS4; FR-025); (e) web off (any combination of toggles, missing key,
  or non-tool-capable model) → app behavior identical to pre-006, zero network calls (FR-021).
  *(test/unit/ + test/widget/; FR-006, FR-021, SC-009, SC-010, SC-011)*

- [x] **T052** [P] **LeakFilter regression test** for web tools: force each invalid-call path via
  `FakeNetworkResearchService` (missing query, malformed url, handler exception); assert no raw
  `{"function_call":...}` text renders in the stream (004 `LeakFilter` applies unchanged); each
  failure produces a red chip + text reply (US8 AS1–AS4; SC-012). *(test/unit/ or test/widget/;
  FR-026, FR-027, FR-028)*

- [x] **T053** [P] **One-tool-per-turn chip-and-skip test**: inject a `ToolCallRequested` event
  after `resumeWithToolResult` has already been called once in the same turn; assert the second
  call is chipped-and-skipped with "call skipped — one tool per turn" and not executed (FR-028,
  spike §4.3). *(test/unit/; contracts/web_research_tools.md)*

**Checkpoint**: US7 and US8 complete — structural gating verified, LeakFilter extended,
one-turn contract held.

---

## Phase 13 — Polish & cross-cutting concerns

- [x] **T054** [P] `flutter analyze` + full unit/widget/data suite green. `dart format`.
  *(repo — SC-014 pre-requisite)*

- [x] **T055** [P] Run `tool/check_plugin_seam.sh` + `tool/check_network_seam.sh` and confirm both
  green: `package:http`, `flutter_secure_storage`, `package:html` confined to
  `lib/infrastructure/network/`; no widget/provider/domain imports. *(SC-014, Principle VII)*

- [x] **T056** [P] Code audit: confirm Tavily key never appears in `tool_args`, `tool_result`,
  any `print`/`debugPrint`/`Logger` call, or any Riverpod state that persists to disk (SC-015).
  *(grep or static analysis; FR-003, SC-015)*

- [x] **T057** [P] `CLAUDE.md` / `AGENTS.md` managed Spec-Kit section updated to 006.
  *(CLAUDE.md)*

- [x] **T058** [P] `checklists/requirements.md` — spec-quality checklist for 006.
  *(specs/006-web-research/checklists/requirements.md)*

---

## Phase 14 — Device validation

- [x] **T059** [P] **INTERNET permission audit**: confirm `<uses-permission android:name=
  "android.permission.INTERNET"/>` is present in `AndroidManifest.xml` (already declared for
  model download — verify before ship). No new runtime permission prompts needed.
  *(android/app/src/main/AndroidManifest.xml)*

- [ ] **T060** Shipped **reliability harness** (`integration_test/`): 20-prompt evaluation suite
  (fact-seeking + current-events + explicit fetch + junk/no-research prompts); verifies SC-001
  (≥ 75% correct `web_search` tool selection) and SC-003 (zero spurious calls on ≥ 5 junk
  prompts); asserts token-budget ceilings (SC-006). Runnable via `flutter drive` (quickstart V10).
  Fills the `TODO(device)` markers in SC-001/SC-002 after the A34 run.
  *(integration_test/web_research_harness_test.dart, test_driver/ — uses `flutter drive` ONLY)*

- [ ] **T061** Device walkthrough V1–V9 (enable + key entry, web search chip, source URL chips,
  per-conversation toggle, fetch_page chip + domain label, offline red chip, key-invalid chip,
  history persistence, settings clear-key) on the A34 via `flutter run`. Fill SC-001/SC-002
  thresholds from harness measurements. *(quickstart.md V1–V9)*

- [ ] **T062** Cross-cutting device gates V10–V15 (reliability harness, airplane-mode offline
  degradation, zero spurious calls on junk prompts, `startSession` toggle-change hitch timing,
  Accessibility Scanner on new surfaces, INTERNET permission confirmed). *(quickstart.md
  V10–V15; SC-002, SC-004, SC-009, SC-013, SC-014)*

---

## Dependencies & parallelization

- **Foundational (T003–T014) blocks everything.** Within it: T003–T010 are [P]; T011→T012→T013
  (migration: tables → schema bump → test + seed-gotcha); T014 [P] alongside T003–T010.
- **Seams + fakes (T015–T018)** depend on Foundational; T015/T016/T017/T018 are [P].
- **Schema validator + registry (T019–T021)** depend on Foundational; T019/T020 [P], T021 depends
  on T020.
- **HtmlExtractor + concrete seams (T022–T027)** depend on T010 (errors) + T014 (constants);
  T022/T023 [P] (pure Dart, no deps on registry); T024 [P] (fake-backed); T025/T026 depend on
  T023; T027 depends on T025/T026.
- **US1 web_search (T028–T034)** depends on T021 (registry) + T016 (fake NRS) + T028→T029 [P];
  T030/T031 depend on T021; T032/T033/T034 [P] after T031.
- **US4 fetch_page (T035–T038)** depends on T021 + T016; T035 [P]; T036 depends on T025;
  T037/T038 [P] after T036.
- **US2 settings (T039–T043)** depends on T008 (interface) + T026 (impl); largely independent of
  the chat controller path; T039/T040 [P]; T041 depends on T039/T040; T043 [P] after T041.
- **US3 per-conversation toggle (T044–T046)** depends on T031 (provider) + T042 (route); T044 [P].
- **US5 offline/error (T047–T048)** depends on T016 (fake) + T028 type assertions; [P] after T031.
- **US6 history (T049–T050)** depends on T033 (persistence wiring) + US1 chip rendering; [P].
- **US7+US8 gating/LeakFilter (T051–T053)** depend on US1+US4 wiring; all [P].
- **Polish (T054–T058)** last before device; [P] within the group.
- **Device (T059–T062)** requires device + clean build; T060–T062 require the device.

**MVP = Foundational + Seams + Registry + Concrete seams + US1 + US2** (a valid key stored →
web search grounded answer → `WEB_SEARCH · Tavily` chip → source URL chips → persisted).
US3/US4/US5/US6/US7/US8 layer on independently.

## Suggested execution order

1. T001–T002 (setup) → T003–T014 (foundational: entities, seams, errors, migration).
2. T015–T018 (fakes) ‖ T019–T021 (schema validator + registry) ‖ T022–T023 (HtmlExtractor).
3. T024–T027 (concrete seam impls + seam guard).
4. T028–T034 (US1 web_search). **← MVP core**
5. T039–T043 (US2 settings) ‖ T035–T038 (US4 fetch_page). **← MVP complete**
6. T044–T046 (US3 per-convo toggle) ‖ T047–T048 (US5 offline) ‖ T049–T050 (US6 history).
7. T051–T053 (US7+US8 gating/LeakFilter).
8. T054–T059 (polish/audit) → T060 (reliability harness) → T061–T062 (device walkthrough + gates).

---

## Definition of Done

The feature is complete when all of the following are satisfied:

- **FR coverage**: all 34 FRs have at least one passing test or device-verified step.
- **SC-001**: ≥ 75% correct `web_search` tool selection on ≥ 20-prompt A34 harness run (device);
  `TODO(device)` markers in SC-001/SC-002 filled.
- **SC-003**: Zero spurious web tool calls on ≥ 5 junk/no-research prompts (device).
- **SC-004**: 100% offline trials produce red error chip; zero crashes; zero network calls.
- **SC-006**: 100% of `web_search` results ≤ ~1,220 chars; 100% of `fetch_page` tool results
  ≤ 2,000 chars — verified by handler-level assertions (NOT 1,500 chars).
- **SC-007**: 100% of successful web tool calls produce ≥ 1 tappable source URL chip.
- **SC-008**: Web chips + source URLs render correctly after app restart; no full snippet body in DB.
- **SC-009/SC-010/SC-011**: Zero web tool declarations under no-capability / both-off / no-key
  conditions — tools structurally absent (verified in unit tests + device).
- **SC-012**: LeakFilter verified — zero raw tool-call JSON rendered.
- **SC-013**: All new interactive elements pass 48dp + AA contrast (Accessibility Scanner, device).
- **SC-014**: `check_plugin_seam.sh` + `check_network_seam.sh` green.
- **SC-015**: Static audit confirms Tavily key absent from DB columns, logs, and Riverpod state.
- **`flutter analyze` green** + full unit/widget/data test suite passes.
- **`dart format` clean**.
- **Spike harness removed** (T002); shipped harness runnable via `flutter drive` (T060).
