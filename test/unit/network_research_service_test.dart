import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ai_assistant/infrastructure/network/research_errors.dart';
import 'package:ai_assistant/infrastructure/network/tavily_network_research_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../helpers/fake_secure_key_store.dart';

/// 006 T024 — NetworkResearchService integration tests (mocked http.Client).
///
/// All tests mock [http.Client] via [MockClient] (package:http/testing.dart) and
/// use [FakeSecureKeyStore] — NO real network calls are made.
///
/// Coverage:
/// - search() success (≤ 3 SearchResults with 'content' field, not 'snippet').
/// - search() zero results.
/// - search() KeyInvalidError on 401/403.
/// - search() RateLimitError on 429.
/// - search() ProviderError on 500.
/// - search() OfflineError on SocketException.
/// - search() TimeoutError on deadline.
/// - fetchPage() success (FetchResult text ≤ 2000 chars).
/// - fetchPage() FetchDomainError on target non-2xx.
/// - fetchPage() ParseError on empty extraction (non-HTML content-type).
/// - fetchPage() TimeoutError.
/// - Pre-flight InternetAddress.lookup failure → OfflineError before HTTP call.
void main() {
  late FakeSecureKeyStore keyStore;

  setUp(() {
    keyStore = FakeSecureKeyStore();
    keyStore.seed('tvly-test-key-abc123');
  });

  // ── Helper to build a Tavily-style JSON response ──────────────────────────

  String tavilyJson(List<Map<String, dynamic>> results) {
    return jsonEncode({'results': results});
  }

  Map<String, dynamic> tavilyResult({
    String title = 'Test Title',
    String url = 'https://example.com',
    String content = 'Test content snippet from the page',
    double score = 0.9,
  }) {
    return {'title': title, 'url': url, 'content': content, 'score': score};
  }

  TavilyNetworkResearchService makeService(http.Client mockClient) {
    return TavilyNetworkResearchService(keyStore: keyStore, client: mockClient);
  }

  // ── StateError guard ──────────────────────────────────────────────────────

  group('StateError guard — no valid key', () {
    test('search() throws StateError when no key stored', () async {
      keyStore.reset(); // remove the key
      final svc = makeService(
        MockClient((_) async => http.Response('{}', 200)),
      );
      expect(() => svc.search('anything'), throwsStateError);
    });

    test('fetchPage() throws StateError when no key stored', () async {
      keyStore.reset();
      final svc = makeService(
        MockClient((_) async => http.Response('{}', 200)),
      );
      expect(() => svc.fetchPage('https://example.com'), throwsStateError);
    });
  });

  // ── search() success paths ────────────────────────────────────────────────

  group('search() success', () {
    test('returns ≤ 3 SearchResults with content field', () async {
      final responseBody = tavilyJson([
        tavilyResult(
          title: 'Result 1',
          url: 'https://r1.com',
          content: 'Content one',
        ),
        tavilyResult(
          title: 'Result 2',
          url: 'https://r2.com',
          content: 'Content two',
        ),
        tavilyResult(
          title: 'Result 3',
          url: 'https://r3.com',
          content: 'Content three',
        ),
      ]);

      final svc = makeService(
        MockClient((request) async {
          expect(request.method, equals('POST'));
          expect(
            request.url.toString(),
            equals('https://api.tavily.com/search'),
          );
          expect(
            request.headers['Authorization'],
            equals('Bearer tvly-test-key-abc123'),
          );
          return http.Response(responseBody, 200);
        }),
      );

      final results = await svc.search('test query');
      expect(results.length, equals(3));
      expect(results[0].title, equals('Result 1'));
      expect(results[0].url, equals('https://r1.com'));
      expect(
        results[0].content,
        equals('Content one'),
      ); // 'content' NOT 'snippet' (FR-010)
      expect(results[1].score, isA<double>());
    });

    test('slices to at most 3 when Tavily returns more', () async {
      final responseBody = tavilyJson([
        tavilyResult(title: 'R1', url: 'https://r1.com', content: 'C1'),
        tavilyResult(title: 'R2', url: 'https://r2.com', content: 'C2'),
        tavilyResult(title: 'R3', url: 'https://r3.com', content: 'C3'),
        tavilyResult(title: 'R4', url: 'https://r4.com', content: 'C4'),
        tavilyResult(title: 'R5', url: 'https://r5.com', content: 'C5'),
      ]);

      final svc = makeService(
        MockClient((_) async => http.Response(responseBody, 200)),
      );
      final results = await svc.search('query');
      expect(results.length, lessThanOrEqualTo(3));
    });

    test('zero results array → empty list', () async {
      final responseBody = tavilyJson([]);
      final svc = makeService(
        MockClient((_) async => http.Response(responseBody, 200)),
      );
      final results = await svc.search('unusual query no results');
      expect(results, isEmpty);
    });

    test('uses max_results: 3 in request body', () async {
      var capturedBody = '';
      final svc = makeService(
        MockClient((req) async {
          capturedBody = req.body;
          return http.Response(tavilyJson([]), 200);
        }),
      );

      await svc.search('hello');
      final decoded = jsonDecode(capturedBody) as Map<String, dynamic>;
      expect(decoded['max_results'], equals(3));
      expect(decoded['query'], equals('hello'));
    });
  });

  // ── search() error paths ──────────────────────────────────────────────────

  group('search() error mapping', () {
    test('401 → KeyInvalidError', () async {
      final svc = makeService(
        MockClient((_) async => http.Response('Unauthorized', 401)),
      );
      expect(
        () => svc.search('query'),
        throwsA(
          isA<KeyInvalidError>().having((e) => e.httpStatusCode, 'status', 401),
        ),
      );
    });

    test('403 → KeyInvalidError', () async {
      final svc = makeService(
        MockClient((_) async => http.Response('Forbidden', 403)),
      );
      expect(
        () => svc.search('query'),
        throwsA(
          isA<KeyInvalidError>().having((e) => e.httpStatusCode, 'status', 403),
        ),
      );
    });

    test('429 → RateLimitError', () async {
      final svc = makeService(
        MockClient((_) async => http.Response('Too Many Requests', 429)),
      );
      expect(
        () => svc.search('query'),
        throwsA(
          isA<RateLimitError>().having((e) => e.httpStatusCode, 'status', 429),
        ),
      );
    });

    test('500 → ProviderError', () async {
      final svc = makeService(
        MockClient((_) async => http.Response('Internal Server Error', 500)),
      );
      expect(
        () => svc.search('query'),
        throwsA(
          isA<ProviderError>().having((e) => e.httpStatusCode, 'status', 500),
        ),
      );
    });

    test('SocketException → OfflineError', () async {
      final svc = makeService(
        MockClient((_) async {
          throw const SocketException('Network is unreachable');
        }),
      );
      expect(() => svc.search('query'), throwsA(isA<OfflineError>()));
    });

    test('TimeoutException from transport → TimeoutError', () async {
      // MockClient that throws TimeoutException directly (simulates timeout at transport level).
      final svc = makeService(
        MockClient((_) async {
          throw TimeoutException('Timed out', const Duration(milliseconds: 1));
        }),
      );
      expect(() => svc.search('query'), throwsA(isA<TimeoutError>()));
    });
  });

  // ── fetchPage() success paths ─────────────────────────────────────────────

  group('fetchPage() success', () {
    test(
      '2xx response with HTML body → FetchResult with extracted text',
      () async {
        const html = '''
<!DOCTYPE html>
<html><head><title>Test Page</title></head>
<body>
  <article>
    <p>This is the main article content that should be extracted from the page for the model.</p>
    <p>Here is a second paragraph with more interesting content about the topic.</p>
  </article>
</body>
</html>
''';
        final svc = makeService(
          MockClient(
            (_) async => http.Response(
              html,
              200,
              headers: {'content-type': 'text/html; charset=utf-8'},
            ),
          ),
        );

        final result = await svc.fetchPage('https://example.com/article');
        expect(result.url, equals('https://example.com/article'));
        expect(result.extractedText, isNotEmpty);
        expect(result.extractedText, contains('main article content'));
        expect(result.extractedText.length, lessThanOrEqualTo(2000));
      },
    );

    test('short content: wasTruncated = false', () async {
      const html = '''
<html><body><article><p>Short article content that fits in 2000 chars easily.</p></article></body></html>
''';
      final svc = makeService(
        MockClient(
          (_) async =>
              http.Response(html, 200, headers: {'content-type': 'text/html'}),
        ),
      );

      final result = await svc.fetchPage('https://example.com');
      expect(result.wasTruncated, isFalse);
    });

    test('long content: extractedText ≤ 2000 chars', () async {
      final longParagraph =
          'The quick brown fox jumps over the lazy dog. ' * 70;
      final html =
          '''
<html><body><article><p>$longParagraph</p></article></body></html>
''';
      final svc = makeService(
        MockClient(
          (_) async => http.Response(
            html,
            200,
            headers: {'content-type': 'text/html; charset=utf-8'},
          ),
        ),
      );

      final result = await svc.fetchPage('https://example.com');
      expect(result.extractedText.length, lessThanOrEqualTo(2000));
      expect(result.wasTruncated, isTrue);
    });
  });

  // ── fetchPage() error paths ───────────────────────────────────────────────

  group('fetchPage() error mapping', () {
    test('404 from target site → FetchDomainError with domain', () async {
      final svc = makeService(
        MockClient((_) async => http.Response('Not Found', 404)),
      );
      expect(
        () => svc.fetchPage('https://example.com/missing'),
        throwsA(
          isA<FetchDomainError>()
              .having((e) => e.domain, 'domain', equals('example.com'))
              .having((e) => e.httpStatusCode, 'httpStatusCode', equals(404)),
        ),
      );
    });

    test('500 from target site → FetchDomainError (not ProviderError)', () async {
      final svc = makeService(
        MockClient((_) async => http.Response('Server Error', 500)),
      );
      // FetchDomainError — NOT ProviderError (different error roots per contract)
      expect(
        () => svc.fetchPage('https://flutter.dev/docs'),
        throwsA(isA<FetchDomainError>()),
      );
    });

    test('non-HTML content-type → ParseError', () async {
      final svc = makeService(
        MockClient(
          (_) async => http.Response(
            '%PDF-1.4 fake pdf content',
            200,
            headers: {'content-type': 'application/pdf'},
          ),
        ),
      );
      expect(
        () => svc.fetchPage('https://example.com/doc.pdf'),
        throwsA(
          isA<ParseError>().having(
            (e) => e.reason,
            'reason',
            contains('application/pdf'),
          ),
        ),
      );
    });

    test('2xx but no extractable text → ParseError', () async {
      // A page with zero meaningful text after extraction.
      const emptyHtml = '''
<!DOCTYPE html>
<html><head><title>Empty</title></head>
<body><p></p></body>
</html>
''';
      final svc = makeService(
        MockClient(
          (_) async => http.Response(
            emptyHtml,
            200,
            headers: {'content-type': 'text/html'},
          ),
        ),
      );
      // The extractor may throw ParseError or return empty — the service throws ParseError.
      expect(
        () => svc.fetchPage('https://example.com/empty'),
        throwsA(isA<ParseError>()),
      );
    });

    test('SocketException on fetch → OfflineError', () async {
      final svc = makeService(
        MockClient((_) async {
          throw const SocketException('Network is unreachable');
        }),
      );
      expect(
        () => svc.fetchPage('https://example.com'),
        throwsA(isA<OfflineError>()),
      );
    });

    test('TimeoutException on fetch → TimeoutError', () async {
      final svc = makeService(
        MockClient((_) async {
          throw TimeoutException('Timed out');
        }),
      );
      expect(
        () => svc.fetchPage('https://example.com'),
        throwsA(isA<TimeoutError>()),
      );
    });
  });

  // ── Pre-flight OfflineError before HTTP ───────────────────────────────────

  group('pre-flight InternetAddress.lookup failure → OfflineError', () {
    // NOTE: We cannot easily mock InternetAddress.lookup without platform-level mocking.
    // These tests verify SocketException (which pre-flight converts) is caught correctly.
    // Full offline integration is verified in the device walkthrough (quickstart V7).

    test(
      'SocketException during search → OfflineError (pre-flight or HTTP level)',
      () async {
        final svc = makeService(
          MockClient((_) async {
            throw SocketException(
              'No route to host',
              address: InternetAddress.loopbackIPv4,
            );
          }),
        );
        expect(() => svc.search('query'), throwsA(isA<OfflineError>()));
      },
    );

    test('SocketException during fetchPage → OfflineError', () async {
      final svc = makeService(
        MockClient((_) async {
          throw const SocketException('Network unreachable');
        }),
      );
      expect(
        () => svc.fetchPage('https://example.com'),
        throwsA(isA<OfflineError>()),
      );
    });
  });

  // ── No retry guarantee ────────────────────────────────────────────────────

  group('no retry (FR-020)', () {
    test('search() calls HTTP exactly once on failure', () async {
      var callCount = 0;
      final svc = makeService(
        MockClient((_) async {
          callCount++;
          return http.Response('Server Error', 500);
        }),
      );

      try {
        await svc.search('query');
      } on ProviderError {
        // expected
      }
      expect(callCount, equals(1));
    });

    test('fetchPage() calls HTTP exactly once on failure', () async {
      var callCount = 0;
      final svc = makeService(
        MockClient((_) async {
          callCount++;
          return http.Response('Not Found', 404);
        }),
      );

      try {
        await svc.fetchPage('https://example.com');
      } on FetchDomainError {
        // expected
      }
      expect(callCount, equals(1));
    });
  });
}
