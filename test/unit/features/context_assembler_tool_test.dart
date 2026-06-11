import 'package:ai_assistant/domain/entities/message.dart';
import 'package:ai_assistant/domain/entities/tool_outcome.dart';
import 'package:ai_assistant/features/chat/context_assembler.dart';
import 'package:flutter_test/flutter_test.dart';

/// 004 data-model §3 — the context assembler includes tool turns in replay, accounts their tokens
/// (name + args + result JSON), drops oldest-first with tool turns in the window, and reserves the
/// R6 instruction budget when function calling is active.
void main() {
  Message msg(int id, MessageRole role, String content, int seq) => Message(
        id: id,
        conversationId: 1,
        role: role,
        content: content,
        sequence: seq,
        createdAt: DateTime.utc(2026, 6, 10),
        status: MessageStatus.complete,
      );

  Message toolMsg(int id, int seq,
          {Map<String, Object?>? args, Map<String, Object?>? result}) =>
      Message(
        id: id,
        conversationId: 1,
        role: MessageRole.tool,
        content: 'battery 83%',
        sequence: seq,
        createdAt: DateTime.utc(2026, 6, 10),
        status: MessageStatus.complete,
        toolName: 'get_device_info',
        toolArgs: args ?? const {'section': 'battery'},
        toolStatus: ToolCallStatus.success,
        toolResult: result ?? const {'battery': 83},
      );

  test('a tool turn is included as a ChatTurn.tool carrying name/args/result', () {
    const assembler = ContextAssembler();
    final turns = assembler.assemble([
      msg(1, MessageRole.user, 'battery?', 0),
      toolMsg(2, 1),
      msg(3, MessageRole.assistant, 'your battery is at 83%', 2),
    ]);

    expect(turns, hasLength(3));
    expect(turns[1].isTool, isTrue);
    expect(turns[1].toolName, 'get_device_info');
    expect(turns[1].toolArgs, {'section': 'battery'});
    expect(turns[1].toolResult, {'battery': 83});
  });

  test('error/skipped tool rows replay their {error: …} result', () {
    const assembler = ContextAssembler();
    final turns = assembler.assemble([
      toolMsg(1, 0, result: const {'error': 'clipboard empty or not text'}),
    ]);
    expect(turns.single.toolResult, {'error': 'clipboard empty or not text'});
  });

  test('token accounting for a tool turn uses name + args + result JSON (oldest-drop)', () {
    // A big oldest user turn (~50 tokens) + a small tool turn (~13 tokens: name 15 + args 21 +
    // result 14 chars). Budget 30 fits the tool turn alone but not both → oldest drops, tool kept.
    const assembler = ContextAssembler(maxContextTokens: 30);
    final turns = assembler.assemble([
      msg(1, MessageRole.user, 'x' * 200, 0), // ~50 tokens — oldest
      toolMsg(2, 1), // ~13 tokens
    ]);
    expect(turns, hasLength(1));
    expect(turns.single.isTool, isTrue, reason: 'oldest user turn dropped, tool turn kept');
  });

  test('reserveToolInstruction shrinks the effective budget by ~40 tokens (R6)', () {
    // Budget exactly fits two ~10-token turns (=20) without reservation, but not with it.
    const assembler = ContextAssembler(maxContextTokens: 30);
    final messages = [
      msg(1, MessageRole.user, 'a' * 40, 0), // ~10 tokens
      msg(2, MessageRole.assistant, 'b' * 40, 1), // ~10 tokens
    ];
    final without = assembler.assemble(messages);
    final withReserve = assembler.assemble(messages, reserveToolInstruction: true);
    // 20 tokens fits in 30 but not in 30-40 (clamped to dropping): reservation drops more.
    expect(without, hasLength(2));
    expect(withReserve.length, lessThan(without.length));
  });
}
