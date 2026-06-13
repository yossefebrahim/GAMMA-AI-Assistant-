import 'package:meta/meta.dart';

/// Extracted text from a [NetworkResearchService.fetchPage] call, ready to pass to the model
/// (006, data-model §1).
///
/// This entity is transient: produced by [NetworkResearchService.fetchPage] and discarded after the
/// tool result JSON is assembled. NOTE: `domain` is NOT a field — it is derived at chip-render time
/// via `Uri.parse(url).host` (e.g. `en.wikipedia.org`).
@immutable
class FetchResult {
  const FetchResult({
    required this.url,
    required this.extractedText,
    required this.wasTruncated,
  });

  /// The URL that was requested for fetching (the post-redirect final URL is not
  /// recoverable from `http`'s plain `get`, so this is the originally requested URL).
  final String url;

  /// Cleaned body text from HtmlExtractor; hard-bounded at kFetchResultCharBound (2,000) chars.
  /// May be up to ~4,000 tokens internally before the resultCharBound truncation is applied at the
  /// handler.
  final String extractedText;

  /// True when [extractedText] was clipped to fit the bound and a
  /// `[truncated: N items remaining]` marker was appended.
  final bool wasTruncated;

  FetchResult copyWith({
    String? url,
    String? extractedText,
    bool? wasTruncated,
  }) {
    return FetchResult(
      url: url ?? this.url,
      extractedText: extractedText ?? this.extractedText,
      wasTruncated: wasTruncated ?? this.wasTruncated,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is FetchResult &&
      other.url == url &&
      other.extractedText == extractedText &&
      other.wasTruncated == wasTruncated;

  @override
  int get hashCode => Object.hash(url, extractedText, wasTruncated);
}
