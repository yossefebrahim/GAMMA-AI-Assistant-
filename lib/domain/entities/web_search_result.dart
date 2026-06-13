import 'package:meta/meta.dart';

/// One item from a Tavily search response (006, data-model §1).
///
/// Field names match Tavily's API contract exactly — [content] is Tavily's field name and MUST NOT
/// be renamed to "snippet" anywhere in the serialisation layer (FR-010). This entity is transient:
/// produced by [NetworkResearchService.search] and discarded after the tool result JSON is assembled.
@immutable
class WebSearchResult {
  const WebSearchResult({
    required this.title,
    required this.url,
    required this.content,
    required this.score,
  });

  /// Page title as returned by Tavily.
  final String title;

  /// Canonical URL of the result.
  final String url;

  /// Pre-extracted clean text snippet from Tavily's `content` field (R4).
  /// NOT renamed to "snippet" — FR-010 prohibition.
  final String content;

  /// Tavily relevance score (0–1).
  final double score;

  WebSearchResult copyWith({
    String? title,
    String? url,
    String? content,
    double? score,
  }) {
    return WebSearchResult(
      title: title ?? this.title,
      url: url ?? this.url,
      content: content ?? this.content,
      score: score ?? this.score,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is WebSearchResult &&
      other.title == title &&
      other.url == url &&
      other.content == content &&
      other.score == score;

  @override
  int get hashCode => Object.hash(title, url, content, score);
}
