import 'package:ai_assistant/core/tools/schema_validator.dart';
import 'package:flutter_test/flutter_test.dart';

/// 004 R3 / contract tool_registry_dispatcher.md — the in-house JSON-schema-subset validator.
/// One failure reason asserted per case; strict unknown-key rejection is the load-bearing
/// non-standard behavior (a hallucinated argument must surface, never be silently dropped).
void main() {
  const validator = SchemaValidator();

  // A schema exercising every supported construct: an optional enum string, a required enum
  // string, a bounded integer, an optional plain string.
  const schema = <String, Object?>{
    'type': 'object',
    'properties': <String, Object?>{
      'section': <String, Object?>{
        'type': 'string',
        'enum': <String>['hardware', 'all'],
      },
      'theme': <String, Object?>{
        'type': 'string',
        'enum': <String>['dark', 'light'],
      },
      'seconds': <String, Object?>{
        'type': 'integer',
        'minimum': 1,
        'maximum': 86400,
      },
      'label': <String, Object?>{'type': 'string'},
    },
    'required': <String>['theme'],
  };

  group('valid args', () {
    test('empty args fail when a required field is missing', () {
      final result = validator.validate(schema, const <String, Object?>{});
      expect(result.isValid, isFalse);
    });

    test('only the required field present is valid', () {
      expect(validator.validate(schema, {'theme': 'dark'}).isValid, isTrue);
    });

    test('optional fields present with valid values pass', () {
      final result = validator.validate(schema, {
        'theme': 'light',
        'section': 'all',
        'seconds': 300,
        'label': 'tea',
      });
      expect(result.isValid, isTrue);
    });

    test('empty-properties schema accepts empty args ({} tool)', () {
      const noArgs = <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{},
        'required': <String>[],
      };
      expect(
        validator.validate(noArgs, const <String, Object?>{}).isValid,
        isTrue,
      );
    });
  });

  group('rejections (first reason asserted)', () {
    test('wrong type → not a string', () {
      final result = validator.validate(schema, {'theme': 'dark', 'label': 42});
      expect(result, isA<InvalidT>());
      expect((result as InvalidT).reason, contains('label'));
      expect(result.reason, contains('string'));
    });

    test('unknown key is rejected (strict mode)', () {
      final result = validator.validate(schema, {
        'theme': 'dark',
        'bogus': 'x',
      });
      expect(result, isA<InvalidT>());
      expect((result as InvalidT).reason, contains('bogus'));
    });

    test('enum violation', () {
      final result = validator.validate(schema, {'theme': 'sepia'});
      expect(result, isA<InvalidT>());
      expect((result as InvalidT).reason, contains('theme'));
    });

    test('missing required field', () {
      final result = validator.validate(schema, {'section': 'hardware'});
      expect(result, isA<InvalidT>());
      expect((result as InvalidT).reason, contains('theme'));
    });

    test('integer below minimum', () {
      final result = validator.validate(schema, {
        'theme': 'dark',
        'seconds': 0,
      });
      expect(result, isA<InvalidT>());
      expect((result as InvalidT).reason, contains('seconds'));
    });

    test('integer above maximum', () {
      final result = validator.validate(schema, {
        'theme': 'dark',
        'seconds': 90000,
      });
      expect(result, isA<InvalidT>());
      expect((result as InvalidT).reason, contains('seconds'));
    });

    test('a double is not an integer', () {
      final result = validator.validate(schema, {
        'theme': 'dark',
        'seconds': 1.5,
      });
      expect(result, isA<InvalidT>());
      expect((result as InvalidT).reason, contains('seconds'));
    });

    test('non-object root is rejected', () {
      final result = validator.validate(
        const {'type': 'string'},
        const {'theme': 'dark'},
      );
      expect(result, isA<InvalidT>());
    });
  });

  // ── T012 — maxLength for type:string (R5 memory fact cap) ──────────────────
  group('maxLength', () {
    // A minimal schema with a maxLength-bounded string property.
    const factSchema = <String, Object?>{
      'type': 'object',
      'properties': <String, Object?>{
        'fact': <String, Object?>{'type': 'string', 'maxLength': 80},
      },
      'required': <String>['fact'],
    };

    test('string at exactly maxLength is valid', () {
      final value = 'x' * 80;
      final result = validator.validate(factSchema, {'fact': value});
      expect(result.isValid, isTrue);
    });

    test('string one character over maxLength is invalid', () {
      final value = 'x' * 81;
      final result = validator.validate(factSchema, {'fact': value});
      expect(result, isA<InvalidT>());
      // reason must mention the property name and the limit
      expect((result as InvalidT).reason, contains('fact'));
      expect(result.reason, contains('80'));
    });

    test(
      'maxLength is ignored when value is not a string (type mismatch reported first)',
      () {
        // Non-string triggers the type check before maxLength; no crash.
        const numSchema = <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'count': <String, Object?>{'type': 'string', 'maxLength': 5},
          },
          'required': <String>['count'],
        };
        final result = validator.validate(numSchema, {'count': 42});
        expect(result, isA<InvalidT>());
        expect((result as InvalidT).reason, contains('string'));
      },
    );
  });

  // ── T019 — format:uri keyword (006 web_research_tools.md §SchemaValidator delta) ──────────

  group('format:uri', () {
    // A minimal schema with a url property using format:uri and maxLength.
    const uriSchema = <String, Object?>{
      'type': 'object',
      'properties': <String, Object?>{
        'url': <String, Object?>{
          'type': 'string',
          'format': 'uri',
          'maxLength': 2048,
        },
      },
      'required': <String>['url'],
    };

    // ── Valid cases (must pass) ─────────────────────────────────────────────

    test('valid http URL passes', () {
      final result = validator.validate(uriSchema, {
        'url': 'http://example.com',
      });
      expect(result.isValid, isTrue);
    });

    test('valid https URL passes', () {
      final result = validator.validate(uriSchema, {
        'url': 'https://flutter.dev/docs',
      });
      expect(result.isValid, isTrue);
    });

    test('https URL with path and query passes', () {
      final result = validator.validate(uriSchema, {
        'url':
            'https://en.wikipedia.org/wiki/Dart_(programming_language)?foo=bar',
      });
      expect(result.isValid, isTrue);
    });

    // ── Invalid cases — "not a valid URI" ───────────────────────────────────

    test('plain text (no scheme) fails with "not a valid URI"', () {
      final result = validator.validate(uriSchema, {'url': 'not a url at all'});
      expect(result, isA<InvalidT>());
      expect((result as InvalidT).reason, contains('not a valid URI'));
    });

    test('URI with no scheme fails with "not a valid URI"', () {
      // Missing scheme — Uri.tryParse returns a relative URI (hasScheme=false).
      final result = validator.validate(uriSchema, {
        'url': '//example.com/path',
      });
      expect(result, isA<InvalidT>());
      expect((result as InvalidT).reason, contains('not a valid URI'));
    });

    test('URI with no authority fails with "not a valid URI"', () {
      // A URI like "data:text/plain" has a scheme but no authority.
      final result = validator.validate(uriSchema, {
        'url': 'data:text/plain;base64,abc123',
      });
      expect(result, isA<InvalidT>());
      expect((result as InvalidT).reason, contains('not a valid URI'));
    });

    test('empty string fails with "not a valid URI"', () {
      final result = validator.validate(uriSchema, {'url': ''});
      expect(result, isA<InvalidT>());
      expect((result as InvalidT).reason, contains('not a valid URI'));
    });

    // ── Scheme allowlist is a SEPARATE step — format:uri does NOT reject ftp://
    // The dispatcher applies the http/https check; format:uri only checks structural validity.
    // This test confirms the separation: ftp:// passes format:uri (structure valid).
    test(
      'ftp:// URI passes format:uri (scheme allowlist is a separate step)',
      () {
        final result = validator.validate(uriSchema, {
          'url': 'ftp://files.example.com/data.zip',
        });
        // format:uri passes — structural check is valid; scheme allowlist is NOT part of format.
        expect(result.isValid, isTrue);
      },
    );

    // ── maxLength on url ────────────────────────────────────────────────────

    test('url at exactly maxLength 2048 passes', () {
      // Construct a valid https URL that is exactly 2048 chars.
      const base = 'https://example.com/';
      final padding = 'a' * (2048 - base.length);
      final url = '$base$padding';
      expect(url.length, 2048);
      final result = validator.validate(uriSchema, {'url': url});
      expect(result.isValid, isTrue);
    });

    test('url one character over maxLength 2048 fails', () {
      const base = 'https://example.com/';
      final padding = 'a' * (2049 - base.length);
      final url = '$base$padding';
      expect(url.length, 2049);
      final result = validator.validate(uriSchema, {'url': url});
      expect(result, isA<InvalidT>());
      // maxLength check fires before format:uri check (order: type → maxLength → format).
      expect((result as InvalidT).reason, contains('2048'));
    });

    // ── Existing tests still pass (regression) ──────────────────────────────

    test(
      'format:uri does not affect non-uri schemas (existing tests unaffected)',
      () {
        // The original schema has no format:uri — should behave exactly as before.
        expect(validator.validate(schema, {'theme': 'dark'}).isValid, isTrue);
        expect(validator.validate(schema, {}).isValid, isFalse);
      },
    );
  });
}
