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
      'seconds': <String, Object?>{'type': 'integer', 'minimum': 1, 'maximum': 86400},
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
      expect(validator.validate(noArgs, const <String, Object?>{}).isValid, isTrue);
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
      final result = validator.validate(schema, {'theme': 'dark', 'bogus': 'x'});
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
      final result = validator.validate(schema, {'theme': 'dark', 'seconds': 0});
      expect(result, isA<InvalidT>());
      expect((result as InvalidT).reason, contains('seconds'));
    });

    test('integer above maximum', () {
      final result = validator.validate(schema, {'theme': 'dark', 'seconds': 90000});
      expect(result, isA<InvalidT>());
      expect((result as InvalidT).reason, contains('seconds'));
    });

    test('a double is not an integer', () {
      final result = validator.validate(schema, {'theme': 'dark', 'seconds': 1.5});
      expect(result, isA<InvalidT>());
      expect((result as InvalidT).reason, contains('seconds'));
    });

    test('non-object root is rejected', () {
      final result =
          validator.validate(const {'type': 'string'}, const {'theme': 'dark'});
      expect(result, isA<InvalidT>());
    });
  });
}
