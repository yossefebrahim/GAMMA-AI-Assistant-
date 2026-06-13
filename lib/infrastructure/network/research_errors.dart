/// Sealed error hierarchy for [NetworkResearchService] (006, data-model §4, FR-019, FR-034).
///
/// All errors are sealed subtypes of [ResearchError]. The seam THROWS; the tool handler CATCHES
/// and maps to a plain-language red chip message. `FetchDomainError` is ALWAYS from the target
/// website path; `ProviderError` and its subtypes are ALWAYS from the Tavily API path — these two
/// roots must NEVER be conflated (Constitution v2.0.0 Principle I).
sealed class ResearchError implements Exception {
  const ResearchError();
}

/// No network connectivity detected at pre-flight or at the socket level
/// (SocketException ENETUNREACH / EHOSTUNREACH / ENOTCONN on either call type).
///
/// Plain-language chip: "offline — no connection"
final class OfflineError extends ResearchError {
  const OfflineError();

  @override
  String toString() => 'offline — no connection';
}

/// Root for all Tavily-side API failures (web_search path only). Any Tavily 4xx/5xx not covered
/// by the subtypes ([KeyInvalidError], [RateLimitError]) is represented by the base [ProviderError]
/// directly.
///
/// Plain-language chip: varies by subtype.
class ProviderError extends ResearchError {
  const ProviderError({required this.httpStatusCode, this.responseBody});

  /// The HTTP status code returned by the Tavily API.
  final int httpStatusCode;

  /// The raw response body from Tavily, if available; `null` on transport-level failures.
  final String? responseBody;

  @override
  String toString() => 'provider error (HTTP $httpStatusCode)';
}

/// HTTP 401 or 403 from Tavily — key missing, invalid, or revoked.
///
/// Plain-language chip: "tavily key invalid — check Settings"
final class KeyInvalidError extends ProviderError {
  const KeyInvalidError({required super.httpStatusCode, super.responseBody});

  @override
  String toString() => 'tavily key invalid — check Settings';
}

/// HTTP 429, 432, or 433 from Tavily — per-month or pay-as-you-go limit hit.
///
/// Plain-language chip: "tavily limit reached — check your plan"
final class RateLimitError extends ProviderError {
  const RateLimitError({required super.httpStatusCode, super.responseBody});

  @override
  String toString() => 'tavily limit reached — check your plan';
}

/// DNS/TCP/TLS failure or non-2xx HTTP response from the TARGET WEBSITE during `fetch_page`
/// (direct GET — not a Tavily failure). [ProviderError] is for Tavily; this is for the target site.
///
/// Plain-language chip: "could not reach [domain] — check the URL or try later"
final class FetchDomainError extends ResearchError {
  const FetchDomainError({required this.domain, this.httpStatusCode});

  /// The hostname of the target site that could not be reached (e.g. `flutter.dev`).
  final String domain;

  /// The HTTP status code from the target site, if available; `null` for DNS/TLS/TCP failures.
  final int? httpStatusCode;

  @override
  String toString() => 'could not reach $domain — check the URL or try later';
}

/// Wall-clock timeout exceeded on either the Tavily POST or the target-site GET.
///
/// Plain-language chip: "request timed out — try again"
final class TimeoutError extends ResearchError {
  const TimeoutError();

  @override
  String toString() => 'request timed out — try again';
}

/// The `fetch_page` HTTP call succeeded (2xx) but the HTML extraction pipeline produced no usable
/// content (empty body, non-HTML content-type, or binary resource).
///
/// Plain-language chip: "could not extract text from page"
final class ParseError extends ResearchError {
  const ParseError({required this.reason});

  /// Human-readable reason for the parse failure
  /// (e.g. `"non-HTML content-type: application/pdf"`).
  final String reason;

  @override
  String toString() => 'could not extract text from page';
}
