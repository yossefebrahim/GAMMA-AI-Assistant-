import 'package:ai_assistant/domain/entities/tool_outcome.dart';
import 'package:ai_assistant/features/chat/tool_handler_providers.dart';
import 'package:ai_assistant/infrastructure/network/research_errors.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/container_harness.dart';
import '../helpers/fake_network_research_service.dart';
import '../helpers/fake_secure_key_store.dart';

/// T047 (006 US5; FR-019, FR-027, FR-034, SC-004, SC-005) — error taxonomy → chip-message mapping.
///
/// Each [ResearchError] subtype thrown by the seam must map, through the REAL handler + dispatcher
/// path, to a DISTINCT plain-language [ToolFailure] reason — the exact string the error chip renders.
/// No crash, no retry (the seam is called exactly once per dispatch — asserted via the fake's call
/// log). `FetchDomainError` must name the domain AND be distinct from `ProviderError`
/// (Constitution Principle I — Tavily vs the target site are never conflated).
void main() {
  late FakeNetworkResearchService network;
  late FakeSecureKeyStore keyStore;

  setUp(() {
    network = FakeNetworkResearchService();
    keyStore = FakeSecureKeyStore()..seed('k');
  });

  /// Dispatch [tool] with [args] through the real handler map + dispatcher and return the outcome.
  Future<ToolOutcome> dispatch(String tool, Map<String, Object?> args) async {
    final container = makeContainer(
      networkResearch: network,
      secureKeyStore: keyStore,
    );
    addTearDown(container.dispose);
    return container.read(toolDispatcherProvider).dispatch(tool, args);
  }

  String reasonOf(ToolOutcome outcome) {
    expect(
      outcome,
      isA<ToolFailure>(),
      reason: 'expected a ToolFailure, got $outcome',
    );
    return (outcome as ToolFailure).reason;
  }

  group('web_search error mapping', () {
    test(
      'OfflineError → "offline — no connection"; seam called once',
      () async {
        network.stubSearchError('q', const OfflineError());
        final outcome = await dispatch('web_search', {'query': 'q'});
        expect(reasonOf(outcome), 'offline — no connection');
        // No retry: the seam is hit exactly once.
        expect(network.searchCallLog, ['q']);
      },
    );

    test('KeyInvalidError → "tavily key invalid — check Settings"', () async {
      network.stubSearchError('q', const KeyInvalidError(httpStatusCode: 401));
      expect(
        reasonOf(await dispatch('web_search', {'query': 'q'})),
        'tavily key invalid — check Settings',
      );
    });

    test('RateLimitError → "tavily limit reached — check your plan"', () async {
      network.stubSearchError('q', const RateLimitError(httpStatusCode: 429));
      expect(
        reasonOf(await dispatch('web_search', {'query': 'q'})),
        'tavily limit reached — check your plan',
      );
    });

    test('ProviderError → "provider error (HTTP 503)"', () async {
      network.stubSearchError('q', const ProviderError(httpStatusCode: 503));
      expect(
        reasonOf(await dispatch('web_search', {'query': 'q'})),
        'provider error (HTTP 503)',
      );
    });

    test('TimeoutError → "request timed out — try again"', () async {
      network.stubSearchError('q', const TimeoutError());
      expect(
        reasonOf(await dispatch('web_search', {'query': 'q'})),
        'request timed out — try again',
      );
    });
  });

  group('fetch_page error mapping', () {
    test('FetchDomainError → names the domain', () async {
      network.stubFetchError(
        'https://flutter.dev/x',
        const FetchDomainError(domain: 'flutter.dev'),
      );
      final reason = reasonOf(
        await dispatch('fetch_page', {'url': 'https://flutter.dev/x'}),
      );
      expect(
        reason,
        'could not reach flutter.dev — check the URL or try later',
      );
      expect(reason, contains('flutter.dev'));
      expect(network.fetchCallLog, ['https://flutter.dev/x']);
    });

    test('ParseError → "could not extract text from page"', () async {
      network.stubFetchError(
        'https://flutter.dev/y',
        const ParseError(reason: 'non-HTML content-type: application/pdf'),
      );
      expect(
        reasonOf(
          await dispatch('fetch_page', {'url': 'https://flutter.dev/y'}),
        ),
        'could not extract text from page',
      );
    });

    test('OfflineError → "offline — no connection"', () async {
      network.stubFetchError('https://flutter.dev/z', const OfflineError());
      expect(
        reasonOf(
          await dispatch('fetch_page', {'url': 'https://flutter.dev/z'}),
        ),
        'offline — no connection',
      );
    });
  });

  test(
    'FetchDomainError message is DISTINCT from ProviderError (Principle I)',
    () async {
      network.stubFetchError(
        'https://flutter.dev/a',
        const FetchDomainError(domain: 'flutter.dev'),
      );
      network.stubSearchError('a', const ProviderError(httpStatusCode: 503));
      final domainReason = reasonOf(
        await dispatch('fetch_page', {'url': 'https://flutter.dev/a'}),
      );
      final providerReason = reasonOf(
        await dispatch('web_search', {'query': 'a'}),
      );
      expect(domainReason, isNot(equals(providerReason)));
      // The Tavily-side message must not name the target domain, and vice versa.
      expect(providerReason, isNot(contains('flutter.dev')));
      expect(domainReason, contains('flutter.dev'));
    },
  );

  test('every distinct ResearchError yields a distinct chip message', () async {
    final messages = <String>{};
    network.stubSearchError('a', const OfflineError());
    network.stubSearchError('b', const KeyInvalidError(httpStatusCode: 401));
    network.stubSearchError('c', const RateLimitError(httpStatusCode: 429));
    network.stubSearchError('d', const ProviderError(httpStatusCode: 503));
    network.stubSearchError('e', const TimeoutError());
    network.stubFetchError(
      'https://x.dev/p',
      const FetchDomainError(domain: 'x.dev'),
    );
    network.stubFetchError(
      'https://x.dev/q',
      const ParseError(reason: 'empty'),
    );
    for (final q in ['a', 'b', 'c', 'd', 'e']) {
      messages.add(reasonOf(await dispatch('web_search', {'query': q})));
    }
    for (final url in ['https://x.dev/p', 'https://x.dev/q']) {
      messages.add(reasonOf(await dispatch('fetch_page', {'url': url})));
    }
    // 7 error types → 7 distinct plain-language messages.
    expect(messages.length, 7);
  });
}
