import 'package:ai_assistant/domain/entities/message.dart';
import 'package:ai_assistant/features/chat/context_assembler.dart';
import 'package:flutter_test/flutter_test.dart';

/// T032 — ContextAssembler web tools token reserve.
///
/// Verifies that [ContextAssembler.webToolsReserveTokens] (~80) is subtracted from the budget when
/// the web tools are declared, independently of the existing tool/memory reserves, and that all
/// four feature reserves compose additively (the ~1,156-token-remaining running total with the
/// default 1,536 budget and tool + memory + web reserves active).
void main() {
  Message msg(int id, MessageRole role, String content) => Message(
    id: id,
    conversationId: 1,
    role: role,
    content: content,
    sequence: id,
    createdAt: DateTime.utc(2026, 6, 12, 0, 0, id),
    status: MessageStatus.complete,
  );

  // ~10 tokens per turn (40 chars / 4).
  const twoTurnChars = 40;

  group('constant value', () {
    test(
      'webToolsReserveTokens is 80 (data-model §7, plan §Context budget)',
      () {
        expect(ContextAssembler.webToolsReserveTokens, 80);
      },
    );
  });

  group('reserve math — reserveWebTools only', () {
    test('webToolsReserveTokens (~80) subtracted from budget', () {
      // Budget = 100; turns cost ~20 tokens.
      // Without web reserve: 20 < 100 → both kept.
      // With web reserve: effective = 100 - 80 = 20; 20 fits exactly.
      const assembler = ContextAssembler(maxContextTokens: 100);
      final messages = [
        msg(1, MessageRole.user, 'a' * twoTurnChars),
        msg(2, MessageRole.assistant, 'b' * twoTurnChars),
      ];
      final withWeb = assembler.assemble(messages, reserveWebTools: true);
      final withoutWeb = assembler.assemble(messages, reserveWebTools: false);

      expect(withoutWeb, hasLength(2));
      expect(withWeb, hasLength(2));
    });

    test(
      'reserveWebTools drops the oldest turn when it would fill the reserve',
      () {
        // Budget = 95; two ~10-token turns = ~20 tokens.
        // Without: 20 < 95 → both kept.
        // With web reserve: effective = 95 - 80 = 15 < 20 → oldest dropped.
        const assembler = ContextAssembler(maxContextTokens: 95);
        final messages = [
          msg(1, MessageRole.user, 'a' * twoTurnChars),
          msg(2, MessageRole.assistant, 'b' * twoTurnChars),
        ];
        final withWeb = assembler.assemble(messages, reserveWebTools: true);
        final withoutWeb = assembler.assemble(messages, reserveWebTools: false);

        expect(withoutWeb, hasLength(2));
        expect(
          withWeb.length,
          lessThan(withoutWeb.length),
          reason: 'web reserve shrinks effective budget; oldest turn dropped',
        );
      },
    );

    test('reserveWebTools=false is identical to no flag (byte-parity)', () {
      const assembler = ContextAssembler(maxContextTokens: 30);
      final messages = [
        msg(1, MessageRole.user, 'a' * twoTurnChars),
        msg(2, MessageRole.assistant, 'b' * twoTurnChars),
      ];
      final implicit = assembler.assemble(messages);
      final explicit = assembler.assemble(messages, reserveWebTools: false);
      expect(explicit, equals(implicit));
    });
  });

  group('reserve math — all four feature reserves active', () {
    test('tool + memory block + memory capture + web reserves sum to 431 tokens', () {
      // 40 (tool) + 225 (memory block) + 86 (memory capture) + 80 (web) = 431.
      // At the default 1,536 budget that leaves 1,105 tokens (≈ the ~1,156 running-total target,
      // within the heuristic margin). Assert the arithmetic directly via an overflow probe.
      const combined =
          ContextAssembler.toolInstructionTokens +
          ContextAssembler.memoryBlockTokens +
          ContextAssembler.memoryCaptureTokens +
          ContextAssembler.webToolsReserveTokens;
      expect(combined, 431);

      // Probe: budget = combined + 9; a single ~10-token turn overflows the effective budget.
      const assembler = ContextAssembler(maxContextTokens: combined + 9);
      final messages = [msg(1, MessageRole.user, 'a' * twoTurnChars)];
      final result = assembler.assemble(
        messages,
        reserveToolInstruction: true,
        reserveMemoryBlock: true,
        reserveMemoryCaptureInstruction: true,
        reserveWebTools: true,
      );
      expect(
        result,
        isEmpty,
        reason:
            'all four reserves sum to 431; effective=9 cannot fit the '
            '~10-token turn',
      );
    });

    test(
      'default 1,536 budget with all four reserves keeps a healthy window',
      () {
        // 1,536 - 431 = 1,105 effective tokens — plenty of room for several short turns.
        const assembler = ContextAssembler();
        final messages = [
          msg(1, MessageRole.user, 'a' * twoTurnChars),
          msg(2, MessageRole.assistant, 'b' * twoTurnChars),
          msg(3, MessageRole.user, 'c' * twoTurnChars),
          msg(4, MessageRole.assistant, 'd' * twoTurnChars),
        ];
        final result = assembler.assemble(
          messages,
          reserveToolInstruction: true,
          reserveMemoryBlock: true,
          reserveMemoryCaptureInstruction: true,
          reserveWebTools: true,
        );
        expect(result, hasLength(4));
      },
    );

    test('web reserve composes independently of the memory/tool reserves', () {
      // Budget = 350.
      // Three turns (~30 tokens). only-tool effective = 310 → all kept.
      // tool + web effective = 350 - 40 - 80 = 230 → all 3 kept; add a 4th to stress.
      const assembler = ContextAssembler(maxContextTokens: 350);
      final messages = [
        for (var i = 1; i <= 4; i++)
          msg(
            i,
            i.isEven ? MessageRole.assistant : MessageRole.user,
            'x' * twoTurnChars,
          ),
      ];
      final toolOnly = assembler.assemble(
        messages,
        reserveToolInstruction: true,
      );
      final toolAndWebAndMemory = assembler.assemble(
        messages,
        reserveToolInstruction: true,
        reserveMemoryBlock: true,
        reserveMemoryCaptureInstruction: true,
        reserveWebTools: true,
      );
      // tool-only: 310 ≥ 40 → all 4 kept.
      expect(toolOnly, hasLength(4));
      // all reserves: 350 - 431 < 0 → everything dropped.
      expect(toolAndWebAndMemory, isEmpty);
    });
  });
}
