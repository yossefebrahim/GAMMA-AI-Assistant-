import 'package:ai_assistant/core/tools/tool_registry.dart';
import 'package:ai_assistant/domain/entities/tool_outcome.dart';
import 'package:ai_assistant/domain/entities/tool_spec.dart';
import 'package:ai_assistant/domain/services/tool_dispatcher.dart';
import 'package:flutter_test/flutter_test.dart';

/// 004 contract tool_registry_dispatcher.md guarantees 1–5 — the feature brief's named dispatcher
/// unit tests. Uses recording fake handlers so "handler NOT invoked" is assertable, not inferred.
void main() {
  // A recorder that proves whether a handler ran, and what args it saw.
  late Map<String, int> invocations;
  late Map<String, Map<String, Object?>> lastArgs;

  ToolHandler recording(String name, Map<String, Object?> Function(Map<String, Object?>) body) {
    return (args) async {
      invocations[name] = (invocations[name] ?? 0) + 1;
      lastArgs[name] = args;
      return body(args);
    };
  }

  setUp(() {
    invocations = <String, int>{};
    lastArgs = <String, Map<String, Object?>>{};
  });

  ToolDispatcher buildDispatcher({ToolHandler Function(String)? override}) {
    Map<String, ToolHandler> handlers = {
      'get_device_info': recording('get_device_info', (_) => {'model': 'A34', 'battery': 83}),
      'summarize_clipboard':
          recording('summarize_clipboard', (_) => {'text': 'hello clipboard'}),
      'set_theme': recording('set_theme', (a) => {'theme': a['theme'], 'alreadyActive': false}),
      'set_timer': recording('set_timer', (a) => {'seconds': a['seconds'], 'set': true}),
    };
    if (override != null) {
      handlers = {for (final name in handlers.keys) name: override(name)};
    }
    return ToolDispatcher(handlers: handlers);
  }

  test('valid call → ToolSuccess; handler invoked once with the args', () async {
    final outcome = await buildDispatcher().dispatch('set_theme', {'theme': 'dark'});
    expect(outcome, isA<ToolSuccess>());
    expect((outcome as ToolSuccess).result['theme'], 'dark');
    expect(invocations['set_theme'], 1);
    expect(lastArgs['set_theme'], {'theme': 'dark'});
  });

  test('malformed args → ToolInvalidArgs; handler NEVER invoked', () async {
    final outcome = await buildDispatcher().dispatch('set_timer', {'seconds': 0});
    expect(outcome, isA<ToolInvalidArgs>());
    expect((outcome as ToolInvalidArgs).reason, contains('seconds'));
    expect(invocations.containsKey('set_timer'), isFalse, reason: 'handler must not run on bad args');
  });

  test('unknown key → ToolInvalidArgs (strict mode), handler untouched', () async {
    final outcome =
        await buildDispatcher().dispatch('set_theme', {'theme': 'dark', 'mode': 'x'});
    expect(outcome, isA<ToolInvalidArgs>());
    expect(invocations.containsKey('set_theme'), isFalse);
  });

  test('unknown tool → ToolUnknown; handler map never consulted', () async {
    final outcome = await buildDispatcher().dispatch('launch_rocket', const {});
    expect(outcome, isA<ToolUnknown>());
    expect((outcome as ToolUnknown).attemptedName, 'launch_rocket');
    expect(invocations, isEmpty);
  });

  test('handler throw → ToolFailure (dispatch NEVER throws)', () async {
    final dispatcher = buildDispatcher(
      override: (name) => (args) async => throw StateError('boom in $name'),
    );
    final outcome = await dispatcher.dispatch('get_device_info', const {});
    expect(outcome, isA<ToolFailure>());
    expect((outcome as ToolFailure).reason, contains('boom'));
  });

  test('oversized result is truncated with truncated: true (per-tool bound)', () async {
    final huge = 'x' * (ToolSpec.clipboardResultCharBound + 500);
    final dispatcher = ToolDispatcher(handlers: {
      'summarize_clipboard': (_) async => {'text': huge},
    });
    final outcome = await dispatcher.dispatch('summarize_clipboard', const {});
    expect(outcome, isA<ToolSuccess>());
    final success = outcome as ToolSuccess;
    expect(success.truncated, isTrue);
    expect((success.result['text'] as String).length, lessThan(huge.length));
  });

  test('a result within the bound is not marked truncated', () async {
    final outcome = await buildDispatcher().dispatch('get_device_info', const {});
    expect((outcome as ToolSuccess).truncated, isFalse);
  });

  group('integer coercion', () {
    test('whole-valued double → coerced to int, ToolSuccess, handler receives int', () async {
      final outcome = await buildDispatcher().dispatch('set_timer', {'seconds': 300.0});
      expect(outcome, isA<ToolSuccess>());
      expect(lastArgs['set_timer']!['seconds'], 300);
      expect(lastArgs['set_timer']!['seconds'], isA<int>());
    });

    test('fractional double → ToolInvalidArgs; handler not invoked', () async {
      final outcome = await buildDispatcher().dispatch('set_timer', {'seconds': 1.5});
      expect(outcome, isA<ToolInvalidArgs>());
      expect(invocations.containsKey('set_timer'), isFalse);
    });

    test('whole-valued double below minimum → ToolInvalidArgs after coercion', () async {
      final outcome = await buildDispatcher().dispatch('set_timer', {'seconds': 0.0});
      expect(outcome, isA<ToolInvalidArgs>());
      expect((outcome as ToolInvalidArgs).reason, contains('seconds'));
      expect(invocations.containsKey('set_timer'), isFalse);
    });

    test('whole-valued double at upper bound → ToolSuccess', () async {
      final outcome = await buildDispatcher().dispatch('set_timer', {'seconds': 86400.0});
      expect(outcome, isA<ToolSuccess>());
      expect(lastArgs['set_timer']!['seconds'], isA<int>());
    });
  });

  test('guarantee 5 — handler map covers exactly the registry names (congruence)', () {
    final handlers = {
      'get_device_info': (Map<String, Object?> a) async => a,
      'summarize_clipboard': (Map<String, Object?> a) async => a,
      'set_theme': (Map<String, Object?> a) async => a,
      'set_timer': (Map<String, Object?> a) async => a,
    };
    final registryNames = ToolRegistry.specs.map((s) => s.name).toSet();
    expect(handlers.keys.toSet(), registryNames);
  });
}
