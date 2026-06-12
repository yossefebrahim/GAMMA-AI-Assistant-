import 'package:ai_assistant/core/memory/system_instruction_composer.dart';
import 'package:ai_assistant/core/tools/tool_registry.dart';
import 'package:flutter_test/flutter_test.dart';

/// 005 R3 / T020 — SystemInstructionComposer unit tests.
///
/// Covers every flag combination (2^3 = 8 subsets), ordering invariants, and the
/// byte-parity guarantee 29 (all-empty → null).
void main() {
  // ---------------------------------------------------------------------------
  // helpers
  // ---------------------------------------------------------------------------

  const sampleFacts = '[identity]\n#1 user\'s name is Yossef';

  // ---------------------------------------------------------------------------
  // null / empty guard (guarantee 29)
  // ---------------------------------------------------------------------------

  group('returns null when all parts are absent', () {
    test('all flags false, no facts block', () {
      expect(
        SystemInstructionComposer.compose(
          factsBlock: null,
          memoryCapture: false,
          deviceTools: false,
        ),
        isNull,
      );
    });

    test('all flags false, empty string facts block', () {
      expect(
        SystemInstructionComposer.compose(
          factsBlock: '',
          memoryCapture: false,
          deviceTools: false,
        ),
        isNull,
      );
    });

    test('all flags false, whitespace-only facts block', () {
      expect(
        SystemInstructionComposer.compose(
          factsBlock: '   ',
          memoryCapture: false,
          deviceTools: false,
        ),
        isNull,
      );
    });
  });

  // ---------------------------------------------------------------------------
  // single-part cases
  // ---------------------------------------------------------------------------

  group('single part only', () {
    test('facts block only — returns the block, no trailing newlines', () {
      final result = SystemInstructionComposer.compose(
        factsBlock: sampleFacts,
        memoryCapture: false,
        deviceTools: false,
      );
      expect(result, isNotNull);
      expect(result, equals(sampleFacts));
      // no blank lines inside a single-part result
      expect(result!.contains('\n\n'), isFalse);
    });

    test('memory capture only — returns the capture instruction', () {
      final result = SystemInstructionComposer.compose(
        factsBlock: null,
        memoryCapture: true,
        deviceTools: false,
      );
      expect(result, isNotNull);
      expect(result, contains('remember_fact'));
      expect(result, contains('third-person'));
      // should not include the device instruction
      expect(result, isNot(contains('clipboard')));
      // should not include a facts block header
      expect(result, isNot(contains('[')));
    });

    test(
      'device tools only — returns ToolRegistry.systemInstruction verbatim',
      () {
        final result = SystemInstructionComposer.compose(
          factsBlock: null,
          memoryCapture: false,
          deviceTools: true,
        );
        expect(result, equals(ToolRegistry.systemInstruction));
      },
    );
  });

  // ---------------------------------------------------------------------------
  // two-part cases
  // ---------------------------------------------------------------------------

  group('two parts', () {
    test('facts + capture — ordered facts first, capture second', () {
      final result = SystemInstructionComposer.compose(
        factsBlock: sampleFacts,
        memoryCapture: true,
        deviceTools: false,
      )!;
      expect(
        result.indexOf(sampleFacts),
        lessThan(result.indexOf('remember_fact')),
      );
      // joined by exactly one blank line
      expect(result, contains('$sampleFacts\n\n'));
    });

    test('facts + device — ordered facts first, device second', () {
      final result = SystemInstructionComposer.compose(
        factsBlock: sampleFacts,
        memoryCapture: false,
        deviceTools: true,
      )!;
      expect(
        result.indexOf(sampleFacts),
        lessThan(result.indexOf(ToolRegistry.systemInstruction)),
      );
      expect(result, contains('\n\n${ToolRegistry.systemInstruction}'));
    });

    test('capture + device — ordered capture first, device second', () {
      final result = SystemInstructionComposer.compose(
        factsBlock: null,
        memoryCapture: true,
        deviceTools: true,
      )!;
      expect(
        result.indexOf('remember_fact'),
        lessThan(result.indexOf(ToolRegistry.systemInstruction)),
      );
      expect(result, contains('\n\n${ToolRegistry.systemInstruction}'));
    });
  });

  // ---------------------------------------------------------------------------
  // all-three case
  // ---------------------------------------------------------------------------

  group('all three parts', () {
    test('ordering: facts → capture → device, joined by blank lines', () {
      final result = SystemInstructionComposer.compose(
        factsBlock: sampleFacts,
        memoryCapture: true,
        deviceTools: true,
      )!;

      final factsIdx = result.indexOf(sampleFacts);
      final captureIdx = result.indexOf('remember_fact');
      final deviceIdx = result.indexOf(ToolRegistry.systemInstruction);

      expect(
        factsIdx,
        lessThan(captureIdx),
        reason: 'facts must precede capture instruction',
      );
      expect(
        captureIdx,
        lessThan(deviceIdx),
        reason: 'capture must precede device instruction',
      );

      // exactly two blank-line separators
      final blankLineCount = '\n\n'.allMatches(result).length;
      expect(blankLineCount, equals(2));
    });

    test('all three parts are present in the output', () {
      final result = SystemInstructionComposer.compose(
        factsBlock: sampleFacts,
        memoryCapture: true,
        deviceTools: true,
      )!;
      expect(result, contains(sampleFacts));
      expect(result, contains('remember_fact'));
      expect(result, contains(ToolRegistry.systemInstruction));
    });
  });

  // ---------------------------------------------------------------------------
  // capture instruction wording (R5 contract)
  // ---------------------------------------------------------------------------

  group('capture instruction wording (R5)', () {
    late String captureOnly;

    setUp(() {
      captureOnly = SystemInstructionComposer.compose(
        factsBlock: null,
        memoryCapture: true,
        deviceTools: false,
      )!;
    });

    test('mentions remember_fact by name', () {
      expect(captureOnly, contains('remember_fact'));
    });

    test('instructs third-person statement', () {
      expect(captureOnly, contains('third-person'));
    });

    test('mentions category', () {
      expect(captureOnly, contains('category'));
    });

    test('mentions lasting preferences as a trigger class', () {
      expect(captureOnly, contains('lasting preference'));
    });

    test('names the negative examples (no trivia/weather/tasks)', () {
      expect(captureOnly, contains('trivia'));
      expect(captureOnly, contains('weather'));
      expect(captureOnly, contains('tasks'));
    });

    test('is lowercase (design-system microcopy rule)', () {
      expect(captureOnly, equals(captureOnly.toLowerCase()));
    });

    test('does not appear when memoryCapture is false', () {
      final result = SystemInstructionComposer.compose(
        factsBlock: sampleFacts,
        memoryCapture: false,
        deviceTools: true,
      )!;
      expect(result, isNot(contains('remember_fact')));
    });
  });

  // ---------------------------------------------------------------------------
  // device instruction referencing (no hardcoded duplicate)
  // ---------------------------------------------------------------------------

  group('device instruction sourced from ToolRegistry (no hardcoded copy)', () {
    test(
      'device-tools result equals ToolRegistry.systemInstruction exactly',
      () {
        final result = SystemInstructionComposer.compose(
          factsBlock: null,
          memoryCapture: false,
          deviceTools: true,
        );
        expect(result, equals(ToolRegistry.systemInstruction));
      },
    );

    test('does not appear when deviceTools is false', () {
      final result = SystemInstructionComposer.compose(
        factsBlock: sampleFacts,
        memoryCapture: true,
        deviceTools: false,
      )!;
      expect(result, isNot(contains(ToolRegistry.systemInstruction)));
    });
  });

  // ---------------------------------------------------------------------------
  // whitespace trimming of factsBlock
  // ---------------------------------------------------------------------------

  group('facts block trimming', () {
    test(
      'leading/trailing whitespace in factsBlock is stripped before joining',
      () {
        final result = SystemInstructionComposer.compose(
          factsBlock: '  $sampleFacts  ',
          memoryCapture: false,
          deviceTools: false,
        );
        expect(result, equals(sampleFacts));
      },
    );

    test(
      'blank-only factsBlock treated as absent — falls through to next part',
      () {
        final result = SystemInstructionComposer.compose(
          factsBlock: '\n  \n',
          memoryCapture: true,
          deviceTools: false,
        )!;
        // should equal just the capture instruction (no leading blank line)
        expect(result.trimLeft(), isNot(startsWith('\n')));
        expect(result, contains('remember_fact'));
        expect(result, isNot(contains('[')));
      },
    );
  });
}
