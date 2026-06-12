import 'package:ai_assistant/core/tools/schema_validator.dart';
import 'package:ai_assistant/core/tools/tool_registry.dart';
import 'package:ai_assistant/domain/entities/tool_spec.dart';
import 'package:flutter_test/flutter_test.dart';

/// 004/005 contract tool_registry_dispatcher.md, invariants 1–4 — registry sanity. The registry
/// can never ship a schema the validator can't enforce, names are stable/unique, descriptions
/// carry the model-facing constraints, and `kind` is set on all six. The three list views
/// (deviceTools / memoryTools / specs) must be internally consistent.
void main() {
  const validator = SchemaValidator();
  final snakeCase = RegExp(r'^[a-z][a-z0-9_]*$');

  // ---------------------------------------------------------------------------
  // List-view consistency
  // ---------------------------------------------------------------------------

  test('deviceTools contains exactly four entries (004 scope)', () {
    expect(ToolRegistry.deviceTools, hasLength(4));
  });

  test('memoryTools contains exactly two entries (005 scope)', () {
    expect(ToolRegistry.memoryTools, hasLength(2));
  });

  test('specs = deviceTools + memoryTools — exactly six entries', () {
    expect(ToolRegistry.specs, hasLength(6));
    expect(
      ToolRegistry.specs,
      containsAllInOrder([
        ...ToolRegistry.deviceTools,
        ...ToolRegistry.memoryTools,
      ]),
    );
  });

  test(
    'deviceTools and memoryTools share no names (no cross-group duplicates)',
    () {
      final deviceNames = ToolRegistry.deviceTools.map((s) => s.name).toSet();
      final memoryNames = ToolRegistry.memoryTools.map((s) => s.name).toSet();
      expect(deviceNames.intersection(memoryNames), isEmpty);
    },
  );

  // ---------------------------------------------------------------------------
  // Invariant 1 — names are unique and snake_case across ALL specs
  // ---------------------------------------------------------------------------

  test('invariant 1 — names are unique and snake_case', () {
    final names = ToolRegistry.specs.map((s) => s.name).toList();
    expect(
      names.toSet(),
      hasLength(names.length),
      reason: 'names must be unique',
    );
    for (final name in names) {
      expect(
        snakeCase.hasMatch(name),
        isTrue,
        reason: '$name must be snake_case',
      );
    }
  });

  // ---------------------------------------------------------------------------
  // Invariant 2 — every parameters schema self-validates against the subset
  // (incl. the maxLength keyword added in T012 for remember_fact.fact)
  // ---------------------------------------------------------------------------

  test('invariant 2 — every parameters schema self-validates against the subset', () {
    // Each schema must itself be a well-formed object schema the validator understands: validating
    // empty args against it must not blow up on an unsupported construct. We assert the schema is
    // an object root and that an empty-arg validation either passes or fails ONLY on a
    // missing-required reason (never on an "unsupported type/construct" reason).
    for (final spec in ToolRegistry.specs) {
      expect(
        spec.parameters['type'],
        'object',
        reason: '${spec.name} root must be object',
      );
      final result = validator.validate(
        spec.parameters,
        const <String, Object?>{},
      );
      if (result is InvalidT) {
        expect(
          result.reason,
          contains('required'),
          reason:
              '${spec.name}: empty-arg failure must be missing-required, not a bad schema '
              '(${result.reason})',
        );
      }
      // Every declared property must use a supported type or an enum.
      final props = (spec.parameters['properties'] as Map)
          .cast<String, Object?>();
      for (final entry in props.entries) {
        final propSchema = (entry.value as Map).cast<String, Object?>();
        final type = propSchema['type'];
        final hasEnum = propSchema.containsKey('enum');
        expect(
          hasEnum ||
              const ['string', 'integer', 'number', 'boolean'].contains(type),
          isTrue,
          reason:
              '${spec.name}.${entry.key} uses an unsupported schema construct',
        );
      }
    }
  });

  test('remember_fact.fact schema includes maxLength:80 (T012 keyword)', () {
    final spec = ToolRegistry.byName('remember_fact')!;
    final props = (spec.parameters['properties'] as Map)
        .cast<String, Object?>();
    final factSchema = (props['fact']! as Map).cast<String, Object?>();
    expect(
      factSchema['maxLength'],
      80,
      reason: 'fact must be capped at 80 chars by schema',
    );
  });

  test('remember_fact.fact maxLength is enforced by SchemaValidator', () {
    final spec = ToolRegistry.byName('remember_fact')!;
    // exactly 80 chars — valid
    final exactly80 = 'x' * 80;
    expect(
      validator.validate(spec.parameters, {
        'fact': exactly80,
        'category': 'identity',
      }).isValid,
      isTrue,
    );
    // 81 chars — invalid
    final over80 = 'x' * 81;
    final result = validator.validate(spec.parameters, {
      'fact': over80,
      'category': 'identity',
    });
    expect(result.isValid, isFalse);
    expect((result as InvalidT).reason, contains('80'));
  });

  // ---------------------------------------------------------------------------
  // Invariant 3 — descriptions are non-empty
  // ---------------------------------------------------------------------------

  test('invariant 3 — descriptions are non-empty', () {
    for (final spec in ToolRegistry.specs) {
      expect(
        spec.description.trim(),
        isNotEmpty,
        reason: '${spec.name} needs a description',
      );
    }
  });

  // ---------------------------------------------------------------------------
  // Invariant 4 — kind is set; read-only vs state-changing split is correct
  // ---------------------------------------------------------------------------

  test('invariant 4 — kind is set; device tools split (004)', () {
    expect(ToolRegistry.byName('get_device_info')!.kind, ToolKind.readOnly);
    expect(ToolRegistry.byName('summarize_clipboard')!.kind, ToolKind.readOnly);
    expect(ToolRegistry.byName('set_theme')!.kind, ToolKind.stateChanging);
    expect(ToolRegistry.byName('set_timer')!.kind, ToolKind.stateChanging);
  });

  test('invariant 4 — memory tools are both stateChanging (005)', () {
    expect(ToolRegistry.byName('remember_fact')!.kind, ToolKind.stateChanging);
    expect(ToolRegistry.byName('forget_fact')!.kind, ToolKind.stateChanging);
  });

  test('every tool has kind set (no null/default confusion)', () {
    for (final spec in ToolRegistry.specs) {
      // Dart enums are never null; this asserts the field is actually assigned.
      expect(spec.kind, isNotNull, reason: '${spec.name} must have kind set');
    }
  });

  // ---------------------------------------------------------------------------
  // byName covers the full specs list
  // ---------------------------------------------------------------------------

  test('byName resolves all six tools by name', () {
    for (final spec in ToolRegistry.specs) {
      expect(
        ToolRegistry.byName(spec.name),
        same(spec),
        reason: 'byName should resolve ${spec.name}',
      );
    }
  });

  test('byName returns null for a hallucinated name', () {
    expect(ToolRegistry.byName('launch_rocket'), isNull);
    expect(
      ToolRegistry.byName('remember_facts'),
      isNull, // near-miss — still null
      reason: 'byName must be exact',
    );
  });

  // ---------------------------------------------------------------------------
  // Result char bounds (device tools)
  // ---------------------------------------------------------------------------

  test('clipboard carries the larger result bound; others use the default', () {
    expect(
      ToolRegistry.byName('summarize_clipboard')!.resultCharBound,
      ToolSpec.clipboardResultCharBound,
    );
    expect(
      ToolRegistry.byName('get_device_info')!.resultCharBound,
      ToolSpec.defaultResultCharBound,
    );
  });

  // ---------------------------------------------------------------------------
  // System instruction
  // ---------------------------------------------------------------------------

  test('the tool-use system instruction is present and lowercase (R6)', () {
    expect(ToolRegistry.systemInstruction.trim(), isNotEmpty);
    expect(
      ToolRegistry.systemInstruction,
      ToolRegistry.systemInstruction.toLowerCase(),
    );
  });

  // ---------------------------------------------------------------------------
  // Schema spot-checks for the two new memory tools
  // ---------------------------------------------------------------------------

  test(
    'remember_fact schema: fact (string, required) + category (enum, required)',
    () {
      final spec = ToolRegistry.byName('remember_fact')!;
      final params = spec.parameters;
      expect(params['required'], containsAll(<String>['fact', 'category']));

      final props = (params['properties'] as Map).cast<String, Object?>();
      final factSchema = (props['fact']! as Map).cast<String, Object?>();
      expect(factSchema['type'], 'string');
      expect(factSchema['maxLength'], 80);

      final catSchema = (props['category']! as Map).cast<String, Object?>();
      expect(
        catSchema['enum'],
        containsAll(<String>['identity', 'work', 'preferences', 'other']),
      );
    },
  );

  test('forget_fact schema: id (integer, minimum 1, required)', () {
    final spec = ToolRegistry.byName('forget_fact')!;
    final params = spec.parameters;
    expect(params['required'], contains('id'));

    final props = (params['properties'] as Map).cast<String, Object?>();
    final idSchema = (props['id']! as Map).cast<String, Object?>();
    expect(idSchema['type'], 'integer');
    expect(idSchema['minimum'], 1);
  });

  test('forget_fact schema: validator rejects id < 1', () {
    final spec = ToolRegistry.byName('forget_fact')!;
    final result = validator.validate(spec.parameters, {'id': 0});
    expect(result.isValid, isFalse);
    expect((result as InvalidT).reason, contains('1'));
  });

  test('forget_fact schema: validator accepts a valid id', () {
    final spec = ToolRegistry.byName('forget_fact')!;
    expect(validator.validate(spec.parameters, {'id': 42}).isValid, isTrue);
  });

  test(
    'remember_fact schema: validator rejects an invalid category enum value',
    () {
      final spec = ToolRegistry.byName('remember_fact')!;
      final result = validator.validate(spec.parameters, {
        'fact': 'prefers dark mode',
        'category': 'hobbies',
      });
      expect(result.isValid, isFalse);
      expect((result as InvalidT).reason, contains('category'));
    },
  );

  test(
    'remember_fact schema: validator accepts valid args for all four categories',
    () {
      final spec = ToolRegistry.byName('remember_fact')!;
      for (final cat in <String>['identity', 'work', 'preferences', 'other']) {
        expect(
          validator.validate(spec.parameters, {
            'fact': 'some fact',
            'category': cat,
          }).isValid,
          isTrue,
          reason: 'category "$cat" should be valid',
        );
      }
    },
  );
}
