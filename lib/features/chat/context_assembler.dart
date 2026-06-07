import 'package:ai_assistant/domain/entities/chat_turn.dart';
import 'package:ai_assistant/domain/entities/message.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Builds the model context for a turn (FR-017, Q2): an ordered list of prior [ChatTurn]s, with a
/// sliding window that drops the OLDEST turns when the context would overflow the model's budget.
///
/// Stored history is never mutated — only the assembled, in-memory context is trimmed. Stopped-
/// partial assistant turns ARE included (their text is real content the model should see, FR-017);
/// empty placeholder turns (a `streaming` assistant turn with no text yet) are skipped.
///
/// Token counting is a heuristic (~4 chars/token) since there is no on-device tokenizer in pure
/// Dart; it only needs to be a safe upper-ish estimate to keep the window under the model budget.
class ContextAssembler {
  const ContextAssembler({this.maxContextTokens = _defaultBudget});

  /// Default context budget, in estimated tokens. The model runs with `maxTokens: 2048`; this
  /// leaves headroom for the current prompt and the generated reply.
  static const int _defaultBudget = 1536;

  final int maxContextTokens;

  /// Assemble the context from [priorMessages] — the conversation's turns BEFORE the current
  /// prompt, in order. Returns ordered turns trimmed (oldest-first) to fit [maxContextTokens].
  List<ChatTurn> assemble(List<Message> priorMessages) {
    final turns = <ChatTurn>[];
    for (final message in priorMessages) {
      // Skip an empty assistant placeholder (still streaming, no text yet). Stopped-partial and
      // complete turns carry real text and are included.
      if (message.role == MessageRole.assistant && message.content.isEmpty) {
        continue;
      }
      turns.add(ChatTurn(isUser: message.isUser, text: message.content));
    }

    var totalTokens = turns.fold<int>(0, (sum, turn) => sum + _estimateTokens(turn.text));
    var start = 0;
    // Drop oldest turns until the window fits (sliding window, Q2).
    while (start < turns.length && totalTokens > maxContextTokens) {
      totalTokens -= _estimateTokens(turns[start].text);
      start++;
    }
    return turns.sublist(start);
  }

  int _estimateTokens(String text) => (text.length / 4).ceil();
}

/// App-wide context assembler. Overridable in tests (e.g. a tiny budget to exercise overflow).
final contextAssemblerProvider = Provider<ContextAssembler>((ref) {
  return const ContextAssembler();
});
