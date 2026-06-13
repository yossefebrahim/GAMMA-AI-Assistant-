# Data Model — 006 Web Research

## 1. Domain entities

### WebSearchResult (transient — in-memory only, never persisted)

Produced by `NetworkResearchService.search()` and consumed by the `web_search` tool handler.
Discarded after the tool result JSON is assembled and bounded.

| Field | Type | Notes |
|---|---|---|
| `title` | `String` | Page title as returned by Tavily |
| `url` | `String` | Canonical URL of the result |
| `content` | `String` | Pre-extracted clean text snippet from Tavily's `content` field (R4). NOT renamed to "snippet" — FR-010 prohibition |
| `score` | `double` | Tavily relevance score (0–1) |

This entity is `lib/domain/entities/web_search_result.dart`. It is a plain Dart value object —
no drift annotations, no JSON key mapping beyond the Tavily field names.

### FetchResult (transient — in-memory only, never persisted)

Produced by `NetworkResearchService.fetchPage()` and consumed by the `fetch_page` tool handler.
Discarded after the tool result JSON is assembled and bounded.

| Field | Type | Notes |
|---|---|---|
| `url` | `String` | The final URL after any HTTP redirects |
| `extractedText` | `String` | Cleaned body text from `HtmlExtractor`; may be up to ~4,000 tokens internally before the `resultCharBound = 2000` truncation is applied at the handler |
| `wasTruncated` | `bool` | True when `extractedText` was clipped to fit the bound — field name matches `contracts/network_research_service.md` |

`domain` is NOT a field on this type — it is derived at chip-render time via `Uri.parse(url).host`
(e.g. `en.wikipedia.org`). This entity is `lib/domain/entities/fetch_result.dart`. Like
`WebSearchResult`, it is a plain value object.

### WebAccessOverride (new enum — `lib/domain/entities/web_access_override.dart`)

Three-state per-conversation web toggle (FR-007). Persisted as `conversations.web_access_override`
(TEXT or NULL — see §2). The NULL representation IS the `inherit` state; the enum name is never
persisted for `inherit`.

```dart
enum WebAccessOverride {
  inherit,    // NULL in DB — use app-level webAccessEnabled (the default)
  on,         // 'on' in DB — force web tools on for this conversation
  off,        // 'off' in DB — force web tools off for this conversation
}
```

`effectiveWebEnabled(globalEnabled)`:
- `inherit` → `globalEnabled`
- `on` → `true`
- `off` → `false`

### web_search / fetch_page ToolSpecs (added to `ToolRegistry.webTools`)

| Tool | Args schema | Kind | Handler |
|---|---|---|---|
| `web_search` | `{query: string (required, maxLength 400)}` | `stateChanging` | `NetworkResearchService.search` → top 3 results |
| `fetch_page` | `{url: string (required)}` | `stateChanging` | `NetworkResearchService.fetchPage` → extracted text |

Both are `stateChanging` — they perform network egress (a consequential external action), consistent with the codebase convention that `stateChanging` marks egress intent, not app-state mutation. `readOnly` is reserved for pure on-device reads (e.g. `get_device_info`). `ToolRegistry` adds a
`webTools` list (006) alongside the existing `deviceTools` (004) and `memoryTools` (005). The
session provider composes the declared list as:

```
deviceTools (if functionCalling)
+ memoryTools (if functionCalling && memoryEnabled)
+ webTools    (if functionCalling && effectiveWebEnabled && hasValidKey)
```

Triple-gate (R6): all three conditions must hold for web tools to appear in the `createConversation`
call. `effectiveWebEnabled` resolves the three-state override (§1 above). `hasValidKey` reads the
`SecureKeyStore` — a missing or blank key causes web tools to be absent, not errored. Toggling
`webAccessOverride` on an open conversation recreates the LiteRT-LM session (same `startSession`
pattern as 005, R6).

`resultCharBound` for both tools: `2000` (the existing `ToolSpec.defaultResultCharBound`). The
`fetch_page` handler may perform internal extraction up to ~4,000 tokens, then truncates the
`FetchResult.extractedText` to fit the bound before serialising.

### App settings (existing — extended)

`AppSettings` gains `webAccessEnabled` (`bool`, default **false** — the global web access toggle,
off by default per Decision 1 / SC-001). Persisted in the single-row `app_settings` table (§2
below). Read/written like `memoryEnabled`.

### SecureKeyStore (NOT a drift table — encrypted KV, new seam)

The Tavily API key is stored in `flutter_secure_storage` under the key `'tavily_api_key'`, NOT in
SQLite. This is a deliberate architectural separation:

**Why it is NOT in drift**: the Tavily key is a user secret (FR-003 / SC-015). Drift/SQLite
stores data in app-private storage, which on FBE devices is credential-encrypted by the OS, but
the raw bytes are directly accessible to adb backups, debug builds, and any code that can open
the DB file. `flutter_secure_storage` uses Android Keystore-backed AES/GCM encryption (R3): the
AES key is stored inside the hardware-backed Keystore and is never exported, so the ciphertext in
`SharedPreferences` cannot be decrypted even with direct filesystem access. This aligns with
FR-003 ("provider key encrypted at rest, separate from DB") and spec Decision 1.

**Why it is not in `app_settings`**: leaking the key into any SQL column, log line, or snapshot
would violate the provider-key confidentiality requirement. The drift DB is visible in
`flutter drive` logs and migration test seeds. Keeping the key entirely out of drift eliminates
that surface.

**Interface seam** (`lib/domain/services/secure_key_store.dart`):
```dart
abstract interface class SecureKeyStore {
  Future<String?> readTavilyKey();
  Future<void> writeTavilyKey(String key);
  Future<void> clearTavilyKey();
  Future<bool> hasValidKey();
}
```
Concrete implementation: `lib/infrastructure/network/flutter_secure_key_store.dart`. The package
`flutter_secure_storage` is imported ONLY in that implementation file (Principle VII guard — same
pattern as `flutter_gemma` behind `GemmaService`). The settings widget reads/writes the key via
the injected `SecureKeyStore` interface.

Constant key name: `'tavily_api_key'` (defined in `lib/infrastructure/network/`; the settings
screen never hard-codes the string).

## 2. Database schema — drift v5 → v6 (additive only, house style)

Two new columns — one on `conversations`, one on `app_settings`. No new tables.

```sql
-- conversations: per-conversation web-access override (three-state, FR-007)
ALTER TABLE conversations ADD COLUMN web_access_override TEXT NULL;
-- NULL = inherit global default; 'on' = force on; 'off' = force off.
-- Existing rows stay NULL (inherit), which is the correct default.

-- app_settings: global web-access toggle (default off — SC-001, Decision 1)
ALTER TABLE app_settings_table ADD COLUMN web_access_enabled INTEGER NOT NULL DEFAULT 0;
-- Bool; 0=false. The existing single row defaults to 0 (off).
```

- v5 rows are untouched. The `conversations` rows all stay `NULL`; the `app_settings` single
  row gets `web_access_enabled = 0` by default. Fresh installs land on v6 via `onCreate`.
- No `@TableIndex` for `web_access_override` — queries filter by conversation id, not override
  state; no index needed.
- The `web_access_override` column stores the enum name (`'on'` / `'off'`) or SQL NULL for
  `WebAccessOverride.inherit`. The domain layer coerces: `null → inherit`, `'on' → on`,
  `'off' → off`; any other value is treated as `inherit` (defensive).

### Drift Dart table changes

In `lib/data/db/tables.dart`:

**`Conversations` table** gains:

```dart
/// Per-conversation web-access override (006, schema v6). NULL = inherit the global
/// `webAccessEnabled` setting; 'on' / 'off' force web tools on or off for this conversation
/// (FR-007, three-state, data-model §1). Added by the v5→v6 migration as nullable, so existing
/// rows stay valid with NULL (= inherit).
TextColumn get webAccessOverride => text().nullable()();
```

**`AppSettingsTable`** gains:

```dart
/// Whether web research tools are globally enabled (006, schema v6). Default **false** (off by
/// default — SC-001, Decision 1); individual conversations may override via
/// [Conversations.webAccessOverride]. Added by the v5→v6 migration with DEFAULT 0 so the
/// existing single row stays valid (data-model §2).
BoolColumn get webAccessEnabled =>
    boolean().withDefault(const Constant(false))();
```

### Migration block (`app_database.dart`)

```dart
// v5 → v6 (006): add web_access_override to conversations and web_access_enabled to
// app_settings (additive only; v5 rows untouched — data-model §2). Existing conversations
// default to NULL (= inherit global), existing app_settings row defaults to false (web off).
// Fresh installs land on v6 directly via onCreate.
if (from < 6) {
  await m.addColumn(conversations, conversations.webAccessOverride);
  await m.addColumn(appSettingsTable, appSettingsTable.webAccessEnabled);
}
```

`schemaVersion` in `AppDatabase` bumps from `5` to `6`.

## 3. Tool-call persistence — reuse of 004 role='tool' columns

The `web_search` and `fetch_page` tool calls flow through the EXISTING 004 controller tool-turn
state machine and persist as `role='tool'` message rows in the `messages` table. No new columns
are added. The four 004 columns carry the following per-tool:

### `web_search` tool row

| Column | What it holds |
|---|---|
| `tool_name` | `'web_search'` |
| `tool_args` | `{"query":"<the query string>"}` |
| `tool_status` | `'success'` / `'error'` / `'running'` (transient) / `'skipped'` |
| `tool_result` | On success: compact JSON `{"results":[{"title":"…","url":"…"},…],"sourceUrls":["url1","url2","url3"]}`. The `sourceUrls` array is the answer-grounding reference (Decision 4 / FR-024). **Only `{title, url}` metadata per result is persisted — the Tavily `content` snippet body is computed transiently and passed to the model in-session, but is NEVER written to the DB** (Decision 4). On error: `{"error":"<reason>"}`. |

### `fetch_page` tool row

| Column | What it holds |
|---|---|
| `tool_name` | `'fetch_page'` |
| `tool_args` | `{"url":"<the target URL>"}` |
| `tool_status` | `'success'` / `'error'` / `'running'` / `'skipped'` |
| `tool_result` | On success: `{"url":"<final url after redirects>","truncated":false,"sourceUrls":["<url>"]}`. The `sourceUrls` array always contains exactly the one fetched URL (answer-grounding reference, Decision 4). **The extracted body text (`extractedText`) is computed transiently and passed to the model in-session, but is NEVER written to the DB — only the final URL, truncation flag, and source URL are persisted** (Decision 4). On error: `{"error":"<reason>","domain":"<hostname if known>"}`. |

**Decision 4 note (no body text persistence)**: the `tool_result` column holds metadata,
answer-grounding source URLs, and the bounded content snippet/extracted text used for the model's
reply — it does NOT persist the raw HTML or full page body. Reasons: (a) the extracted text
already fits the reply; (b) raw HTML is large and of no historical value; (c) source URLs give
the user traceability without a DB bloat risk. The `resultCharBound = 2000` ceiling is enforced
at the handler level by the existing `ToolDispatcher` truncation path (same mechanism as 004/005).

### Error rows

On any `ResearchError` (see §4), the dispatcher maps the error to `ToolFailure(reason)`, which
persists as `tool_status = 'error'`, `tool_result = '{"error":"<lowercase reason>"}'`. The chip
renders this as the existing error-chip style (sanctioned red). The reason string is user-visible
and must not include the raw API key, stack traces, or internal HTTP headers.

### Chip rendering (reuse of 004 `ToolChip`)

| Outcome | Chip |
|---|---|
| `web_search` success | `TOOL · WEB_SEARCH` + `3 results for "<query>"` |
| `fetch_page` success | `TOOL · FETCH_PAGE` + `fetched <domain>` |
| `web_search` error (offline) | error chip + `"no network — try again when online"` |
| `fetch_page` error (domain) | error chip + `"could not reach <domain>"` |
| Key invalid / rate limit | error chip + `"tavily key invalid"` / `"tavily limit reached"` |
| Timeout | error chip + `"request timed out"` |

Web tool chips render in reopened history regardless of whether web tools are currently enabled,
identically to 004/005 tool chips (FR-019).

## 4. Error taxonomy (`lib/infrastructure/network/research_errors.dart`)

Sealed class hierarchy; thrown by `NetworkResearchService` methods, caught by tool handlers, and
mapped to `ToolFailure(reason)` by the dispatcher:

```dart
sealed class ResearchError implements Exception {}

/// No network route to host (SocketException ENETUNREACH / EHOSTUNREACH, or pre-flight
/// InternetAddress.lookup failure). Maps to chip: "no network".
final class OfflineError extends ResearchError {}

/// Provider-side failure — subclasses distinguish cause for chip wording.
/// Any other Tavily 4xx/5xx not covered by the subtypes is represented by
/// the base ProviderError directly (no separate HttpError subclass).
class ProviderError extends ResearchError {
  final int httpStatusCode;
  final String? responseBody;
}

/// HTTP 401 / 403 — key missing, invalid, or revoked (R4).
final class KeyInvalidError extends ProviderError {}

/// HTTP 429 / 432 / 433 — rate or plan limit exceeded (R4).
final class RateLimitError extends ProviderError {}

/// SocketException on the target site only (fetch_page); Tavily is reachable (OfflineError
/// would have fired first if the general network was absent).
final class FetchDomainError extends ResearchError {
  const FetchDomainError(this.domain);
  final String domain;
}

/// HTML parsing succeeded structurally but yielded no usable content (all candidate nodes empty
/// after boilerplate stripping). Returned as a ToolFailure, not a hard error.
final class ParseError extends ResearchError {}

/// Future.timeout() fired before the HTTP response completed. kTavilyTimeoutMs = 10000,
/// kFetchTimeoutMs = 15000 (R1).
final class TimeoutError extends ResearchError {}
```

## 5. Migration test obligation (`test/data/migration_v5_to_v6_test.dart`)

### New test file

`migration_v5_to_v6_test.dart` seeds a real **v5 file DB** with raw SQL at `user_version = 5`
(matching the schema drift actually created at v5: conversations + messages + model_installs +
app_settings WITH `memory_enabled` + memories table + both indexes). It then opens the DB via
`AppDatabase(NativeDatabase(dbFile))`, which triggers `onUpgrade(5, 6)`.

Required assertions:

1. `conversations` rows survive with `web_access_override = null` (existing rows default to inherit).
2. `app_settings` row survives with `web_access_enabled = false` (existing row defaults to off).
3. `memories` rows survive untouched (unrelated table, must not be disturbed).
4. A new conversation row with `web_access_override = 'on'` round-trips correctly.
5. A `web_access_override = null` row round-trips as `null` (the `inherit` case).
6. Setting `web_access_enabled = true` on the `app_settings` row persists and reads back.
7. `db.schemaVersion` equals `6`.

### Seed-gotcha: update ALL prior migration test seeds

**House rule** (project memory `drift-migration-test-seed-gotcha`): any prior `migration_v*_test`
seed that touches `conversations` or `app_settings_table` must be updated to include the two new
v6 columns with their defaults, AND its `schemaVersion` assert must be bumped from 5 to 6.

Affected files and required changes:

| File | Table(s) touched | Change required |
|---|---|---|
| `test/data/migration_v4_to_v5_test.dart` | `conversations`, `app_settings_table` | Add `web_access_override TEXT NULL` to the `conversations` CREATE in `seedV4()`; add `web_access_enabled INTEGER NOT NULL DEFAULT 0` to the `app_settings_table` CREATE; bump `schemaVersion` expect from `5` to `6` |
| `test/data/migration_v3_to_v4_test.dart` | `conversations`, `app_settings_table` | Same additions to `seedV3()`; bump `schemaVersion` assert |
| `test/data/migration_v2_to_v3_test.dart` | `conversations`, `app_settings_table` | Same additions to `seedV2()`; bump `schemaVersion` assert |
| `test/data/migration_v1_to_v2_test.dart` | `conversations`, `app_settings_table` | Same additions to `seedV1()`; bump `schemaVersion` assert |

The seed represents the schema as drift ACTUALLY creates it at the seed's version — including
columns added by LATER migrations, because drift's `onCreate` path creates the FULL CURRENT schema
on a fresh install. The seed must mirror what a device at that schema version would actually have.

**No `@TableIndex` for `web_access_override`** — so no `m.createIndex` call is needed in the v6
migration block and no index-existence assertion is needed in the migration test (contrast with
the v4→v5 `idx_memories_active` index, which required an explicit `m.createIndex(idxMemoriesActive)`
and a corresponding `SELECT name FROM sqlite_master WHERE type='index'` assertion).

## 6. Providers (Riverpod) — additive

- `secureKeyStoreProvider` — `Provider<SecureKeyStore>`; implementation is
  `FlutterSecureKeyStore`; overridden with a stub in tests (no real `flutter_secure_storage`
  calls in unit/widget tests).
- `networkResearchServiceProvider` — `Provider<NetworkResearchService>`; implementation is
  `TavilyNetworkResearchService`; overridden with a fake in tests.
- `webAccessEnabledProvider` — `Notifier<bool>` over `app_settings.webAccessEnabled`, like
  `memoryEnabledProvider`.
- `conversationWebOverrideProvider(conversationId)` — family provider that reads/writes
  `conversations.webAccessOverride` for a specific conversation; drives the per-conversation
  toggle in the chat toolbar.
- `toolHandlersProvider` (existing) gains `web_search` and `fetch_page` handlers bound to the
  `NetworkResearchService`.
- The session provider composes `declaredTools` as described in §1 (triple gate) and passes
  them to `loadModel`/`startSession`. Toggling `webAccessOverride` calls `startSession` (no
  model reload — identical to 005 memory-toggle pattern).

## 7. Context budget accounting (R9)

The two new tool declarations add ~80 tokens. The `ContextAssembler` gains
`webToolsReserveTokens = 80` added to the existing reserves when web tools are declared:

| Slot | Tokens |
|---|---|
| Output reserve | 512 |
| 004 device tool instruction | ~40 |
| 005 memory block (max 20 facts) | ~174 |
| 005 memory capture instruction | ~86 |
| 006 web tool declarations | ~80 |
| **Remaining for chat history + turn** | **~1,156** |

A `web_search` result (3 results × ~300 chars content, serialized JSON) costs ~305 tokens; a
`fetch_page` result (≤ 2,000 chars) costs ~500 tokens. Both fit within the 1,156-token remainder.
The `resultCharBound = 2000` ceiling enforced by `ToolDispatcher` is the hard guard for both tools.
