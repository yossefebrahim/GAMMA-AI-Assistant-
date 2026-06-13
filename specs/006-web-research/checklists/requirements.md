# Requirements Checklist — 006 Web Research

**Feature branch**: `006-web-research`
**Suite baseline**: 622 tests green (unit + migration)
**Device baseline**: A34 20-prompt harness run pending (tasks T060–T062)

---

## Functional Requirements

### Opt-in & Privacy (Constitution v2.0.0 Principle I)

- [X] **FR-001** — Web research defaults OFF; no query or URL leaves the device without explicit opt-in. `test/unit/features/tool_gating_test.dart` (web tools absent when toggle off)
- [X] **FR-002** — Settings microcopy names both Tavily (search) and target website (fetch_page) as recipients; key-stays-on-device statement required. `test/unit/features/settings_web_copy_test.dart`
- [X] **FR-003** — Tavily API key stored in EncryptedSharedPreferences; never written to SQLite DB, logs, or crash reports; masked in UI after entry. `test/unit/domain/key_storage_test.dart`
- [X] **FR-004** — Key clearable by user; clearing removes key from EncryptedSharedPreferences and turns global toggle off. `test/unit/domain/key_storage_test.dart`
- [X] **FR-005** — Missing/empty key makes web tools absent (same as toggle off); enabling toggle without a key surfaces an actionable prompt. `test/unit/features/tool_gating_test.dart`

### Double Gating — Toggle + Capability

- [X] **FR-006** — Web tools declared only when (a) `capabilities.functionCalling` true AND (b) valid key stored AND (c) effective toggle resolves ON; absent (not refused) otherwise. `test/unit/features/tool_gating_test.dart`
- [X] **FR-007** — Per-conversation toggle is THREE-STATE (inherit-global / explicitly-on / explicitly-off); precedence: per-convo explicit value overrides global in both directions; NULL inherits global. `test/unit/domain/web_access_override_test.dart`
- [X] **FR-008** — Per-conversation quick toggle accessible from composer; initial state inherits global default; state persists in conversation row across restarts. `test/unit/features/chat_controller_web_toggle_test.dart`
- [X] **FR-009** — Toggling web access off while in a conversation makes tools absent at the next model-call boundary; no retroactive revocation of in-progress turns. `test/unit/features/chat_controller_web_toggle_test.dart`

### Tool Surface — web_search

- [X] **FR-010** — `web_search(query)` calls Tavily Search API (top 3 results); result schema uses `content` field name (not "snippet"); results limited to 3 before constructing tool result. `test/unit/domain/web_search_handler_test.dart`
- [X] **FR-011** — Combined `web_search` tool result fits within ≤ ~305 tokens (~1,220 chars); content-length guards applied before returning. `test/unit/domain/web_search_handler_test.dart`
- [X] **FR-012** — Every `web_search` call renders a `WEB_SEARCH · Tavily` chip with query string and running/success/error states; chip names recipient "Tavily". `test/unit/features/tool_chip_web_test.dart`
- [X] **FR-013** — Successful `web_search` produces ≥ 1 tappable source URL chip per result; tapping opens URL in default browser. `test/unit/features/source_chip_test.dart`

### Tool Surface — fetch_page

- [X] **FR-014** — `fetch_page(url)` fetches and extracts readable text; internal extraction limit ~4,000 tokens; tool-result hard-truncated to ≤ 2,000 chars via `ToolSpec.resultCharBound` with `[truncated: N items remaining]` marker. `test/unit/domain/fetch_page_handler_test.dart`
- [X] **FR-015** — `fetch_page` validates url arg; non-HTTP(S) schemes, empty/malformed URLs produce a validation error chip without network call. `test/unit/domain/fetch_page_handler_test.dart`
- [X] **FR-016** — Every `fetch_page` call renders a `FETCH_PAGE · [domain]` chip (hostname of target); running/success/error states; chip names target website NOT "Tavily". `test/unit/features/tool_chip_web_test.dart`
- [X] **FR-017** — Successful `fetch_page` produces a tappable source URL chip for the fetched page beneath the model's answer. `test/unit/features/source_chip_test.dart`

### Network Service Seam

- [X] **FR-018** — ALL HTTP/search/extraction logic owned by `NetworkResearchService` seam in `lib/infrastructure/network/`; no widget/provider/domain class makes network calls directly. `tool/check_network_seam.sh` (static seam audit)
- [X] **FR-019** — Network service surfaces typed errors: `OfflineError`, `KeyInvalidError`, `RateLimitError`, `ProviderError`, `FetchDomainError`, `TimeoutError`, `ExtractionError`/`ParseError`; each maps to a distinct plain-language message in the error chip. `test/unit/infrastructure/network_research_service_test.dart`

### Offline Degradation

- [X] **FR-020** — No connectivity → `OfflineError` immediately (no retry); model prompted to answer from own knowledge; no crash/hang/retry loop. `test/unit/infrastructure/network_research_service_test.dart`
- [X] **FR-021** — With web access off (any combination), app is byte-for-byte identical to pre-006 behavior; no new network calls or UI elements. `test/unit/features/tool_gating_test.dart`

### Visible Indication (Constitution Principle I)

- [X] **FR-022** — Every web tool call renders a chip naming the TRUE external recipient before/at network call time; `web_search` chips name "Tavily"; `fetch_page` chips name target hostname; no silent web egress. `test/unit/features/tool_chip_web_test.dart`
- [X] **FR-023** — Running chip visible before request completes (optimistic render). `test/unit/features/tool_chip_web_test.dart`

### Persistence (Decision 4)

- [X] **FR-024** — Tool calls persisted using 004 `role='tool'` schema (`tool_name`, `tool_args`, `tool_status`, `tool_result`); full Tavily `content` bodies and extracted page text NOT persisted. `test/data/migration_v5_to_v6_test.dart`, `test/unit/features/web_tool_persistence_test.dart`
- [X] **FR-025** — Source URL chips persisted and render correctly on history load with tappable links; rendering is independent of current toggle state or key availability. `test/unit/features/web_tool_persistence_test.dart`

### LeakFilter and Failure Handling

- [X] **FR-026** — 004 LeakFilter applied to `web_search` and `fetch_page`; raw tool-call JSON never renders as text in the chat stream. `test/unit/features/leak_filter_web_test.dart`
- [X] **FR-027** — Invalid tool call (bad args, validation failure, handler exception) → red error chip with plain-language reason + honest text reply; no crash. `test/unit/features/chat_controller_tool_test.dart`
- [X] **FR-028** — Second tool call within a single user turn → chip-and-skip behavior (chip rendered, not executed); consistent with 004 one-round-trip contract. `test/unit/features/chat_controller_tool_test.dart`

### Design System

- [X] **FR-029** — All new UI uses centralized design tokens (no hardcoded colors/fonts); error states use #D71921; microcopy lowercase; interactive elements meet 48dp touch-target and WCAG AA contrast. `test/unit/features/tool_chip_web_test.dart` (token assertions)

### Drift Schema Migration

- [X] **FR-030** — Drift migration v5→v6 adds nullable `webAccessOverride` column (TEXT, default NULL) to conversations table and `webAccessEnabled` boolean (default false) to app_settings table; additive/idempotent; all prior migration seeds updated; `migration_v5_to_v6_test.dart` verifies defaults. `test/data/migration_v5_to_v6_test.dart`

### Query-Length Guard

- [X] **FR-031** — `web_search` rejects empty, whitespace-only, or >400-char queries before any network call; produces red error chip with plain-language reason; Tavily API not contacted. `test/unit/domain/web_search_handler_test.dart`

### Mid-Conversation Toggle Change — Session Recreation

- [X] **FR-032** — Changing per-conversation web toggle on an already-open session closes and recreates the LiteRT-LM chat session before the next tool call; no user data lost; history replayed into new session. `test/unit/features/chat_controller_web_toggle_test.dart`

### web_search Zero-Results Handling

- [X] **FR-033** — `web_search` returning 0 results renders a success chip indicating "0 results"; tool result payload contains empty array with "no results found" message; no crash/error chip; no source URL chips. `test/unit/domain/web_search_handler_test.dart`

### Error Taxonomy — fetch_page Target-Site Errors

- [X] **FR-034** — `FetchDomainError` distinct from `ProviderError`; full taxonomy (`OfflineError`, `ProviderError` + subtypes, `FetchDomainError`, `ParseError`, `TimeoutError`) present in `NetworkResearchService`; each maps to distinct user-visible message clearly distinguishing Tavily failures from target-website failures. `test/unit/infrastructure/network_research_service_test.dart`

---

## Success Criteria

- [ ] **SC-001** — ≥ 75% correct `web_search` tool selection on ≥ 20-prompt research-worthy harness; zero crashes. (device — TODO: A34 20-prompt harness run, task T060)
- [ ] **SC-002** — E2E latency (send → final answer rendered) for `web_search` + answer turn measured on A34; threshold TBD after harness run. (device — TODO: A34 latency measurement, task T061)
- [ ] **SC-003** — Zero spurious `web_search`/`fetch_page` calls on ≥ 5 junk/no-research prompts (arithmetic, chitchat, in-context). (device — TODO: A34 spurious-call check, task T060)
- [ ] **SC-004** — Airplane mode: 100% of web tool call attempts produce red offline error chip; zero network calls observed; no crash. (device — TODO: offline trial on A34, task T062)
- [X] **SC-005** — Invalid Tavily key: 100% of calls produce red key-invalid chip; no partial result used. `test/unit/infrastructure/network_research_service_test.dart` (KeyInvalidError path)
- [X] **SC-006** — `web_search` tool result ≤ ~1,220 chars (≤ ~305 tok) 100% of calls; `fetch_page` tool result ≤ 2,000 chars 100% of calls; verified by handler content-length guards. `test/unit/domain/web_search_handler_test.dart`, `test/unit/domain/fetch_page_handler_test.dart`
- [X] **SC-007** — 100% of completed `web_search`/`fetch_page` calls produce ≥ 1 tappable source URL chip. `test/unit/features/source_chip_test.dart`
- [X] **SC-008** — After close/reopen: 100% of web tool chips and source URL chips render with correct query/url and status; no full snippet body in persisted DB rows. `test/unit/features/web_tool_persistence_test.dart`
- [X] **SC-009** — Function calling off: zero web tool declarations made; zero web chips appear; no behavioral regression. `test/unit/features/tool_gating_test.dart`
- [X] **SC-010** — Both toggles off: zero web tool declarations and zero network calls across any prompt type. `test/unit/features/tool_gating_test.dart`
- [X] **SC-011** — After clearing API key: zero web tool declarations; zero network calls; global toggle returns off. `test/unit/domain/key_storage_test.dart`
- [X] **SC-012** — Raw tool-call JSON never appears in rendered text stream for any web tool call; LeakFilter verified 100% of trials. `test/unit/features/leak_filter_web_test.dart`
- [ ] **SC-013** — Every new interactive element passes 48dp touch-target and WCAG AA contrast audit before release. (device — TODO: Accessibility Scanner run on A34, task T062)
- [X] **SC-014** — Code/network audit confirms ALL network calls go through `NetworkResearchService` seam; `check_network_seam.sh` stays green. `tool/check_network_seam.sh`
- [X] **SC-015** — Code/network audit confirms Tavily API key never written to SQLite DB, any log file, or crash-reporting path. `test/unit/domain/key_storage_test.dart`

---

## Constitution / Seam Compliance

- [X] **Principle I (Opt-in, named recipient, visible egress)** — FR-001 (default off), FR-002 (microcopy), FR-022 (chip names recipient), FR-023 (optimistic chip). Covered by `tool_gating_test.dart`, `tool_chip_web_test.dart`.
- [X] **Principle II (Offline-first degradation)** — FR-020 (OfflineError, no retry), FR-021 (web-off path unchanged). Covered by `network_research_service_test.dart`.
- [X] **Principle VI (Accessibility floors)** — FR-029 (48dp touch-target, WCAG AA, design tokens). Static token assertions in `tool_chip_web_test.dart`; full Accessibility Scanner audit deferred to device (SC-013).
- [X] **Principle VII (Single seam for I/O)** — FR-018 (NetworkResearchService owns all HTTP); enforced by `check_network_seam.sh` static audit (SC-014).
- [X] **Principle IX (Android-only scope)** — No non-Android platform targets introduced; EncryptedSharedPreferences is Android-only API.
- [X] **004 capability-seam StateError guard pattern** — FR-006 uses same structural-absent-not-refused pattern as 004/005. Covered by `tool_gating_test.dart`.
- [X] **004 one-round-trip-per-turn contract** — FR-028 (chip-and-skip for second tool call in same turn). Covered by `chat_controller_tool_test.dart`.
- [X] **005 session-recreation pattern** — FR-032 (toggle change recreates live LiteRT-LM session). Covered by `chat_controller_web_toggle_test.dart`.
- [X] **004/005 persistence pattern** — FR-024/FR-025 (role='tool' rows, history-outlives-capability rendering). Covered by `web_tool_persistence_test.dart`.
- [X] **Drift migration house rule (test-seed gotcha)** — FR-030 requires all prior v*_test seeds that touch conversation/app_settings tables updated with new columns and bumped schemaVersion asserts. Covered by `migration_v5_to_v6_test.dart` and updated prior seed files.

---

*Last updated: 2026-06-13. Device-pending items map to tasks T060 (harness run SC-001/SC-003), T061 (latency SC-002), T062 (offline/accessibility SC-004/SC-013).*
