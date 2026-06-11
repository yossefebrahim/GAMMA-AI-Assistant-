import 'package:ai_assistant/infrastructure/gemma/leak_filter.dart';
import 'package:flutter_test/flutter_test.dart';

/// 004 R1 / contract guarantee 20 — the chunk-granularity raw-JSON suppression, against the
/// spike's captured leak shapes (spike §3). Drives the filter chunk-by-chunk and asserts what
/// reaches the text channel under each terminator.
void main() {
  // The verbatim leak shape the spike captured on the device (the raw SDK tool_calls JSON).
  const leak =
      '{"role":"assistant","tool_calls":[{"type":"function","function":{"name":"get_device_info","arguments":{}}}]}';

  String emit(LeakFilter f, Iterable<String> chunks) {
    final out = StringBuffer();
    for (final c in chunks) {
      out.write(f.process(c));
    }
    return out.toString();
  }

  test('pure-JSON call turn: everything withheld then discarded (nothing emitted)', () {
    final f = LeakFilter();
    final emitted = emit(f, [leak]);
    expect(emitted, isEmpty);
    expect(f.isWithholding, isTrue);
    f.discardOnToolCall();
  });

  test('prose-only turn: all flushed, nothing withheld', () {
    final f = LeakFilter();
    final emitted = emit(f, ['the battery ', 'is at ', '83%.']);
    expect(emitted, 'the battery is at 83%.');
    expect(f.flushOnText(), isEmpty);
  });

  test('prose-then-leak-then-call: prose emitted, trailing JSON discarded (the key case)', () {
    final f = LeakFilter();
    final emitted = emit(f, ['let me check. ', leak]);
    expect(emitted, 'let me check. ');
    f.discardOnToolCall(); // turn ended in a tool call → withheld leak dropped
  });

  test('{-prefix false-positive prose: withheld then FLUSHED verbatim at a text-terminated turn', () {
    final f = LeakFilter();
    // A legitimate reply that happens to start with "{" but never becomes a call.
    final emitted = emit(f, ['{not actually json} ', 'here is your answer.']);
    expect(emitted, isEmpty, reason: 'withheld from the {-chunk onward');
    expect(f.flushOnText(), '{not actually json} here is your answer.');
  });

  test('chunk-split JSON: leak spanning multiple chunks is fully withheld', () {
    final f = LeakFilter();
    final emitted = emit(f, ['{"role":"assistant",', '"tool_calls":[', '{"function":{}}]}']);
    expect(emitted, isEmpty);
    f.discardOnToolCall();
  });

  test('leading whitespace before the brace is still detected as a leak start', () {
    final f = LeakFilter();
    final emitted = emit(f, ['   $leak']);
    expect(emitted, isEmpty);
  });

  test('inactive filter (flag off) is a pass-through — byte parity (guarantee 19)', () {
    final f = LeakFilter(active: false);
    final emitted = emit(f, [leak, ' and more']);
    expect(emitted, '$leak and more');
    expect(f.isWithholding, isFalse);
  });
}
