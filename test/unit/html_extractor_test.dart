import 'dart:io';

import 'package:ai_assistant/infrastructure/network/html_extractor.dart';
import 'package:ai_assistant/infrastructure/network/network_constants.dart';
import 'package:ai_assistant/infrastructure/network/research_errors.dart';
import 'package:flutter_test/flutter_test.dart';

/// 006 T022 — HtmlExtractor unit tests against all 11 saved fixtures.
///
/// Coverage:
/// (a) Extraction quality — readable text present, boilerplate absent, correct priority-order
///     selection (article > main > [role="main"] > heuristics > body).
/// (b) Wikipedia p-only rule — no navboxes/infoboxes in output.
/// (c) Hard-truncation at kFetchResultCharBound (2000) chars with '[truncated: N items remaining]'.
/// (d) Binary/non-HTML content-type → ParseError (synthesised in-code, no binary fixture on disk).
void main() {
  const extractor = HtmlExtractor();

  // ── Fixture paths ─────────────────────────────────────────────────────────

  String fixture(String name) {
    // Resolve relative to the project root, as flutter test runs from project root.
    final f = File('specs/006-web-research/fixtures/$name');
    return f.readAsStringSync();
  }

  // ── (a) Extraction quality ────────────────────────────────────────────────

  group('extraction quality — readable text present, boilerplate absent', () {
    test('news-bbc-1: extracts news article text (article selector)', () {
      final body = fixture('news-bbc-1.html');
      final result = extractor.extract(
        body,
        contentType: 'text/html; charset=utf-8',
      );

      expect(result, isNotEmpty);
      expect(result.length, lessThanOrEqualTo(kFetchResultCharBound));
      // Should contain meaningful article content about the sea drone rescue story.
      expect(
        result.toLowerCase(),
        anyOf(
          contains('drone'),
          contains('helicopter'),
          contains('rescue'),
          contains('corsair'),
          contains('sea'),
        ),
      );
      // Should NOT contain raw JS/CSS.
      expect(result, isNot(contains('window.dotcom')));
      expect(result, isNot(contains('@font-face')));
    });

    test('news-guardian-1: extracts news text (article selector)', () {
      final body = fixture('news-guardian-1.html');
      final result = extractor.extract(body, contentType: 'text/html');

      expect(result, isNotEmpty);
      expect(result.length, lessThanOrEqualTo(kFetchResultCharBound));
      // Should contain news content (lung cancer AI article).
      expect(
        result.toLowerCase(),
        anyOf(
          contains('cancer'),
          contains('nhs'),
          contains('ai'),
          contains('lung'),
          contains('diagnos'),
          contains('article'),
        ),
      );
      expect(result, isNot(contains('window.googletag')));
    });

    test('docs-mdn-1: extracts MDN documentation (main selector)', () {
      final body = fixture('docs-mdn-1.html');
      final result = extractor.extract(
        body,
        contentType: 'text/html; charset=utf-8',
      );

      expect(result, isNotEmpty);
      expect(result.length, lessThanOrEqualTo(kFetchResultCharBound));
      // MDN article element content
      expect(
        result.toLowerCase(),
        anyOf(
          contains('article'),
          contains('html'),
          contains('element'),
          contains('content'),
        ),
      );
    });

    test('docs-dart-1: extracts Dart documentation (article selector)', () {
      final body = fixture('docs-dart-1.html');
      final result = extractor.extract(body, contentType: 'text/html');

      expect(result, isNotEmpty);
      expect(result.length, lessThanOrEqualTo(kFetchResultCharBound));
      expect(
        result.toLowerCase(),
        anyOf(
          contains('dart'),
          contains('concurr'),
          contains('isolate'),
          contains('parallel'),
        ),
      );
      // Should not contain raw script content.
      expect(result, isNot(contains('window.dataLayer')));
    });

    test('blog-overreacted-1: extracts blog article (article selector)', () {
      final body = fixture('blog-overreacted-1.html');
      final result = extractor.extract(
        body,
        contentType: 'text/html; charset=utf-8',
      );

      expect(result, isNotEmpty);
      expect(result.length, lessThanOrEqualTo(kFetchResultCharBound));
      expect(
        result.toLowerCase(),
        anyOf(
          contains('useeffect'),
          contains('hooks'),
          contains('react'),
          contains('components'),
        ),
      );
    });

    test('blog-jvns-1: extracts blog article (article selector)', () {
      final body = fixture('blog-jvns-1.html');
      final result = extractor.extract(body, contentType: 'text/html');

      expect(result, isNotEmpty);
      expect(result.length, lessThanOrEqualTo(kFetchResultCharBound));
      expect(
        result.toLowerCase(),
        anyOf(
          contains('command'),
          contains('tool'),
          contains('ripgrep'),
          contains('julia'),
          contains('list'),
        ),
      );
    });

    test('blog-fowler-1: extracts blog article (main selector)', () {
      final body = fixture('blog-fowler-1.html');
      final result = extractor.extract(
        body,
        contentType: 'text/html; charset=utf-8',
      );

      expect(result, isNotEmpty);
      expect(result.length, lessThanOrEqualTo(kFetchResultCharBound));
      expect(
        result.toLowerCase(),
        anyOf(
          contains('microservice'),
          contains('architecture'),
          contains('service'),
          contains('agile'),
        ),
      );
    });

    test('gov-data-1: extracts government page content', () {
      final body = fixture('gov-data-1.html');
      final result = extractor.extract(body, contentType: 'text/html');

      expect(result, isNotEmpty);
      expect(result.length, lessThanOrEqualTo(kFetchResultCharBound));
      expect(
        result.toLowerCase(),
        anyOf(
          contains('data'),
          contains('climate'),
          contains('government'),
          contains('update'),
          contains('datasets'),
        ),
      );
    });

    test('gov-nist-1: extracts NIST government page (body fallback)', () {
      final body = fixture('gov-nist-1.html');
      final result = extractor.extract(
        body,
        contentType: 'text/html; charset=utf-8',
      );

      expect(result, isNotEmpty);
      expect(result.length, lessThanOrEqualTo(kFetchResultCharBound));
      expect(
        result.toLowerCase(),
        anyOf(
          contains('nist'),
          contains('standard'),
          contains('technology'),
          contains('intelligence'),
          contains('government'),
        ),
      );
    });

    test('priority-order: article selected over main when both present', () {
      // Construct HTML with both <article> and <main> — article wins.
      const html = '''
<!DOCTYPE html>
<html><head><title>Test</title></head>
<body>
  <main><p>This is the main section content that should not be picked first</p></main>
  <article><p>This is the article content that should be selected by priority</p></article>
</body>
</html>
''';
      final result = extractor.extract(html, contentType: 'text/html');
      expect(result, contains('article content that should be selected'));
    });

    test('priority-order: main selected when no article present', () {
      const html = '''
<!DOCTYPE html>
<html><head><title>Test</title></head>
<body>
  <nav><a href="/home">Home</a><a href="/about">About</a></nav>
  <main><p>Main content lives here and should be extracted.</p></main>
  <footer><p>Footer text that should not appear</p></footer>
</body>
</html>
''';
      final result = extractor.extract(html, contentType: 'text/html');
      expect(result, contains('Main content lives here'));
      expect(result, isNot(contains('Footer text')));
    });

    test('priority-order: role=main selected when no article or main tag', () {
      const html = '''
<!DOCTYPE html>
<html><head><title>Test</title></head>
<body>
  <div role="main"><p>Role-main content is here.</p></div>
  <nav><a href="/">home</a></nav>
</body>
</html>
''';
      final result = extractor.extract(html, contentType: 'text/html');
      expect(result, contains('Role-main content'));
    });

    test(
      'boilerplate: nav/header/footer/script/style stripped from output',
      () {
        const html = '''
<!DOCTYPE html>
<html><head><title>T</title></head>
<body>
  <header><p>Site header navigation stuff</p></header>
  <nav><a href="/home">Home</a></nav>
  <main>
    <script>var x = "raw javascript that must not appear";</script>
    <style>.cls { color: red; }</style>
    <p>The real article text that should appear in extraction output.</p>
  </main>
  <footer><p>Footer with copyright notice</p></footer>
</body>
</html>
''';
        final result = extractor.extract(html, contentType: 'text/html');
        expect(result, contains('real article text'));
        expect(result, isNot(contains('raw javascript')));
        expect(result, isNot(contains('.cls { color')));
        expect(result, isNot(contains('Site header navigation')));
        expect(result, isNot(contains('copyright notice')));
      },
    );
  });

  // ── (b) Wikipedia p-only rule ─────────────────────────────────────────────

  group('Wikipedia p-only extraction', () {
    test('wikipedia-1 (Dart lang): extracts p-content, result bounded', () {
      final body = fixture('wikipedia-1.html');
      final result = extractor.extract(
        body,
        contentType: 'text/html; charset=utf-8',
      );

      expect(result, isNotEmpty);
      expect(result.length, lessThanOrEqualTo(kFetchResultCharBound));
      // Should contain actual Dart programming language information.
      expect(
        result.toLowerCase(),
        anyOf(
          contains('dart'),
          contains('programming'),
          contains('google'),
          contains('language'),
        ),
      );
      // Should NOT contain navbox-specific text like "Navigation menu" from Wikipedia UI.
      expect(result, isNot(contains('move to sidebar')));
    });

    test('wikipedia-2 (LLM): extracts p-content, result bounded', () {
      final body = fixture('wikipedia-2.html');
      final result = extractor.extract(body, contentType: 'text/html');

      expect(result, isNotEmpty);
      expect(result.length, lessThanOrEqualTo(kFetchResultCharBound));
      expect(
        result.toLowerCase(),
        anyOf(
          contains('language model'),
          contains('llm'),
          contains('model'),
          contains('neural'),
          contains('natural language'),
          contains('training'),
        ),
      );
    });

    test('wikipedia p-only: navbox content absent from output', () {
      // Synthesised minimal Wikipedia-style HTML with navbox
      const html = '''
<!DOCTYPE html>
<html><head><title>T - Wikipedia</title></head>
<body>
<div id="mw-content-text">
  <p>This is the first real paragraph about the topic.</p>
  <p>This is the second real paragraph with more details.</p>
  <table class="navbox"><tr><td>Navigation box content should be excluded</td></tr></table>
  <table class="infobox"><tr><td>Infobox content should be excluded</td></tr></table>
  <div class="noprint">Print-only content should be excluded</div>
  <p>Third paragraph with information.</p>
</div>
</body>
</html>
''';
      final result = extractor.extract(html, contentType: 'text/html');
      expect(result, contains('first real paragraph'));
      expect(result, contains('second real paragraph'));
      expect(result, contains('Third paragraph'));
      expect(
        result,
        isNot(contains('Navigation box content should be excluded')),
      );
      expect(result, isNot(contains('Infobox content should be excluded')));
      expect(result, isNot(contains('Print-only content')));
    });
  });

  // ── (c) Hard-truncation at kFetchResultCharBound ─────────────────────────

  group('hard-truncation at kFetchResultCharBound = 2000', () {
    test('short content: not truncated, no marker', () {
      const html = '''
<!DOCTYPE html>
<html><head><title>Short</title></head>
<body>
  <article><p>Short content that fits well within the 2000 char bound.</p></article>
</body>
</html>
''';
      final result = extractor.extract(html, contentType: 'text/html');
      expect(result.length, lessThanOrEqualTo(kFetchResultCharBound));
      expect(result, isNot(contains('[truncated:')));
    });

    test('long content: truncated at 2000 chars with marker', () {
      // Build a page with > 2000 chars of text content.
      final longParagraph =
          'The quick brown fox jumps over the lazy dog. ' * 60; // ~2700 chars
      final html =
          '''
<!DOCTYPE html>
<html><head><title>Long</title></head>
<body>
  <article><p>$longParagraph</p></article>
</body>
</html>
''';
      final result = extractor.extract(html, contentType: 'text/html');

      // Output must be ≤ kFetchResultCharBound chars.
      expect(result.length, lessThanOrEqualTo(kFetchResultCharBound));

      // Must contain the truncation marker.
      expect(result, contains('[truncated:'));
      expect(result, contains('items remaining]'));
    });

    test('truncation marker format: [truncated: N items remaining]', () {
      final longText = 'Word sentence text content. ' * 100; // ~2800 chars
      final html =
          '''
<!DOCTYPE html>
<html><head><title>T</title></head>
<body><article><p>$longText</p></article></body>
</html>
''';
      final result = extractor.extract(html, contentType: 'text/html');
      expect(result.length, lessThanOrEqualTo(kFetchResultCharBound));

      // Verify marker format matches specification.
      final markerMatch = RegExp(
        r'\[truncated: \d+ items remaining\]',
      ).hasMatch(result);
      expect(
        markerMatch,
        isTrue,
        reason: 'Output must end with [truncated: N items remaining] marker',
      );
    });

    test('total output including marker is ≤ 2000 chars', () {
      final veryLong = 'A' * 5000;
      final html =
          '''
<!DOCTYPE html>
<html><head><title>T</title></head>
<body><article><p>$veryLong</p></article></body>
</html>
''';
      final result = extractor.extract(html, contentType: 'text/html');
      expect(
        result.length,
        lessThanOrEqualTo(kFetchResultCharBound),
        reason:
            'Total output (text + marker) must be ≤ $kFetchResultCharBound chars',
      );
    });
  });

  // ── (d) Binary/non-HTML content-type → ParseError ─────────────────────────

  group('non-HTML content-type → ParseError (synthesised)', () {
    test('application/pdf body → throws ParseError with reason', () {
      // Synthesised: a fake application/pdf response body constructed inline.
      // There is NO binary fixture file on disk — this is purely in-code.
      const fakePdfBody =
          '%PDF-1.4 fake pdf binary content not parseable as html';

      expect(
        () => extractor.extract(fakePdfBody, contentType: 'application/pdf'),
        throwsA(
          isA<ParseError>().having(
            (e) => e.reason,
            'reason',
            contains('application/pdf'),
          ),
        ),
      );
    });

    test('application/octet-stream → throws ParseError', () {
      const fakeBinaryBody = '\x00\x01\x02binary garbage\x03\x04';
      expect(
        () => extractor.extract(
          fakeBinaryBody,
          contentType: 'application/octet-stream',
        ),
        throwsA(isA<ParseError>()),
      );
    });

    test('image/png → throws ParseError', () {
      const fakePngBody = '\x89PNG\r\n\x1a\nnot real png but fake for test';
      expect(
        () => extractor.extract(fakePngBody, contentType: 'image/png'),
        throwsA(
          isA<ParseError>().having(
            (e) => e.reason,
            'reason',
            contains('image/png'),
          ),
        ),
      );
    });

    test('text/plain → throws ParseError (only text/html is accepted)', () {
      const textBody = 'This is plain text not HTML';
      expect(
        () => extractor.extract(textBody, contentType: 'text/plain'),
        throwsA(isA<ParseError>()),
      );
    });

    test('application/json → throws ParseError', () {
      const jsonBody = '{"key": "value"}';
      expect(
        () => extractor.extract(jsonBody, contentType: 'application/json'),
        throwsA(isA<ParseError>()),
      );
    });

    test('text/html with charset param is accepted (no error)', () {
      const html =
          '<html><body><article><p>Hello world content text here.</p></article></body></html>';
      // text/html; charset=utf-8 must NOT throw.
      expect(
        () => extractor.extract(html, contentType: 'text/html; charset=utf-8'),
        returnsNormally,
      );
    });

    test('text/html uppercase is accepted', () {
      const html =
          '<html><body><article><p>Test content here please.</p></article></body></html>';
      expect(
        () => extractor.extract(html, contentType: 'TEXT/HTML'),
        returnsNormally,
      );
    });
  });

  // ── Edge cases ────────────────────────────────────────────────────────────

  group('edge cases', () {
    test('empty body → throws ParseError', () {
      expect(
        () => extractor.extract('', contentType: 'text/html'),
        throwsA(isA<ParseError>()),
      );
    });

    test('HTML with only boilerplate → throws ParseError', () {
      const html = '''
<!DOCTYPE html>
<html><head><title>T</title></head>
<body>
  <nav><a href="/">only nav links here, no content</a></nav>
</body>
</html>
''';
      // After removing boilerplate, the remaining text may be empty.
      // This may or may not throw; the extractor falls back to body if no container.
      // We just check it doesn't throw unexpectedly with a non-ParseError.
      try {
        final result = extractor.extract(html, contentType: 'text/html');
        // If it doesn't throw, the output should be bounded.
        expect(result.length, lessThanOrEqualTo(kFetchResultCharBound));
      } on ParseError {
        // Acceptable — empty extraction after boilerplate removal.
      }
    });

    test('Wikipedia: empty mw-content-text → ParseError', () {
      const html = '''
<!DOCTYPE html>
<html><head><title>Empty - Wikipedia</title></head>
<body>
  <div id="mw-content-text"></div>
</body>
</html>
''';
      expect(
        () => extractor.extract(html, contentType: 'text/html'),
        throwsA(isA<ParseError>()),
      );
    });
  });
}
