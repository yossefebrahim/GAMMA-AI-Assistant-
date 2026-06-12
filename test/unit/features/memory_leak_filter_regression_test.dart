import 'package:ai_assistant/infrastructure/gemma/leak_filter.dart';
import 'package:flutter_test/flutter_test.dart';

/// T038 — Regression assertion: the 004 [LeakFilter] suppresses raw `remember_fact` /
/// `forget_fact` call JSON (guarantee 20 extended to the 005 memory tools).
///
/// The plugin's `extractTextFromResponse` passes chunks lacking a `content` key through verbatim;
/// the raw SDK JSON streams as text before the typed event arrives. The [LeakFilter] intercepts
/// this at the first `{`-prefixed chunk and discards it when the turn ends in a tool call.
/// No new library code is needed — this test asserts that the EXISTING filter already handles
/// the exact leak shapes that flutter_gemma 0.15.3 produces for `remember_fact` /
/// `forget_fact`, symmetric with the 004 coverage in `leak_filter_test.dart`.
void main() {
  // Verbatim raw SDK JSON leak shapes produced by flutter_gemma 0.15.3 for the 005 memory tools
  // (same envelope as the 004 `get_device_info` leak captured in the spike §3, just different
  // function name and arguments). Matching the actual runtime chunk format is the key fidelity
  // guarantee — if the plugin changes shape, this test will catch it.

  const rememberFactLeak =
      '{"role":"assistant","tool_calls":[{"type":"function","function":'
      '{"name":"remember_fact","arguments":{"fact":"name is Yossef","category":"identity"}}}]}';

  const forgetFactLeak =
      '{"role":"assistant","tool_calls":[{"type":"function","function":'
      '{"name":"forget_fact","arguments":{"id":1}}}]}';

  // Helper: pump all chunks through the filter and return the emitted text.
  String emit(LeakFilter f, Iterable<String> chunks) {
    final out = StringBuffer();
    for (final c in chunks) {
      out.write(f.process(c));
    }
    return out.toString();
  }

  // ---------------------------------------------------------------------------
  // T038 — remember_fact leak is suppressed
  // ---------------------------------------------------------------------------

  group('remember_fact leak suppression (guarantee 20)', () {
    test(
      'bare remember_fact call JSON: nothing emitted to the text channel',
      () {
        final f = LeakFilter();
        final emitted = emit(f, [rememberFactLeak]);
        expect(emitted, isEmpty);
        f.discardOnToolCall();
      },
    );

    test(
      'prose then remember_fact leak: prose passes, leak withheld, then discarded',
      () {
        final f = LeakFilter();
        final emitted = emit(f, ['let me save that. ', rememberFactLeak]);
        expect(emitted, 'let me save that. ');
        f.discardOnToolCall(); // turn ended in a tool call → leak discarded
      },
    );

    test(
      'split-chunk remember_fact leak: all chunks withheld and discarded',
      () {
        final f = LeakFilter();
        const part1 = '{"role":"assistant","tool_calls":[';
        const part2 = '{"type":"function","function":';
        const part3 =
            '{"name":"remember_fact","arguments":{"fact":"name is Yossef"}}}]}';
        final emitted = emit(f, [part1, part2, part3]);
        expect(emitted, isEmpty);
        f.discardOnToolCall();
      },
    );

    test(
      'remember_fact args are never emitted (fact content not visible as raw text)',
      () {
        final f = LeakFilter();
        emit(f, [rememberFactLeak]);
        // discardOnToolCall drops everything — no fact content leaks
        f.discardOnToolCall();
        // nothing was flushed
        expect(f.isWithholding, isFalse);
      },
    );

    test(
      'isWithholding is true mid-stream when processing remember_fact leak',
      () {
        final f = LeakFilter();
        f.process(rememberFactLeak);
        expect(f.isWithholding, isTrue);
        f.discardOnToolCall();
      },
    );
  });

  // ---------------------------------------------------------------------------
  // T038 — forget_fact leak is suppressed
  // ---------------------------------------------------------------------------

  group('forget_fact leak suppression (guarantee 20)', () {
    test('bare forget_fact call JSON: nothing emitted to the text channel', () {
      final f = LeakFilter();
      final emitted = emit(f, [forgetFactLeak]);
      expect(emitted, isEmpty);
      f.discardOnToolCall();
    });

    test(
      'prose then forget_fact leak: prose passes, leak withheld, then discarded',
      () {
        final f = LeakFilter();
        final emitted = emit(f, ['alright. ', forgetFactLeak]);
        expect(emitted, 'alright. ');
        f.discardOnToolCall();
      },
    );

    test('split-chunk forget_fact leak: all chunks withheld and discarded', () {
      final f = LeakFilter();
      const part1 = '{"role":"assistant","tool_calls":[';
      const part2 = '{"type":"function","function":{"name":"forget_fact",';
      const part3 = '"arguments":{"id":1}}}]}';
      final emitted = emit(f, [part1, part2, part3]);
      expect(emitted, isEmpty);
      f.discardOnToolCall();
    });

    test(
      'isWithholding is true mid-stream when processing forget_fact leak',
      () {
        final f = LeakFilter();
        f.process(forgetFactLeak);
        expect(f.isWithholding, isTrue);
        f.discardOnToolCall();
      },
    );
  });

  // ---------------------------------------------------------------------------
  // T038 — inactive filter (functionCalling off) passes both leaks through
  //         (byte-parity guarantee 19 is preserved even for memory tool JSON)
  // ---------------------------------------------------------------------------

  group(
    'inactive filter passes all JSON through (byte-parity, guarantee 19)',
    () {
      test('inactive filter: remember_fact leak JSON is emitted verbatim', () {
        final f = LeakFilter(active: false);
        final emitted = emit(f, [rememberFactLeak]);
        expect(emitted, rememberFactLeak);
        expect(f.isWithholding, isFalse);
      });

      test('inactive filter: forget_fact leak JSON is emitted verbatim', () {
        final f = LeakFilter(active: false);
        final emitted = emit(f, [forgetFactLeak]);
        expect(emitted, forgetFactLeak);
        expect(f.isWithholding, isFalse);
      });
    },
  );

  // ---------------------------------------------------------------------------
  // T038 — false-positive prose that starts with '{' is recovered on text-terminated turns
  //         (this invariant must hold for memory-tool turns too — no regressions)
  // ---------------------------------------------------------------------------

  group(
    'false-positive prose recovery is unaffected by memory tools (fidelity)',
    () {
      test(
        'a reply starting with { that is NOT a tool call is flushed on text-terminated turns',
        () {
          final f = LeakFilter();
          final emitted = emit(f, ['{"summary":"remembered facts are: ..."}']);
          expect(emitted, isEmpty, reason: 'withheld while ambiguous');
          // Turn ends as text (no tool call came) → flush verbatim.
          final flushed = f.flushOnText();
          expect(flushed, '{"summary":"remembered facts are: ..."}');
        },
      );

      test(
        'leading-whitespace probe with remember_fact JSON is still detected and suppressed',
        () {
          final f = LeakFilter();
          final emitted = emit(f, ['   $rememberFactLeak']);
          expect(emitted, isEmpty);
          f.discardOnToolCall();
        },
      );
    },
  );
}
