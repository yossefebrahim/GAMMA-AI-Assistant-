import 'package:ai_assistant/domain/entities/fetch_result.dart';
import 'package:ai_assistant/domain/entities/web_search_result.dart';
import 'package:ai_assistant/domain/services/network_research_service.dart';
import 'package:ai_assistant/infrastructure/network/research_errors.dart';

/// In-memory [NetworkResearchService] test double (006, contracts/network_research_service.md).
///
/// Supports configurable response stubs and error stubs, and records call logs for assertions.
/// Does NOT import `package:http` or any real network code — pure Dart (Principle VII).
class FakeNetworkResearchService implements NetworkResearchService {
  // ── Search stubs ────────────────────────────────────────────────────────────

  final Map<String, List<WebSearchResult>> _searchResults = {};
  final Map<String, ResearchError> _searchErrors = {};

  // ── Fetch stubs ─────────────────────────────────────────────────────────────

  final Map<String, FetchResult> _fetchResults = {};
  final Map<String, ResearchError> _fetchErrors = {};

  // ── Call logs ───────────────────────────────────────────────────────────────

  /// All queries passed to [search], in order.
  final List<String> searchCallLog = [];

  /// All URLs passed to [fetchPage], in order.
  final List<String> fetchCallLog = [];

  // ── Stub configuration ───────────────────────────────────────────────────────

  /// Configure [search] to return [result] when called with [query].
  void stubSearch(String query, List<WebSearchResult> result) {
    _searchResults[query] = result;
    _searchErrors.remove(query);
  }

  /// Configure [search] to throw [error] when called with [query].
  void stubSearchError(String query, ResearchError error) {
    _searchErrors[query] = error;
    _searchResults.remove(query);
  }

  /// Configure [fetchPage] to return [result] when called with [url].
  void stubFetch(String url, FetchResult result) {
    _fetchResults[url] = result;
    _fetchErrors.remove(url);
  }

  /// Configure [fetchPage] to throw [error] when called with [url].
  void stubFetchError(String url, ResearchError error) {
    _fetchErrors[url] = error;
    _fetchResults.remove(url);
  }

  /// Reset all stubs and call logs.
  void reset() {
    _searchResults.clear();
    _searchErrors.clear();
    _fetchResults.clear();
    _fetchErrors.clear();
    searchCallLog.clear();
    fetchCallLog.clear();
  }

  // ── Interface implementation ─────────────────────────────────────────────────

  @override
  Future<List<WebSearchResult>> search(String query) async {
    searchCallLog.add(query);
    final error = _searchErrors[query];
    if (error != null) throw error;
    final result = _searchResults[query];
    if (result != null) return result;
    // Default: no stub configured — return empty results.
    return const [];
  }

  @override
  Future<FetchResult> fetchPage(String url) async {
    fetchCallLog.add(url);
    final error = _fetchErrors[url];
    if (error != null) throw error;
    final result = _fetchResults[url];
    if (result != null) return result;
    // Default: no stub configured — return an empty extraction.
    return FetchResult(url: url, extractedText: '', wasTruncated: false);
  }
}
