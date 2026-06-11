import 'package:meta/meta.dart';

/// Result of [SchemaValidator.validate]: either valid, or invalid with the FIRST human-readable
/// failure reason (the dispatcher maps that reason onto `ToolInvalidArgs`, surfaced on the chip).
@immutable
sealed class ValidationResult {
  const ValidationResult();

  const factory ValidationResult.valid() = ValidT;
  const factory ValidationResult.invalid(String reason) = InvalidT;

  bool get isValid => this is ValidT;
}

@immutable
final class ValidT extends ValidationResult {
  const ValidT();
}

@immutable
final class InvalidT extends ValidationResult {
  const InvalidT(this.reason);
  final String reason;
}

/// A pure, in-house JSON-schema-SUBSET validator (research R3) — no dependency, ~the six fields
/// the four v1 tools actually use. Plugin-free, lives in `lib/core/tools/`.
///
/// Supported subset:
///  * root `type: object` with `properties` (a map of name → property schema) and optional
///    `required` (a list of property names);
///  * primitive property types `string | integer | number | boolean`;
///  * `enum` (a closed list of allowed values) on a property;
///  * integer `minimum` / `maximum` bounds (inclusive).
///
/// **Strict mode**: unknown argument keys are REJECTED (a hallucinated argument is a model error
/// the chip should surface, not silently drop — R3). Anything in a *schema* outside this subset is
/// a registry-sanity test failure (the registry can never ship a schema this can't enforce), not a
/// runtime surprise — but the validator degrades safely (reports the unsupported construct) rather
/// than throwing if it ever sees one.
class SchemaValidator {
  const SchemaValidator();

  ValidationResult validate(Map<String, Object?> schema, Map<String, Object?> args) {
    if (schema['type'] != 'object') {
      return const ValidationResult.invalid('schema root must be type: object');
    }

    final properties = (schema['properties'] as Map?)?.cast<String, Object?>() ??
        const <String, Object?>{};
    final required = (schema['required'] as List?)?.cast<String>() ?? const <String>[];

    // Strict: every supplied key must be a declared property (R3 — unknown keys surface, never
    // silently dropped).
    for (final key in args.keys) {
      if (!properties.containsKey(key)) {
        return ValidationResult.invalid('unknown argument: $key');
      }
    }

    // Every required property must be present.
    for (final name in required) {
      if (!args.containsKey(name)) {
        return ValidationResult.invalid('missing required argument: $name');
      }
    }

    // Validate each supplied property against its declared schema.
    for (final entry in args.entries) {
      final propSchema = (properties[entry.key] as Map?)?.cast<String, Object?>();
      if (propSchema == null) {
        return ValidationResult.invalid('argument ${entry.key} has no schema');
      }
      final result = _validateProperty(entry.key, propSchema, entry.value);
      if (!result.isValid) return result;
    }

    return const ValidationResult.valid();
  }

  ValidationResult _validateProperty(
    String name,
    Map<String, Object?> propSchema,
    Object? value,
  ) {
    // `enum` is a closed allowed-value list; it takes precedence over the bare type check.
    final allowed = (propSchema['enum'] as List?);
    if (allowed != null && !allowed.contains(value)) {
      return ValidationResult.invalid(
        'argument $name must be one of ${allowed.join(', ')}',
      );
    }

    final type = propSchema['type'] as String?;
    switch (type) {
      case 'string':
        if (value is! String) {
          return ValidationResult.invalid('argument $name must be a string');
        }
      case 'boolean':
        if (value is! bool) {
          return ValidationResult.invalid('argument $name must be a boolean');
        }
      case 'integer':
        // Dart/JSON: an integer arrives as `int`; reject doubles even with a zero fraction so the
        // bound checks below operate on a true integer.
        if (value is! int) {
          return ValidationResult.invalid('argument $name must be an integer');
        }
        final min = propSchema['minimum'];
        if (min is int && value < min) {
          return ValidationResult.invalid('argument $name must be ≥ $min');
        }
        final max = propSchema['maximum'];
        if (max is int && value > max) {
          return ValidationResult.invalid('argument $name must be ≤ $max');
        }
      case 'number':
        if (value is! num) {
          return ValidationResult.invalid('argument $name must be a number');
        }
      case null:
        // No type and no enum: nothing to assert (enum-only properties already checked above).
        if (allowed == null) {
          return ValidationResult.invalid('argument $name has no type or enum in its schema');
        }
      default:
        return ValidationResult.invalid('argument $name has unsupported type: $type');
    }

    return const ValidationResult.valid();
  }
}
