import 'dart:convert';

import 'package:ai_assistant/domain/entities/audio_input.dart';
import 'package:ai_assistant/domain/entities/chat_turn.dart';
import 'package:ai_assistant/domain/entities/image_input.dart';
import 'package:ai_assistant/domain/entities/message.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Builds the model context for a turn (FR-017, Q2): an ordered list of prior [ChatTurn]s, with a
/// sliding window that drops the OLDEST turns when the context would overflow the model's budget.
///
/// Stored history is never mutated — only the assembled, in-memory context is trimmed. Stopped-
/// partial assistant turns ARE included (their text is real content the model should see, FR-017);
/// empty placeholder turns (a `streaming` assistant turn with no text yet) are skipped. Tool turns
/// (004) are included as `ChatTurn.tool` so the seam replays them as the plugin's call+response
/// pair; their token cost is the name + args + result JSON (data-model §3).
///
/// Token counting is a heuristic (~4 chars/token) since there is no on-device tokenizer in pure
/// Dart; it only needs to be a safe upper-ish estimate to keep the window under the model budget.
class ContextAssembler {
  const ContextAssembler({this.maxContextTokens = _defaultBudget});

  /// Default context budget, in estimated tokens. The model runs with `maxTokens: 2048`; this
  /// leaves headroom for the current prompt and the generated reply.
  static const int _defaultBudget = 1536;

  /// Estimated cost of the R6 tool-use system instruction (~40 tokens), reserved off the top of
  /// the budget when function calling is active so a long history can't crowd it out.
  static const int toolInstructionTokens = 40;

  final int maxContextTokens;

  /// Assemble the context from [priorMessages] — the conversation's turns BEFORE the current
  /// prompt, in order. Returns ordered turns trimmed (oldest-first) to fit the budget.
  ///
  /// A media-bearing prior turn carries its image/clip forward (FR-015/FR-016; 003 FR-016/FR-017):
  /// [images]/[audio] map a message id to the just-in-time bytes. A tool turn replays as
  /// `ChatTurn.tool`. When [reserveToolInstruction] is true (the model supports function calling),
  /// [toolInstructionTokens] are subtracted from the budget (R6). The assembler stays pure (no
  /// file I/O) — bytes are injected.
  List<ChatTurn> assemble(
    List<Message> priorMessages, {
    Map<int, ImageInput> images = const <int, ImageInput>{},
    Map<int, AudioInput> audio = const <int, AudioInput>{},
    bool reserveToolInstruction = false,
  }) {
    final turns = <ChatTurn>[];
    for (final message in priorMessages) {
      if (message.role == MessageRole.tool) {
        // A tool turn replays as the plugin's call+response pair; error/skipped rows carry their
        // `{error: …}` result so the model remembers failures honestly (data-model §3).
        turns.add(ChatTurn.tool(
          name: message.toolName ?? '',
          args: message.toolArgs ?? const <String, Object?>{},
          result: message.toolResult ?? const <String, Object?>{},
        ));
        continue;
      }
      // Skip an empty assistant placeholder (still streaming, no text yet). User turns are kept
      // even when text is empty (they may be media-only).
      if (message.role == MessageRole.assistant && message.content.isEmpty) {
        continue;
      }
      turns.add(ChatTurn(
        isUser: message.isUser,
        text: message.content,
        image: images[message.id],
        audio: audio[message.id],
      ));
    }

    final budget =
        maxContextTokens - (reserveToolInstruction ? toolInstructionTokens : 0);
    var totalTokens = turns.fold<int>(0, (sum, turn) => sum + _estimateTurnTokens(turn));
    var start = 0;
    // Drop oldest turns until the window fits (sliding window, Q2).
    while (start < turns.length && totalTokens > budget) {
      totalTokens -= _estimateTurnTokens(turns[start]);
      start++;
    }
    return turns.sublist(start);
  }

  /// Estimated tokens for a turn. A tool turn costs its name + args + result JSON (data-model §3);
  /// everything else costs its text.
  int _estimateTurnTokens(ChatTurn turn) {
    if (turn.isTool) {
      final payload = (turn.toolName ?? '') +
          jsonEncode(turn.toolArgs ?? const <String, Object?>{}) +
          jsonEncode(turn.toolResult ?? const <String, Object?>{});
      return _estimateTokens(payload);
    }
    return _estimateTokens(turn.text);
  }

  int _estimateTokens(String text) => (text.length / 4).ceil();
}

/// App-wide context assembler. Overridable in tests (e.g. a tiny budget to exercise overflow).
final contextAssemblerProvider = Provider<ContextAssembler>((ref) {
  return const ContextAssembler();
});
