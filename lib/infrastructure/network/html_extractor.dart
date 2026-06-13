import 'package:ai_assistant/infrastructure/network/network_constants.dart';
import 'package:ai_assistant/infrastructure/network/research_errors.dart';
import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;

/// Extracts readable text from raw HTML for the `fetch_page` tool (006, T023).
///
/// Priority order for content container selection:
///   1. `<article>` elements
///   2. `<main>` element
///   3. Element with `role="main"` attribute
///   4. Class/id heuristics (`#content`, `#main`, `.content`, `.post`, `.article`, `.entry`)
///   5. `<body>` fallback
///
/// Special rules:
/// - **Wikipedia**: `#mw-content-text` → `p`-only extraction (no navboxes/infoboxes/tables).
/// - **Link-density guard**: any candidate with a link-to-text ratio ≥ 0.7 is skipped.
/// - **Boilerplate removal**: strips `<nav>`, `<header>`, `<footer>`, `<aside>`, `<script>`,
///   `<style>`, `<noscript>`, `.navbox`, `.infobox`, `.mw-editsection`, `.references`,
///   `.noprint`, `#toc` before extraction.
/// - **Token ceiling**: internally limits extraction to [kMaxExtractedTokens] tokens.
/// - **Char bound**: hard-truncates final output to [kFetchResultCharBound] with a marker.
///
/// This file is the ONLY file in the codebase permitted to import `package:html`
/// (enforced by `check_plugin_seam.sh` / `check_network_seam.sh`, Principle VII).
class HtmlExtractor {
  const HtmlExtractor();

  /// Extract readable text from [body] (raw HTML bytes as a String), where [contentType]
  /// is the MIME type from the HTTP `Content-Type` header (e.g. `text/html; charset=utf-8`).
  ///
  /// Returns the extracted and truncated text, or throws [ParseError] if:
  /// - [contentType] is not `text/html` (e.g. `application/pdf`), OR
  /// - extraction produces no usable content.
  String extract(String body, {required String contentType}) {
    // ── 1. Content-type guard ─────────────────────────────────────────────────
    final ct = contentType.toLowerCase().split(';').first.trim();
    if (!ct.startsWith('text/html')) {
      throw ParseError(reason: 'non-HTML content-type: $ct');
    }

    // ── 2. Parse HTML ─────────────────────────────────────────────────────────
    final doc = html_parser.parse(body);

    // ── 3. Detect Wikipedia (mw-content-text present) ─────────────────────────
    final mwContent = doc.querySelector('#mw-content-text');
    if (mwContent != null) {
      return _extractWikipedia(mwContent);
    }

    // ── 4. Remove boilerplate globally ────────────────────────────────────────
    _removeBoilerplate(doc);

    // ── 5. Select content container by priority order ─────────────────────────
    final candidate = _selectContainer(doc);

    // ── 6. Extract text ───────────────────────────────────────────────────────
    final raw = _extractText(candidate);

    if (raw.trim().isEmpty) {
      throw const ParseError(reason: 'extraction produced no usable content');
    }

    // ── 7. Apply token ceiling then char bound ────────────────────────────────
    return _applyBounds(raw);
  }

  // ── Wikipedia p-only extraction ───────────────────────────────────────────

  String _extractWikipedia(Element mwContent) {
    // Remove known boilerplate within the content area (mutates mwContent in place).
    for (final sel in _boilerplateSelectors) {
      for (final el in mwContent.querySelectorAll(sel)) {
        el.remove();
      }
    }

    // Extract only <p> elements (no navboxes, infoboxes, tables).
    final paragraphs = mwContent
        .querySelectorAll('p')
        .map((p) => p.text.trim())
        .where((t) => t.isNotEmpty)
        .toList();

    if (paragraphs.isEmpty) {
      throw const ParseError(reason: 'extraction produced no usable content');
    }

    final raw = paragraphs.join('\n\n');
    return _applyBounds(raw);
  }

  // ── Boilerplate removal ───────────────────────────────────────────────────

  static const List<String> _boilerplateSelectors = [
    'nav',
    'header',
    'footer',
    'aside',
    'script',
    'style',
    'noscript',
    '.navbox',
    '.infobox',
    '.mw-editsection',
    '.references',
    '.noprint',
    '#toc',
    '.toc',
    // Wikipedia-specific
    '.reflist',
    '.mw-references-wrap',
    'table.infobox',
    'table.navbox',
    '.sistersitebox',
    '.ambox',
    '.hatnote',
  ];

  void _removeBoilerplate(Document doc) {
    for (final sel in _boilerplateSelectors) {
      for (final el in doc.querySelectorAll(sel)) {
        el.remove();
      }
    }
  }

  // ── Container selection by priority order ─────────────────────────────────

  Element _selectContainer(Document doc) {
    final body = doc.body;

    // Priority 1: <article>
    final articles = doc.querySelectorAll('article');
    for (final el in articles) {
      if (!_isHighLinkDensity(el)) return el;
    }

    // Priority 2: <main>
    final main = doc.querySelector('main');
    if (main != null && !_isHighLinkDensity(main)) return main;

    // Priority 3: [role="main"]
    final roleMain = doc.querySelector('[role="main"]');
    if (roleMain != null && !_isHighLinkDensity(roleMain)) return roleMain;

    // Priority 4: class/id heuristics
    const heuristics = [
      '#content',
      '#main',
      '#main-content',
      '.content',
      '.post',
      '.article',
      '.entry',
      '.post-content',
      '.article-body',
      '.entry-content',
      '#bodyContent', // MediaWiki
    ];
    for (final sel in heuristics) {
      final el = doc.querySelector(sel);
      if (el != null && !_isHighLinkDensity(el)) return el;
    }

    // Priority 5: body fallback
    return body ?? doc.documentElement ?? doc.querySelector('*')!;
  }

  // ── Link-density guard ────────────────────────────────────────────────────

  bool _isHighLinkDensity(Element el) {
    final allText = el.text.trim();
    if (allText.isEmpty) return true;

    // Sum text of all <a> children.
    final linkText = el
        .querySelectorAll('a')
        .map((a) => a.text.trim())
        .join(' ');

    final ratio = linkText.length / allText.length;
    return ratio >= 0.7;
  }

  // ── Text extraction ───────────────────────────────────────────────────────

  String _extractText(Element el) {
    // Walk block-level elements and collect non-empty text chunks.
    // We use the element's innerText (collapsing whitespace).
    final buffer = StringBuffer();

    void visit(Node node) {
      if (node is Element) {
        final tag = node.localName?.toLowerCase() ?? '';
        // Skip invisible elements.
        if (const {
          'script',
          'style',
          'noscript',
          'svg',
          'img',
          'video',
          'audio',
          'iframe',
        }.contains(tag)) {
          return;
        }
        for (final child in node.nodes) {
          visit(child);
        }
        // Add paragraph break after block elements.
        if (const {
          'p',
          'div',
          'section',
          'h1',
          'h2',
          'h3',
          'h4',
          'h5',
          'h6',
          'li',
          'blockquote',
          'pre',
          'td',
          'th',
          'tr',
          'br',
          'hr',
        }.contains(tag)) {
          buffer.write('\n');
        }
      } else if (node is Text) {
        final t = node.text;
        if (t.isNotEmpty) buffer.write(t);
      }
    }

    visit(el);

    // Collapse repeated whitespace / blank lines.
    final text = buffer
        .toString()
        .replaceAll(RegExp(r'[ \t]+'), ' ')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();

    return text;
  }

  // ── Token ceiling + char bound ────────────────────────────────────────────

  String _applyBounds(String raw) {
    // Rough token estimate: ~4 chars/token on average.
    const charsPerToken = 4;
    const tokenCeilingChars =
        kMaxExtractedTokens * charsPerToken; // 16 000 chars

    final String bounded = raw.length > tokenCeilingChars
        ? raw.substring(0, tokenCeilingChars)
        : raw;

    if (bounded.length <= kFetchResultCharBound) {
      return bounded;
    }

    // Hard-truncate at kFetchResultCharBound and append marker.
    // The marker itself must fit within the bound.
    // We calculate the remaining items as approximate remaining chars.
    final remaining = bounded.length - kFetchResultCharBound;
    final marker = '[truncated: $remaining items remaining]';

    // The truncation point must leave room for the marker within 2000 chars.
    // Per spec: output ≤ 2000 chars with marker appended.
    // We truncate at (kFetchResultCharBound - marker.length) then append.
    final truncateAt = kFetchResultCharBound - marker.length;
    if (truncateAt <= 0) {
      // Edge case: marker itself is huge (shouldn't happen in practice).
      return bounded.substring(0, kFetchResultCharBound);
    }

    return '${bounded.substring(0, truncateAt)}$marker';
  }
}
