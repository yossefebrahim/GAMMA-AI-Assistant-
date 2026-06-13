import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ai_assistant/domain/entities/fetch_result.dart';
import 'package:ai_assistant/domain/entities/web_search_result.dart';
import 'package:ai_assistant/domain/services/network_research_service.dart';
import 'package:ai_assistant/domain/services/secure_key_store.dart';
import 'package:ai_assistant/infrastructure/network/html_extractor.dart';
import 'package:ai_assistant/infrastructure/network/network_constants.dart';
import 'package:ai_assistant/infrastructure/network/research_errors.dart';
import 'package:http/http.dart' as http;

/// Concrete [NetworkResearchService] backed by the Tavily Search API + direct HTTP GET (006, T025).
///
/// This is the ONLY file in the codebase permitted to import `package:http`
/// (enforced by `check_network_seam.sh`, Principle VII). All other code interacts with web
/// research exclusively via the [NetworkResearchService] interface.
///
/// - [search]: pre-flight connectivity probe + POST to Tavily, parse `content` (not `snippet`),
///   top 3 results, full typed-error mapping.
/// - [fetchPage]: pre-flight + GET target URL directly (NOT via Tavily), feed body to
///   [HtmlExtractor], typed-error mapping.
///
/// Throws [StateError] when called without a valid Tavily key stored (programming error — the
/// triple-gate in the session provider should prevent this).
class TavilyNetworkResearchService implements NetworkResearchService {
  TavilyNetworkResearchService({
    required SecureKeyStore keyStore,
    http.Client? client,
  }) : _keyStore = keyStore,
       _client = client ?? http.Client();

  final SecureKeyStore _keyStore;
  final http.Client _client;

  static const _tavilySearchUrl = 'https://api.tavily.com/search';
  static const HtmlExtractor _extractor = HtmlExtractor();

  // ── search() ─────────────────────────────────────────────────────────────

  @override
  Future<List<WebSearchResult>> search(String query) async {
    final key = await _keyStore.readTavilyKey();
    if (key == null || key.isEmpty) {
      throw StateError('NetworkResearchService called without a valid key');
    }

    // Pre-flight connectivity probe.
    await _preflight('api.tavily.com');

    final uri = Uri.parse(_tavilySearchUrl);
    final body = jsonEncode({'query': query, 'max_results': kMaxSearchResults});

    http.Response response;
    try {
      response = await _client
          .post(
            uri,
            headers: {
              'Authorization': 'Bearer $key',
              'Content-Type': 'application/json',
            },
            body: body,
          )
          .timeout(
            const Duration(milliseconds: kTavilyTimeoutMs),
            onTimeout: () => throw const TimeoutError(),
          );
    } on TimeoutError {
      rethrow;
    } on TimeoutException {
      throw const TimeoutError();
    } on SocketException {
      // Any socket-level failure = no connectivity or host unreachable.
      throw const OfflineError();
    }

    _mapTavilyStatusCode(response.statusCode, response.body);

    // Parse results.
    final Map<String, dynamic> json;
    try {
      json = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (_) {
      throw ProviderError(
        httpStatusCode: response.statusCode,
        responseBody: response.body,
      );
    }

    final rawResults = (json['results'] as List<dynamic>?) ?? [];
    final results = rawResults.take(kMaxSearchResults).map((item) {
      final m = item as Map<String, dynamic>;
      return WebSearchResult(
        title: (m['title'] as String?) ?? '',
        url: (m['url'] as String?) ?? '',
        // Use 'content' field — NOT 'snippet' (FR-010 prohibition).
        content: (m['content'] as String?) ?? '',
        score: ((m['score'] as num?) ?? 0.0).toDouble(),
      );
    }).toList();

    return results;
  }

  // ── fetchPage() ───────────────────────────────────────────────────────────

  @override
  Future<FetchResult> fetchPage(String url) async {
    final key = await _keyStore.readTavilyKey();
    if (key == null || key.isEmpty) {
      throw StateError('NetworkResearchService called without a valid key');
    }

    // Pre-flight connectivity probe (use the target URL's host).
    final uri = Uri.parse(url);
    await _preflight(uri.host);

    http.Response response;
    try {
      response = await _client
          .get(Uri.parse(url))
          .timeout(
            const Duration(milliseconds: kFetchTimeoutMs),
            onTimeout: () => throw const TimeoutError(),
          );
    } on TimeoutError {
      rethrow;
    } on TimeoutException {
      throw const TimeoutError();
    } on SocketException {
      // Any socket-level failure on direct fetch = no connectivity or host unreachable.
      throw const OfflineError();
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw FetchDomainError(
        domain: uri.host,
        httpStatusCode: response.statusCode,
      );
    }

    // Extract text via HtmlExtractor.
    final contentType = response.headers['content-type'] ?? 'text/html';
    final String extracted;
    try {
      extracted = _extractor.extract(response.body, contentType: contentType);
    } on ParseError {
      rethrow;
    }

    if (extracted.trim().isEmpty) {
      throw ParseError(
        reason: 'extraction produced no usable content from $url',
      );
    }

    // Determine truncation from the marker.
    final wasTruncated =
        extracted.contains('[truncated:') &&
        extracted.contains('items remaining]');

    return FetchResult(
      url: url,
      extractedText: extracted,
      wasTruncated: wasTruncated,
    );
  }

  // ── Pre-flight connectivity probe ─────────────────────────────────────────

  Future<void> _preflight(String hostname) async {
    try {
      await InternetAddress.lookup(hostname).timeout(
        const Duration(milliseconds: kConnectivityTimeoutMs),
        onTimeout: () => throw const OfflineError(),
      );
    } on OfflineError {
      rethrow;
    } on SocketException {
      throw const OfflineError();
    } on OSError {
      throw const OfflineError();
    }
  }

  // ── Error mapping ─────────────────────────────────────────────────────────

  void _mapTavilyStatusCode(int statusCode, String body) {
    if (statusCode >= 200 && statusCode < 300) return;
    if (statusCode == 401 || statusCode == 403) {
      throw KeyInvalidError(httpStatusCode: statusCode, responseBody: body);
    }
    if (statusCode == 429 || statusCode == 432 || statusCode == 433) {
      throw RateLimitError(httpStatusCode: statusCode, responseBody: body);
    }
    throw ProviderError(httpStatusCode: statusCode, responseBody: body);
  }
}
