import 'package:ai_assistant/core/tools/schema_validator.dart';
import 'package:ai_assistant/core/tools/tool_registry.dart';
import 'package:ai_assistant/domain/entities/tool_spec.dart';
import 'package:flutter_test/flutter_test.dart';

/// 004 contract tool_registry_dispatcher.md, invariants 1–4 — registry sanity. The registry can
/// never ship a schema the validator can't enforce, names are stable/unique, descriptions carry
/// the model-facing constraints, and `kind` is set on all four.
void main() {
  const validator = SchemaValidator();
  final snakeCase = RegExp(r'^[a-z][a-z0-9_]*$');

  test('exactly four tools in v1', () {
    expect(ToolRegistry.specs, hasLength(4));
  });

  test('invariant 1 — names are unique and snake_case', () {
    final names = ToolRegistry.specs.map((s) => s.name).toList();
    expect(names.toSet(), hasLength(names.length), reason: 'names must be unique');
    for (final name in names) {
      expect(snakeCase.hasMatch(name), isTrue, reason: '$name must be snake_case');
    }
  });

  test('invariant 2 — every parameters schema self-validates against the subset', () {
    // Each schema must itself be a well-formed object schema the validator understands: validating
    // empty args against it must not blow up on an unsupported construct. We assert the schema is
    // an object root and that an empty-arg validation either passes or fails ONLY on a
    // missing-required reason (never on an "unsupported type/construct" reason).
    for (final spec in ToolRegistry.specs) {
      expect(spec.parameters['type'], 'object', reason: '${spec.name} root must be object');
      final result = validator.validate(spec.parameters, const <String, Object?>{});
      if (result is InvalidT) {
        expect(result.reason, contains('required'),
            reason: '${spec.name}: empty-arg failure must be missing-required, not a bad schema '
                '(${result.reason})');
      }
      // Every declared property must use a supported type or an enum.
      final props =
          (spec.parameters['properties'] as Map).cast<String, Object?>();
      for (final entry in props.entries) {
        final propSchema = (entry.value as Map).cast<String, Object?>();
        final type = propSchema['type'];
        final hasEnum = propSchema.containsKey('enum');
        expect(
          hasEnum || const ['string', 'integer', 'number', 'boolean'].contains(type),
          isTrue,
          reason: '${spec.name}.${entry.key} uses an unsupported schema construct',
        );
      }
    }
  });

  test('invariant 3 — descriptions are non-empty', () {
    for (final spec in ToolRegistry.specs) {
      expect(spec.description.trim(), isNotEmpty, reason: '${spec.name} needs a description');
    }
  });

  test('invariant 4 — kind is set; read-only vs state-changing split is correct', () {
    expect(ToolRegistry.byName('get_device_info')!.kind, ToolKind.readOnly);
    expect(ToolRegistry.byName('summarize_clipboard')!.kind, ToolKind.readOnly);
    expect(ToolRegistry.byName('set_theme')!.kind, ToolKind.stateChanging);
    expect(ToolRegistry.byName('set_timer')!.kind, ToolKind.stateChanging);
  });

  test('byName resolves known tools and returns null for a hallucinated name', () {
    expect(ToolRegistry.byName('set_theme'), isNotNull);
    expect(ToolRegistry.byName('launch_rocket'), isNull);
  });

  test('clipboard carries the larger result bound; others use the default', () {
    expect(ToolRegistry.byName('summarize_clipboard')!.resultCharBound,
        ToolSpec.clipboardResultCharBound);
    expect(ToolRegistry.byName('get_device_info')!.resultCharBound,
        ToolSpec.defaultResultCharBound);
  });

  test('the tool-use system instruction is present and lowercase (R6)', () {
    expect(ToolRegistry.systemInstruction.trim(), isNotEmpty);
    expect(ToolRegistry.systemInstruction, ToolRegistry.systemInstruction.toLowerCase());
  });
}
