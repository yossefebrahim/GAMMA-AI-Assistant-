import 'dart:convert';

import 'package:ai_assistant/domain/entities/fetch_result.dart';
import 'package:ai_assistant/domain/entities/tool_outcome.dart';
import 'package:ai_assistant/domain/services/tool_dispatcher.dart';
import 'package:ai_assistant/features/chat/tool_handler_providers.dart';
import 'package:ai_assistant/infrastructure/network/research_errors.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/container_harness.dart';
import '../helpers/fake_network_research_service.dart';
import '../helpers/fake_secure_key_store.dart';

/// T035 (006 US4) — dispatcher / handler unit tests for `fetch_page`.
///
/// Exercises the REAL handler wiring from [toolHandlersProvider] via [toolDispatcherProvider] (the
/// production closure, not a copy) backed by [FakeNetworkResearchService] + [FakeSecureKeyStore], so
/// the StateError key-guard, the `{url, text, truncated}` result shape, the 2,000-char bound, the
/// `format: uri` + scheme-allowlist + maxLength validation, and the full ResearchError → ToolFailure
/// mapping are all covered against the shipped code.
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

  group('fetch_page success', () {
    test(
      'returns ToolSuccess with {url,text,truncated:false}; text ≤ 2000 chars',
      () async {
        network.stubFetch(
          'https://flutter.dev/docs',
          const FetchResult(
            url: 'https://flutter.dev/docs',
            extractedText: 'the readable extracted text of the page',
            wasTruncated: false,
          ),
        );
        final dispatcher = dispatcherWith();

        final outcome = await dispatcher.dispatch('fetch_page', {
          'url': 'https://flutter.dev/docs',
        });

        expect(outcome, isA<ToolSuccess>());
        final success = outcome as ToolSuccess;
        expect(success.result['url'], 'https://flutter.dev/docs');
        expect(
          success.result['text'],
          'the readable extracted text of the page',
        );
        expect(success.result['truncated'], isFalse);
        // The single fetched page is the lone source url for the source chip (FR-013).
        expect(success.result['sourceUrls'], ['https://flutter.dev/docs']);
        expect(_serialisedLength(success.result), lessThanOrEqualTo(2000));
        expect(network.fetchCallLog, ['https://flutter.dev/docs']);
      },
    );
  });

  group('fetch_page truncation', () {
    test(
      'truncated text ends with marker; truncated:true; result ≤ 2000 chars',
      () async {
        // The seam hard-bounds extractedText to 2,000 chars and appends the marker; the handler
        // surfaces both the bounded text and the wasTruncated flag verbatim (FR-014, SC-006). Sized
        // so the full serialised result (url + sourceUrls + keys) still fits the 2,000-char ceiling
        // without the dispatcher's _applyBound safety net re-clipping the marker.
        final bounded = 'x' * 1820 + ' [truncated: 7 items remaining]';
        network.stubFetch(
          'https://en.wikipedia.org/wiki/Dart',
          FetchResult(
            url: 'https://en.wikipedia.org/wiki/Dart',
            extractedText: bounded,
            wasTruncated: true,
          ),
        );
        final dispatcher = dispatcherWith();

        final outcome = await dispatcher.dispatch('fetch_page', {
          'url': 'https://en.wikipedia.org/wiki/Dart',
        });

        expect(outcome, isA<ToolSuccess>());
        final success = outcome as ToolSuccess;
        expect(success.result['truncated'], isTrue);
        expect(
          (success.result['text'] as String),
          endsWith('[truncated: 7 items remaining]'),
        );
        expect(_serialisedLength(success.result), lessThanOrEqualTo(2000));
      },
    );
  });

  group('fetch_page invalid args', () {
    test('malformed URL → ToolInvalidArgs("url is not a valid URI")', () async {
      final dispatcher = dispatcherWith();
      final outcome = await dispatcher.dispatch('fetch_page', {
        'url': 'not a url at all',
      });
      expect(outcome, isA<ToolInvalidArgs>());
      // The validator prepends "argument "; the meaningful clause is the contract message.
      expect(
        (outcome as ToolInvalidArgs).reason,
        contains('url is not a valid URI'),
      );
      expect(network.fetchCallLog, isEmpty);
    });

    test(
      'non-http(s) scheme → ToolInvalidArgs("url scheme must be http or https")',
      () async {
        final dispatcher = dispatcherWith();
        final outcome = await dispatcher.dispatch('fetch_page', {
          'url': 'ftp://example.com/file',
        });
        expect(outcome, isA<ToolInvalidArgs>());
        expect(
          (outcome as ToolInvalidArgs).reason,
          'url scheme must be http or https',
        );
        expect(network.fetchCallLog, isEmpty);
      },
    );

    test('>2048-char URL → ToolInvalidArgs (too long)', () async {
      final dispatcher = dispatcherWith();
      final longUrl = 'https://example.com/${'a' * 2048}';
      final outcome = await dispatcher.dispatch('fetch_page', {'url': longUrl});
      expect(outcome, isA<ToolInvalidArgs>());
      expect((outcome as ToolInvalidArgs).reason, contains('too long'));
      expect((outcome).reason, contains('2048'));
      expect(network.fetchCallLog, isEmpty);
    });

    test('absent url key → ToolInvalidArgs', () async {
      final dispatcher = dispatcherWith();
      final outcome = await dispatcher.dispatch('fetch_page', const {});
      expect(outcome, isA<ToolInvalidArgs>());
      expect(network.fetchCallLog, isEmpty);
    });
  });

  group('fetch_page error mapping (ResearchError → ToolFailure)', () {
    Future<ToolFailure> failureFor(String url, ResearchError error) async {
      network.stubFetchError(url, error);
      final dispatcher = dispatcherWith();
      final outcome = await dispatcher.dispatch('fetch_page', {'url': url});
      expect(outcome, isA<ToolFailure>());
      return outcome as ToolFailure;
    }

    test('FetchDomainError → ToolFailure naming the domain', () async {
      final failure = await failureFor(
        'https://flutter.dev/down',
        const FetchDomainError(domain: 'flutter.dev'),
      );
      expect(
        failure.reason,
        'could not reach flutter.dev — check the URL or try later',
      );
    });

    test('ParseError → "could not extract text from page"', () async {
      final failure = await failureFor(
        'https://example.com/binary',
        const ParseError(reason: 'non-HTML content-type: application/pdf'),
      );
      expect(failure.reason, 'could not extract text from page');
    });

    test('OfflineError → "offline — no connection"', () async {
      final failure = await failureFor(
        'https://example.com/x',
        const OfflineError(),
      );
      expect(failure.reason, 'offline — no connection');
    });

    test('TimeoutError → "request timed out — try again"', () async {
      final failure = await failureFor(
        'https://example.com/slow',
        const TimeoutError(),
      );
      expect(failure.reason, 'request timed out — try again');
    });

    test('StateError (no valid key) → propagated as ToolFailure', () async {
      network.stubFetch(
        'https://example.com/x',
        const FetchResult(
          url: 'https://example.com/x',
          extractedText: 'text',
          wasTruncated: false,
        ),
      );
      final dispatcher = dispatcherWith(withKey: false);
      final outcome = await dispatcher.dispatch('fetch_page', {
        'url': 'https://example.com/x',
      });
      expect(outcome, isA<ToolFailure>());
      // The structural guard fires BEFORE any network call (the gate should have prevented this).
      expect(network.fetchCallLog, isEmpty);
    });
  });
}

// Mirror the dispatcher's bound metric: the JSON-encoded result string length.
int _serialisedLength(Map<String, Object?> map) => jsonEncode(map).length;
