import 'package:ai_assistant/domain/entities/fetch_result.dart';
import 'package:ai_assistant/domain/entities/web_search_result.dart';

/// Plugin-free interface for web research operations (006, contracts/network_research_service.md,
/// Principle VII). The sole concrete implementation, `TavilyNetworkResearchService`, lives in
/// `lib/infrastructure/network/tavily_network_research_service.dart` and is the ONLY file in the
/// codebase permitted to import `package:http` or read from [SecureKeyStore].
///
/// No widget, Riverpod provider, domain class, controller, or handler may import `package:http`,
/// `dart:io` sockets, or any HTTP-adjacent package directly. ALL network I/O for this feature
/// crosses this seam — there is no second network access path (SC-014 code-audit guarantee).
abstract interface class NetworkResearchService {
  /// Search via Tavily Search API (POST https://api.tavily.com/search).
  ///
  /// [query] must be non-empty and ≤ 400 chars (validated upstream; the seam trusts validated
  /// input but still guards defensively). Returns ≤ 3 results ordered by Tavily score descending.
  /// Throws a [ResearchError] subtype on any failure — never returns null.
  Future<List<WebSearchResult>> search(String query);

  /// Fetch and extract readable text from [url] (direct HTTP GET to the target site — NOT via
  /// Tavily).
  ///
  /// [url] must be a well-formed http:// or https:// URL (validated upstream). Returns extracted
  /// text hard-bounded at kFetchResultCharBound chars (≤ 2,000); appends
  /// '[truncated: N items remaining]' when truncated. Throws a [ResearchError] subtype on any
  /// failure — never returns null.
  Future<FetchResult> fetchPage(String url);
}
