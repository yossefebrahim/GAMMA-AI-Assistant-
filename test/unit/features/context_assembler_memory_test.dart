import 'package:ai_assistant/domain/entities/message.dart';
import 'package:ai_assistant/features/chat/context_assembler.dart';
import 'package:flutter_test/flutter_test.dart';

/// T025 — ContextAssembler memory token reserve.
///
/// Verifies that [memoryBlockTokens] (~225) and [memoryCaptureTokens] (~86) are correctly
/// subtracted from the budget across all on/off combinations, mirroring the existing
/// [toolInstructionTokens] (~40) reserve tests.
void main() {
  Message msg(int id, MessageRole role, String content) => Message(
    id: id,
    conversationId: 1,
    role: role,
    content: content,
    sequence: id,
    createdAt: DateTime.utc(2026, 6, 11, 0, 0, id),
    status: MessageStatus.complete,
  );

  // A minimal budget just large enough to hold two ~10-token turns (40 chars / 4 ≈ 10 each).
  // Useful to detect whether a given reserve drops at least one turn.
  const twoTurnChars =
      40; // chars per turn → ~10 tokens each → ~20 tokens for both

  group('constant values', () {
    test(
      'memoryBlockTokens is 225 (R4: ≤20 facts × 8.7 tok/fact, ≤900-char cap)',
      () {
        expect(ContextAssembler.memoryBlockTokens, 225);
      },
    );

    test(
      'memoryCaptureTokens is 86 (R5: measured on A34 via sizeInTokens)',
      () {
        expect(ContextAssembler.memoryCaptureTokens, 86);
      },
    );

    test('toolInstructionTokens is still 40 (004 R6 — not regressed)', () {
      expect(ContextAssembler.toolInstructionTokens, 40);
    });
  });

  group(
    'reserve math — no memory flags (baseline, byte-parity with 003/004)',
    () {
      test('memory off/empty → zero extra reserve; existing turns kept', () {
        // Budget = 30 tokens; two ~10-token turns = ~20 tokens → fits.
        const assembler = ContextAssembler(maxContextTokens: 30);
        final messages = [
          msg(1, MessageRole.user, 'a' * twoTurnChars),
          msg(2, MessageRole.assistant, 'b' * twoTurnChars),
        ];
        final context = assembler.assemble(messages);
        // No memory flags → full 30-token budget; both turns fit.
        expect(context, hasLength(2));
      });
    },
  );

  group(
    'reserve math — reserveMemoryBlock only (memory on, facts present, capture off)',
    () {
      test(
        'memoryBlockTokens (~225) subtracted from budget; history can overflow',
        () {
          // Budget = 250; turns cost ~20 tokens; reserve = 225 → effective = 25 → 20 fits.
          const assembler = ContextAssembler(maxContextTokens: 250);
          final messages = [
            msg(1, MessageRole.user, 'a' * twoTurnChars),
            msg(2, MessageRole.assistant, 'b' * twoTurnChars),
          ];
          final withBlock = assembler.assemble(
            messages,
            reserveMemoryBlock: true,
          );
          final withoutBlock = assembler.assemble(
            messages,
            reserveMemoryBlock: false,
          );

          // Without reserve: 20 tokens fits in 250 → both turns.
          expect(withoutBlock, hasLength(2));
          // With reserve: effective budget = 250 - 225 = 25; 20 tokens still fits.
          expect(withBlock, hasLength(2));
        },
      );

      test(
        'reserveMemoryBlock drops turns when turns would fill the reserved space',
        () {
          // Budget = 240; two ~10-token turns = ~20 tokens.
          // Without reserve: 20 < 240 → both kept.
          // With reserve: effective = 240 - 225 = 15 < 20 → oldest dropped.
          const assembler = ContextAssembler(maxContextTokens: 240);
          final messages = [
            msg(1, MessageRole.user, 'a' * twoTurnChars),
            msg(2, MessageRole.assistant, 'b' * twoTurnChars),
          ];
          final withBlock = assembler.assemble(
            messages,
            reserveMemoryBlock: true,
          );
          final withoutBlock = assembler.assemble(
            messages,
            reserveMemoryBlock: false,
          );

          expect(withoutBlock, hasLength(2));
          expect(
            withBlock.length,
            lessThan(withoutBlock.length),
            reason:
                'block reserve reduces effective budget, oldest turn dropped',
          );
        },
      );
    },
  );

  group('reserve math — reserveMemoryCaptureInstruction only', () {
    test(
      'memoryCaptureTokens (~86) subtracted independently when only capture flag set',
      () {
        // Budget = 100; two ~10-token turns = ~20 tokens.
        // Without: 20 < 100 → both kept.
        // With capture only: effective = 100 - 86 = 14 < 20 → oldest dropped.
        const assembler = ContextAssembler(maxContextTokens: 100);
        final messages = [
          msg(1, MessageRole.user, 'a' * twoTurnChars),
          msg(2, MessageRole.assistant, 'b' * twoTurnChars),
        ];
        final withCapture = assembler.assemble(
          messages,
          reserveMemoryCaptureInstruction: true,
        );
        final withoutCapture = assembler.assemble(
          messages,
          reserveMemoryCaptureInstruction: false,
        );

        expect(withoutCapture, hasLength(2));
        expect(
          withCapture.length,
          lessThan(withoutCapture.length),
          reason: 'capture reserve shrinks budget; oldest turn dropped',
        );
      },
    );
  });

  group(
    'reserve math — both memory reserves active (block + capture = ~311 tokens total)',
    () {
      test('combined reserve is 225 + 86 = 311 tokens', () {
        // Verify by observing the budget arithmetic directly: at budget=320, combined=311,
        // effective=9; a single ~10-token turn overflows and is dropped.
        const assembler = ContextAssembler(maxContextTokens: 320);
        final messages = [
          msg(1, MessageRole.user, 'a' * twoTurnChars), // ~10 tokens
        ];
        final result = assembler.assemble(
          messages,
          reserveMemoryBlock: true,
          reserveMemoryCaptureInstruction: true,
        );
        // Effective = 320 - 225 - 86 = 9; single ~10-token turn exceeds 9 → dropped.
        expect(
          result,
          isEmpty,
          reason:
              'combined 311-token reserve leaves effective=9, '
              'which cannot fit the ~10-token turn',
        );
      });

      test('both active + tool reserve = 40 + 225 + 86 = 351 tokens total', () {
        // Budget = 360; three reserves sum to 351; effective = 9.
        const assembler = ContextAssembler(maxContextTokens: 360);
        final messages = [
          msg(1, MessageRole.user, 'a' * twoTurnChars), // ~10 tokens
        ];
        final result = assembler.assemble(
          messages,
          reserveToolInstruction: true,
          reserveMemoryBlock: true,
          reserveMemoryCaptureInstruction: true,
        );
        // Effective = 360 - 40 - 225 - 86 = 9 < 10 → turn dropped.
        expect(
          result,
          isEmpty,
          reason:
              'all three reserves sum to 351; effective=9 cannot fit the ~10-token turn',
        );
      });

      test('all reserves off → all turns kept (zero extra deduction)', () {
        const assembler = ContextAssembler(maxContextTokens: 30);
        final messages = [
          msg(1, MessageRole.user, 'a' * twoTurnChars),
          msg(2, MessageRole.assistant, 'b' * twoTurnChars),
        ];
        // No flags → effective = 30; ~20 tokens fits.
        final context = assembler.assemble(messages);
        expect(context, hasLength(2));
      });
    },
  );

  group('reserve combinations — flag independence', () {
    test(
      'reserveMemoryBlock=false, reserveMemoryCaptureInstruction=false → identical to no flags',
      () {
        const assembler = ContextAssembler(maxContextTokens: 30);
        final messages = [
          msg(1, MessageRole.user, 'a' * twoTurnChars),
          msg(2, MessageRole.assistant, 'b' * twoTurnChars),
        ];
        final implicit = assembler.assemble(messages);
        final explicit = assembler.assemble(
          messages,
          reserveMemoryBlock: false,
          reserveMemoryCaptureInstruction: false,
        );
        expect(explicit, equals(implicit));
      },
    );

    test(
      'reserveMemoryBlock adds 225; reserveMemoryCaptureInstruction adds 86 independently',
      () {
        // Budget = 350.
        // Only block: effective = 350 - 225 = 125.
        // Only capture: effective = 350 - 86 = 264.
        // Both: effective = 350 - 225 - 86 = 39.
        //
        // Single 40-char (~10-token) turn:
        //   only-block   125 ≥ 10 → kept
        //   only-capture 264 ≥ 10 → kept
        //   both          39 ≥ 10 → kept
        // Add a second 40-char turn (total ~20 tokens):
        //   both: 39 ≥ 20 → both kept
        // Add enough turns that only-capture keeps them but both drops the oldest.
        // Use budget=350, 3 turns each ~10 tokens = ~30 tokens.
        //   only-capture: 264 ≥ 30 → all 3 kept
        //   both:  39 ≥ 30 → all 3 kept   (add more to stress)
        // Use 4 turns, budget=350, each 40 chars (~10 tokens) = ~40 tokens.
        //   only-capture: 264 ≥ 40 → 4 kept
        //   both:  39 <  40 → oldest(s) dropped
        const assembler = ContextAssembler(maxContextTokens: 350);
        final messages = [
          msg(1, MessageRole.user, 'a' * twoTurnChars),
          msg(2, MessageRole.assistant, 'b' * twoTurnChars),
          msg(3, MessageRole.user, 'c' * twoTurnChars),
          msg(4, MessageRole.assistant, 'd' * twoTurnChars),
        ];
        final onlyCapture = assembler.assemble(
          messages,
          reserveMemoryCaptureInstruction: true,
        );
        final both = assembler.assemble(
          messages,
          reserveMemoryBlock: true,
          reserveMemoryCaptureInstruction: true,
        );
        expect(
          onlyCapture,
          hasLength(4),
          reason: 'only-capture effective=264, 4×10=40 tokens fits',
        );
        expect(
          both.length,
          lessThan(onlyCapture.length),
          reason: 'adding block reserve further shrinks budget, oldest dropped',
        );
      },
    );
  });
}
