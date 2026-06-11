import 'dart:convert';

import 'package:ai_assistant/core/tools/schema_validator.dart';
import 'package:ai_assistant/core/tools/tool_registry.dart';
import 'package:ai_assistant/domain/entities/tool_outcome.dart';

/// A bound tool handler: takes the SCHEMA-VALIDATED args and returns a structured result. May
/// throw — the dispatcher catches and maps any exception to [ToolFailure] (FR-025). Handlers live
/// behind infrastructure services (`lib/infrastructure/tools/`) or the existing theme mechanism;
/// the dispatcher never imports them, only this typedef.
typedef ToolHandler = Future<Map<String, Object?>> Function(Map<String, Object?> validArgs);

/// Maps a model-requested tool call to a typed [ToolOutcome] (004 contract:
/// tool_registry_dispatcher.md). Plugin-free, in `lib/domain/services/`.
///
/// Pipeline, in order (contract guarantee 1 — validation ALWAYS precedes execution):
///   1. registry lookup — `name ∉ registry` → [ToolUnknown] (the handler map is never consulted);
///   2. strict schema validation — failure → [ToolInvalidArgs] (the handler never runs);
///   3. dispatch to the injected handler — its result becomes [ToolSuccess], bounded per the
///      spec's `resultCharBound` (truncating with `truncated: true`); any thrown exception →
///      [ToolFailure] (guarantee 2: `dispatch` NEVER throws).
///
/// No policy lives here (guarantee 4): the one-call-per-turn rule and stop semantics are the
/// controller's; capability gating is the seam's. The dispatcher is a pure mapping.
class ToolDispatcher {
  ToolDispatcher({
    required Map<String, ToolHandler> handlers,
    this.validator = const SchemaValidator(),
  }) : _handlers = handlers;

  final Map<String, ToolHandler> _handlers;
  final SchemaValidator validator;

  Future<ToolOutcome> dispatch(String name, Map<String, Object?> args) async {
    final spec = ToolRegistry.byName(name);
    if (spec == null) {
      // Hallucinated tool (FR-022). Handler map never touched.
      return ToolUnknown(name);
    }

    // Coerce whole-valued doubles → int for integer-typed properties. The model/SDK emits JSON
    // numbers as Dart `double` (e.g. 300.0); JSON has no separate integer type. Fractional values
    // (1.5) are left as-is so the strict validator still rejects them.
    final coerced = _coerceIntegerArgs(spec.parameters, args);

    final validation = validator.validate(spec.parameters, coerced);
    if (validation is InvalidT) {
      // Schema rejection — handler never invoked (FR-023).
      return ToolInvalidArgs(validation.reason);
    }

    final handler = _handlers[name];
    if (handler == null) {
      // The registry declares this tool but no handler is bound — a wiring error, surfaced as a
      // failure rather than a crash. (The congruence sanity test asserts the map covers the
      // registry, so this is defensive.)
      return const ToolFailure('tool not available');
    }

    try {
      final result = await handler(coerced);
      final (bounded, truncated) = _applyBound(result, spec.resultCharBound);
      return ToolSuccess(bounded, truncated: truncated);
    } catch (error) {
      // Typed outcomes only — never let a handler exception escape (guarantee 2).
      return ToolFailure(_reasonOf(error));
    }
  }

  Map<String, Object?> _coerceIntegerArgs(
      Map<String, Object?> schema, Map<String, Object?> args) {
    final properties =
        (schema['properties'] as Map?)?.cast<String, Object?>() ?? const <String, Object?>{};
    final out = Map<String, Object?>.of(args);
    for (final entry in args.entries) {
      final propSchema = (properties[entry.key] as Map?)?.cast<String, Object?>();
      if (propSchema?['type'] != 'integer') continue;
      final v = entry.value;
      if (v is double && v.isFinite && v == v.roundToDouble()) {
        out[entry.key] = v.toInt(); // 300.0 → 300; 1.5 left as double → still rejected
      }
    }
    return out;
  }

  /// Bound the result JSON to [bound] chars (R3, guarantee 3). Truncates the longest string value
  /// first until it fits, marking `truncated`. v1 tools keep their own caps (clipboard 4,000
  /// chars), so this is the belt-and-braces ceiling.
  (Map<String, Object?>, bool) _applyBound(Map<String, Object?> result, int bound) {
    if (jsonEncode(result).length <= bound) return (result, false);
    final bounded = Map<String, Object?>.of(result);
    while (jsonEncode(bounded).length > bound) {
      String? longestKey;
      var longest = -1;
      bounded.forEach((key, value) {
        if (value is String && value.length > longest) {
          longestKey = key;
          longest = value.length;
        }
      });
      if (longestKey == null || longest <= 0) break; // nothing left to shrink
      final overflow = jsonEncode(bounded).length - bound;
      final text = bounded[longestKey] as String;
      final keep = (text.length - overflow - 1).clamp(0, text.length);
      bounded[longestKey!] = '${text.substring(0, keep)}…';
    }
    return (bounded, true);
  }

  String _reasonOf(Object error) {
    final message = error.toString();
    return message.isEmpty ? 'tool failed' : message;
  }
}
