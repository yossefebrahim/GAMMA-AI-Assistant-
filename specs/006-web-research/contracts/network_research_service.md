# Contract — NetworkResearchService (006)

Plugin-free interface (Principle VII). Defined in
`lib/domain/services/network_research_service.dart` (pure Dart — no `http` import). The sole
concrete implementation, `TavilyNetworkResearchService`, lives in
`lib/infrastructure/network/tavily_network_research_service.dart` and is the ONLY file in the
codebase permitted to import `package:http` or read from `SecureKeyStore`. Enforced by
`check_network_seam.sh` (FR-018, SC-014).

No widget, Riverpod provider, domain class, controller, or handler may import
`package:http`, `dart:io` sockets, or any HTTP-adjacent package directly. ALL network I/O for
this feature crosses this seam — there is no second network access path (SC-014 code-audit
guarantee).

---

## Interface

```dart
abstract interface class NetworkResearchService {
  /// Search via Tavily Search API (POST https://api.tavily.com/search).
  /// [query] must be non-empty and ≤ 400 chars (validated upstream; the seam
  /// trusts validated input but still guards defensively).
  /// Returns ≤ 3 results ordered by Tavily score descending.
  /// Throws a [ResearchError] subtype on any failure — never returns null.
  Future<List<SearchResult>> search(String query);

  /// Fetch and extract readable text from [url] (direct HTTP GET to the
  /// target site — NOT via Tavily).
  /// [url] must be a well-formed http:// or https:// URL (validated upstream).
  /// Returns extracted text hard-bounded at [kFetchResultCharBound] chars
  /// (≤ 2,000); appends '[truncated: N items remaining]' when truncated.
  /// Throws a [ResearchError] subtype on any failure — never returns null.
  Future<FetchResult> fetchPage(String url);
}
```

### Result types

```dart
/// One item from a Tavily search response. Field names match Tavily's API
/// contract exactly — 'content' is Tavily's field name and must NOT be
/// renamed to 'snippet' anywhere in the serialisation layer (FR-010).
class SearchResult {
  final String title;
  final String url;
  final String content; // Tavily 'content' field — pre-extracted clean text
  final double score;
}

/// Extracted text from a fetch_page call, ready to pass to the model.
class FetchResult {
  final String url;           // canonical URL actually fetched
  final String extractedText; // ≤ kFetchResultCharBound chars (hard-truncated)
  final bool wasTruncated;    // true iff '[truncated: N items remaining]' appended
}
```

### Timeout constants

```dart
// Defined in lib/infrastructure/network/network_constants.dart
const int kTavilyTimeoutMs   = 10_000;  // 10 s wall-clock for Tavily POST
const int kFetchTimeoutMs    = 15_000;  // 15 s wall-clock for target-site GET
const int kConnectivityTimeoutMs = 3_000; // pre-flight InternetAddress.lookup
const int kMaxExtractedTokens = 4_000;  // internal extraction pipeline ceiling
const int kFetchResultCharBound = 2_000; // authoritative tool-result bound (FR-014)
const int kMaxSearchResults  = 3;       // top-N from Tavily (FR-010)
```

---

## No-other-network-access guarantee

**Given** the `check_network_seam.sh` seam-guard script is green,
**Then** every HTTP socket opened by this feature exits through
`TavilyNetworkResearchService` — zero other files import `package:http`,
`dart:io`'s `HttpClient`, or any socket-creating library for this feature's traffic.

Specifically: `flutter_secure_storage` (Keystore reads/writes only — no network I/O),
`drift`/`sqlite3` (local SQLite only), `flutter_gemma` (LiteRT-LM FFI — no network) and all
Riverpod providers are not permitted to make outbound HTTP calls.

---

## Timeout and cancellation contract

1. **Tavily POST**: wrapped in `Future.timeout(Duration(milliseconds: kTavilyTimeoutMs))`. On
   timeout the abort trigger fires (`abortTrigger.complete()`), the `IOClient` surfaces a
   `RequestAbortedException`, and the seam throws `TimeoutError`.

2. **Target-site GET**: same pattern with `kFetchTimeoutMs`. `RequestAbortedException` → `TimeoutError`.

3. **Pre-flight connectivity probe**: `InternetAddress.lookup(hostname)` with a
   `kConnectivityTimeoutMs` ceiling. A `SocketException`/`OSError` here → `OfflineError` thrown
   BEFORE the actual HTTP call is attempted. If the pre-flight passes but the HTTP call itself
   raises `SocketException(ENETUNREACH/EHOSTUNREACH/ENOTCONN)`, the seam also throws `OfflineError`.

4. **No automatic retry**: the seam throws on the first failure. Retry logic is out of scope
   (FR-020: "no retry loop"). The caller (tool handler) does not retry; it maps the error to a
   chip.

5. **Cancellation from toggle-off**: if the toggle is turned off while a request is in flight,
   the tool handler receives the result anyway (the seam does not observe the toggle). The
   controller discards the result at the chip level before the next model turn (FR-009: "applies
   from the next user turn").

---

## Typed error taxonomy

All errors are sealed subtypes of `ResearchError`
(`lib/infrastructure/network/research_errors.dart`). The seam THROWS; the handler CATCHES and
maps to `ToolOutcome.failure` with a plain-language message for the red error chip.

```dart
sealed class ResearchError implements Exception {}

/// No network connectivity detected at pre-flight or at the socket level
/// (SocketException ENETUNREACH / EHOSTUNREACH / ENOTCONN on either call type).
/// Plain-language chip: "offline — no connection"
final class OfflineError extends ResearchError {}

/// Root for all Tavily-side API failures (web_search path only).
/// Plain-language chip: varies by subtype.
class ProviderError extends ResearchError {
  final int httpStatusCode;
  final String? responseBody;
}

/// HTTP 401 or 403 from Tavily — key missing, invalid, or revoked.
/// Plain-language chip: "tavily key invalid — check Settings"
final class KeyInvalidError extends ProviderError {}

/// HTTP 429, 432, or 433 from Tavily — per-month or pay-as-you-go limit hit.
/// Plain-language chip: "tavily limit reached — check your plan"
final class RateLimitError extends ProviderError {}

/// Any other Tavily 4xx/5xx not covered by the subtypes above (e.g. 400 bad
/// request, 500 server error). Plain-language chip: "provider error (HTTP N)"
/// FetchDomainError is NOT a ProviderError — it is a distinct sibling.
// (covered by the base ProviderError class)

/// DNS/TCP/TLS failure or non-2xx HTTP response from the TARGET WEBSITE
/// during fetch_page (direct GET — not a Tavily failure).
/// Plain-language chip: "could not reach [domain] — check the URL or try later"
final class FetchDomainError extends ResearchError {
  final String domain;
  final int? httpStatusCode; // null for DNS/TLS failure, non-null for non-2xx
}

/// Wall-clock timeout exceeded on either Tavily POST or target-site GET.
/// Plain-language chip: "request timed out — try again"
final class TimeoutError extends ResearchError {}

/// fetch_page HTTP call succeeded (2xx) but the HTML extraction pipeline
/// produced no usable content (empty body, non-HTML content-type, or
/// binary resource). Plain-language chip: "could not extract text from page"
final class ParseError extends ResearchError {
  final String reason; // e.g. "non-HTML content-type: application/pdf"
}
```

### Error routing rules

| Call site | Error type | Condition |
|---|---|---|
| `search()` | `OfflineError` | Pre-flight `InternetAddress.lookup` throws OR Tavily HTTP call raises `SocketException` with no-route errno |
| `search()` | `KeyInvalidError` | Tavily HTTP 401 or 403 |
| `search()` | `RateLimitError` | Tavily HTTP 429, 432, or 433 |
| `search()` | `ProviderError` | Any other Tavily 4xx or 5xx |
| `search()` | `TimeoutError` | `Future.timeout` fires on the Tavily POST |
| `fetchPage()` | `OfflineError` | Pre-flight throws OR `SocketException` with no-route errno on the GET |
| `fetchPage()` | `FetchDomainError` | DNS failure, TLS failure, TCP refusal, or non-2xx HTTP from target site |
| `fetchPage()` | `TimeoutError` | `Future.timeout` fires on the target-site GET |
| `fetchPage()` | `ParseError` | 2xx response but content-type not `text/html` or extraction pipeline produces empty content |

`FetchDomainError` is ALWAYS from the target website path; `ProviderError` and its subtypes are
ALWAYS from the Tavily API path. These two error roots must NEVER be conflated — they name
different recipients to the user (Constitution v2.0.0 Principle I).

---

## Guarantees (unit-testable via `FakeNetworkResearchService`)

1. **Single seam (FR-018)**: `check_network_seam.sh` verifies that `package:http` and
   `dart:io` socket APIs are imported only in `lib/infrastructure/network/`. Any import
   violation fails CI.

2. **Key never logged or persisted (FR-003, SC-015)**: the seam reads the Tavily key from
   `SecureKeyStore.readTavilyKey()` at call time and places it in the `Authorization: Bearer`
   header only. The key string never touches: `toString()`/`print()`, the `tool_result`
   column, the `tool_args` column, any Dart `Logger`, or any crash-report breadcrumb path.
   Verified by a static lint rule (custom analyzer plugin or `check_network_seam.sh` grep).

3. **Field name is `content` not `snippet` (FR-010)**: `SearchResult.content` maps directly
   from Tavily's `content` JSON field. No serialization layer renames it. The registry-sanity
   test asserts the field name in the tool's result schema description.

4. **Result count ≤ 3 (FR-010)**: `search()` passes `max_results: 3` in the Tavily request body
   AND slices the response to at most 3 items before returning. A response with more results is
   truncated at the seam.

5. **Tool-result char bound ≤ 2,000 (FR-014, SC-006)**: `fetchPage()` applies the internal
   extraction ceiling (`kMaxExtractedTokens = 4,000`) first, then hard-truncates the
   `FetchResult.extractedText` to `kFetchResultCharBound` (2,000) chars. The 2,000-char figure
   is authoritative; 1,500 chars MUST NOT be used as the bound.

6. **No retry (FR-020)**: the seam throws on first failure; there is no loop, no exponential
   backoff, no silent swallow. The error propagates immediately to the handler.

7. **StateError guard**: if `search()` or `fetchPage()` is called when no valid key is stored
   (a coding error — the gate in the session provider should have prevented this), the seam
   throws `StateError('NetworkResearchService called without a valid key')`. This mirrors the
   004/005 `StateError` capability-seam guard.

---

## Fake / test double

`FakeNetworkResearchService` (in-memory, plugin-free) for handler, dispatcher, and controller
tests:

- Configurable response stubs: `stubSearch(query, result)`, `stubSearchError(query, error)`,
  `stubFetch(url, result)`, `stubFetchError(url, error)`.
- Records calls: `searchCallLog`, `fetchCallLog` — assertable in unit tests.
- Models timeout by immediately throwing `TimeoutError` when configured.
- Does NOT import `package:http` or any real network code.
- Used to verify: triple-gate logic, error chip mapping, key-not-logged invariant (by asserting
  `SecureKeyStore.readTavilyKey()` is never called on the fake — the fake is pre-seeded with
  results, not key-dependent).
