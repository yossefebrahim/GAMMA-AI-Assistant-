import 'package:ai_assistant/domain/entities/tool_outcome.dart';
import 'package:ai_assistant/domain/services/tool_dispatcher.dart';
import 'package:ai_assistant/features/chat/tool_handler_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/container_harness.dart';
import '../../helpers/fake_timer_intent_service.dart';

/// 004 US4 — the set_timer handler fires the intent with the right payload, maps a missing clock
/// app to a structured failure (FR-015), and relies on the schema to reject out-of-bounds durations
/// BEFORE the handler runs (R3). Through the real dispatcher with a fake intent sink.
void main() {
  late FakeTimerIntentService timer;

  ToolDispatcher dispatcher(ProviderContainer c) => c.read(toolDispatcherProvider);

  ProviderContainer build() {
    timer = FakeTimerIntentService();
    return makeContainer(overrides: [
      timerIntentServiceProvider.overrideWithValue(timer),
    ]);
  }

  test('valid duration → fires the intent with seconds + label; success result', () async {
    final c = build();
    addTearDown(c.dispose);
    final outcome =
        await dispatcher(c).dispatch('set_timer', const {'seconds': 300, 'label': 'tea'});

    expect(outcome, isA<ToolSuccess>());
    expect(timer.lastSeconds, 300);
    expect(timer.lastLabel, 'tea');
    expect((outcome as ToolSuccess).result['set'], true);
  });

  test('no clock app → ToolFailure("no clock app available") (FR-015)', () async {
    final c = build();
    addTearDown(c.dispose);
    timer.unavailable = true;

    final outcome = await dispatcher(c).dispatch('set_timer', const {'seconds': 60});
    expect(outcome, isA<ToolFailure>());
    expect((outcome as ToolFailure).reason, 'no clock app available');
  });

  test('zero seconds is rejected by the schema → ToolInvalidArgs, intent never fired (US4/AS3)',
      () async {
    final c = build();
    addTearDown(c.dispose);
    final outcome = await dispatcher(c).dispatch('set_timer', const {'seconds': 0});

    expect(outcome, isA<ToolInvalidArgs>());
    expect(timer.callCount, 0, reason: 'the handler must not run on an out-of-bounds duration');
  });

  test('over-24h is rejected by the schema (1..86400 bound)', () async {
    final c = build();
    addTearDown(c.dispose);
    final outcome = await dispatcher(c).dispatch('set_timer', const {'seconds': 90000});
    expect(outcome, isA<ToolInvalidArgs>());
    expect(timer.callCount, 0);
  });
}
