import 'dart:convert';

import 'package:ai_assistant/domain/entities/tool_outcome.dart';
import 'package:ai_assistant/domain/entities/web_search_result.dart';
import 'package:ai_assistant/domain/services/tool_dispatcher.dart';
import 'package:ai_assistant/features/chat/tool_handler_providers.dart';
import 'package:ai_assistant/infrastructure/network/research_errors.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/container_harness.dart';
import '../helpers/fake_network_research_service.dart';
import '../helpers/fake_secure_key_store.dart';

/// T028 (006 US1) — dispatcher / handler unit tests for `web_search`.
///
/// Exercises the REAL handler wiring from [toolHandlersProvider] via [toolDispatcherProvider] (the
/// production closure, not a copy) backed by [FakeNetworkResearchService] + [FakeSecureKeyStore], so
/// the StateError key-guard, the `content`-not-`snippet` field name (FR-010), the 2,000-char bound,
/// and the full ResearchError → ToolFailure mapping are all covered against the shipped code.
void main() {
  late FakeNetworkResearchService network;
  late FakeSecureKeyStore keyStore;

  /// A dispatcher wired with the real handler map for a container whose 006 seams are the configured
  /// fakes. The key store is seeded with a valid key unless [withKey] is false (the StateError case).
  ToolDispatcher dispatcherWith({bool withKey = true}) {
    keyStore = FakeSecureKeyStore();
    if (withKey) keyStore.seed('tvly-test-key');
    final container = makeContainer(
      secureKeyStore: keyStore,
      networkResearch: network,
    );
    addTearDown(container.dispose);
    return container.read(toolDispatcherProvider);
  }

  setUp(() {
    network = FakeNetworkResearchService();
  });

  WebSearchResult result(String url, {double score = 0.9}) => WebSearchResult(
    title: 'title for $url',
    url: url,
    content: 'content for $url',
    score: score,
  );

  group('web_search success', () {
    test(
      'returns ToolSuccess with {results:[{title,url,content,score}]} — content not snippet',
      () async {
        network.stubSearch('dart 3 records', [
          result('https://dart.dev/a'),
          result('https://dart.dev/b'),
          result('https://dart.dev/c'),
        ]);
        final dispatcher = dispatcherWith();

        final outcome = await dispatcher.dispatch('web_search', {
          'query': 'dart 3 records',
        });

        expect(outcome, isA<ToolSuccess>());
        final success = outcome as ToolSuccess;
        final results = success.result['results']! as List;
        expect(results, hasLength(3));
        final first = results.first! as Map;
        // The field name is `content`, NOT `snippet` (FR-010).
        expect(first.containsKey('content'), isTrue);
        expect(first.containsKey('snippet'), isFalse);
        expect(first['title'], 'title for https://dart.dev/a');
        expect(first['url'], 'https://dart.dev/a');
        expect(first['content'], 'content for https://dart.dev/a');
        expect(first['score'], 0.9);
        // sourceUrls grounds the tappable source chips (FR-013).
        expect(success.result['sourceUrls'], [
          'https://dart.dev/a',
          'https://dart.dev/b',
          'https://dart.dev/c',
        ]);
      },
    );

    test(
      'combined serialised result is bounded to ≤ 2000 chars (FR-014)',
      () async {
        // Three results whose raw content would push the serialised JSON well past 2,000 chars; the
        // handler pre-truncates each content snippet so the final result respects the spec ceiling.
        final big = 'x' * 1500;
        network.stubSearch('big', [
          WebSearchResult(
            title: 't1',
            url: 'https://a.com',
            content: big,
            score: 0.5,
          ),
          WebSearchResult(
            title: 't2',
            url: 'https://b.com',
            content: big,
            score: 0.4,
          ),
          WebSearchResult(
            title: 't3',
            url: 'https://c.com',
            content: big,
            score: 0.3,
          ),
        ]);
        final dispatcher = dispatcherWith();

        final outcome = await dispatcher.dispatch('web_search', {
          'query': 'big',
        });

        expect(outcome, isA<ToolSuccess>());
        final success = outcome as ToolSuccess;
        // The serialised result respects the 2,000-char ceiling.
        expect(_serialisedLength(success.result), lessThanOrEqualTo(2000));
        // Each content snippet was clipped from its 1,500-char raw value.
        final results = success.result['results']! as List;
        for (final r in results) {
          expect((r as Map)['content'].toString().length, lessThan(1500));
        }
      },
    );
  });

  group('web_search zero results', () {
    test(
      'empty results → ToolSuccess {results:[], note:...} with no source urls',
      () async {
        network.stubSearch('obscure nonsense', const []);
        final dispatcher = dispatcherWith();

        final outcome = await dispatcher.dispatch('web_search', {
          'query': 'obscure nonsense',
        });

        expect(outcome, isA<ToolSuccess>());
        final success = outcome as ToolSuccess;
        expect(success.result['results'], isEmpty);
        expect(success.result['note'], contains('no results found'));
        // No grounding urls in the zero-results case (FR-033).
        expect(success.result.containsKey('sourceUrls'), isFalse);
      },
    );
  });

  group('web_search invalid args', () {
    test('empty query → ToolInvalidArgs("query is empty")', () async {
      final dispatcher = dispatcherWith();
      final outcome = await dispatcher.dispatch('web_search', {'query': '   '});
      expect(outcome, isA<ToolInvalidArgs>());
      expect((outcome as ToolInvalidArgs).reason, 'query is empty');
      // The handler was never reached — no network call.
      expect(network.searchCallLog, isEmpty);
    });

    test('>400-char query → ToolInvalidArgs (too long)', () async {
      final dispatcher = dispatcherWith();
      final outcome = await dispatcher.dispatch('web_search', {
        'query': 'a' * 401,
      });
      expect(outcome, isA<ToolInvalidArgs>());
      expect((outcome as ToolInvalidArgs).reason, contains('400'));
      expect(network.searchCallLog, isEmpty);
    });

    test('absent query key → ToolInvalidArgs', () async {
      final dispatcher = dispatcherWith();
      final outcome = await dispatcher.dispatch('web_search', const {});
      expect(outcome, isA<ToolInvalidArgs>());
      expect(network.searchCallLog, isEmpty);
    });
  });

  group('web_search error mapping (ResearchError → ToolFailure)', () {
    Future<ToolFailure> failureFor(ResearchError error) async {
      network.stubSearchError('q', error);
      final dispatcher = dispatcherWith();
      final outcome = await dispatcher.dispatch('web_search', {'query': 'q'});
      expect(outcome, isA<ToolFailure>());
      return outcome as ToolFailure;
    }

    test('OfflineError → "offline — no connection"', () async {
      expect(
        (await failureFor(const OfflineError())).reason,
        'offline — no connection',
      );
    });

    test('KeyInvalidError → "tavily key invalid — check Settings"', () async {
      expect(
        (await failureFor(const KeyInvalidError(httpStatusCode: 401))).reason,
        'tavily key invalid — check Settings',
      );
    });

    test('RateLimitError → "tavily limit reached — check your plan"', () async {
      expect(
        (await failureFor(const RateLimitError(httpStatusCode: 429))).reason,
        'tavily limit reached — check your plan',
      );
    });

    test('ProviderError(503) → "provider error (HTTP 503)"', () async {
      expect(
        (await failureFor(const ProviderError(httpStatusCode: 503))).reason,
        'provider error (HTTP 503)',
      );
    });

    test('TimeoutError → "request timed out — try again"', () async {
      expect(
        (await failureFor(const TimeoutError())).reason,
        'request timed out — try again',
      );
    });

    test('StateError (no valid key) → propagated as ToolFailure', () async {
      network.stubSearch('q', [result('https://a.com')]);
      final dispatcher = dispatcherWith(withKey: false);
      final outcome = await dispatcher.dispatch('web_search', {'query': 'q'});
      expect(outcome, isA<ToolFailure>());
      // The structural guard fires BEFORE any network call (the gate should have prevented this).
      expect(network.searchCallLog, isEmpty);
    });
  });

  group('gate congruence', () {
    test(
      'the real handler map includes web_search alongside the device + memory + web tools',
      () {
        final container = makeContainer(
          secureKeyStore: FakeSecureKeyStore()..seed('k'),
          networkResearch: network,
        );
        addTearDown(container.dispose);
        final handlers = container.read(toolHandlersProvider);
        expect(handlers.containsKey('web_search'), isTrue);
        expect(handlers.containsKey('fetch_page'), isTrue);
        // The four device + two memory + two web tools = eight handlers.
        expect(handlers.length, 8);
      },
    );
  });
}

// Mirror the dispatcher's bound metric: the JSON-encoded result string length.
int _serialisedLength(Map<String, Object?> map) => jsonEncode(map).length;
