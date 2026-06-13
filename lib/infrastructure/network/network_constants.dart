// Network timing and size constants for the web research feature
// (006, contracts/network_research_service.md, data-model §1).
//
// All timeout values are in milliseconds. Size bounds are in characters or tokens as named.

/// Wall-clock timeout for the Tavily Search API POST (10 s).
const int kTavilyTimeoutMs = 10000;

/// Wall-clock timeout for the target-site GET in [NetworkResearchService.fetchPage] (15 s).
const int kFetchTimeoutMs = 15000;

/// Timeout for the pre-flight connectivity probe (`InternetAddress.lookup`) (3 s).
const int kConnectivityTimeoutMs = 3000;

/// Internal extraction pipeline token ceiling — the maximum number of tokens the [HtmlExtractor]
/// processes before truncating. Applied before [kFetchResultCharBound].
const int kMaxExtractedTokens = 4000;

/// Authoritative tool-result character bound for [NetworkResearchService.fetchPage] (FR-014,
/// SC-006). The `fetch_page` handler hard-truncates [FetchResult.extractedText] to this many
/// characters before serialising. 1,500 chars MUST NOT be used as the bound.
const int kFetchResultCharBound = 2000;

/// Maximum number of search results returned by [NetworkResearchService.search] (FR-010).
/// The Tavily request includes `max_results: kMaxSearchResults` and the seam slices to at most
/// this many items before returning.
const int kMaxSearchResults = 3;
