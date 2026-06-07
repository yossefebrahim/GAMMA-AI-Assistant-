import 'package:ai_assistant/data/repositories/drift_conversation_repository.dart';
import 'package:ai_assistant/domain/entities/message.dart';
import 'package:ai_assistant/features/chat/context_assembler.dart';
import 'package:ai_assistant/infrastructure/gemma/flutter_gemma_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Chat surface state: which conversation is open and whether a reply is generating. Messages
/// themselves come reactively from [chatMessagesProvider]; this holds only the control state.
class ChatState {
  const ChatState({this.conversationId, this.isGenerating = false});

  final int? conversationId;
  final bool isGenerating;

  ChatState copyWith({int? conversationId, bool? isGenerating}) {
    return ChatState(
      conversationId: conversationId ?? this.conversationId,
      isGenerating: isGenerating ?? this.isGenerating,
    );
  }
}

/// Owns send/stream/stop for the chat (FR-012–FR-014). Persists the user turn, opens a `streaming`
/// assistant turn, consumes the [GemmaService] token stream appending deltas, and finalizes the
/// turn as `complete` or — on stop — `stoppedPartial`, retaining 100% of the produced text
/// (SC-005). Only one generation is in flight at a time (Q4).
class ChatController extends Notifier<ChatState> {
  bool _stopRequested = false;

  @override
  ChatState build() => const ChatState();

  /// Point the chat at an existing conversation (US4) or null for a fresh thread.
  void openConversation(int? conversationId) {
    state = ChatState(conversationId: conversationId);
  }

  Future<void> send(String text) async {
    if (state.isGenerating) return; // single in-flight (Q4)
    final trimmed = text.trim();
    if (trimmed.isEmpty) return; // empty/whitespace send prevented (edge case)

    final repo = ref.read(conversationRepositoryProvider);
    var conversationId = state.conversationId;
    conversationId ??= (await repo.createConversation()).id;

    await repo.appendUserMessage(conversationId, trimmed);

    // Assemble the sliding-window context (FR-017, Q2). Exclude the user turn just appended — it is
    // passed separately as the prompt — and let the assembler trim oldest turns to the token budget.
    final turns = await repo.loadTurns(conversationId);
    final priorMessages = turns.take(turns.length - 1).toList();
    final history = ref.read(contextAssemblerProvider).assemble(priorMessages);

    final assistantId = await repo.beginAssistantMessage(conversationId);
    _stopRequested = false;
    state = state.copyWith(conversationId: conversationId, isGenerating: true);

    final gemma = ref.read(gemmaServiceProvider);
    final buffer = StringBuffer();
    try {
      await for (final delta in gemma.generate(history: history, prompt: trimmed)) {
        if (_stopRequested) break;
        buffer.write(delta);
        await repo.updateAssistantContent(assistantId, buffer.toString());
      }
      await repo.finalizeAssistantMessage(
        assistantId,
        _stopRequested ? MessageStatus.stoppedPartial : MessageStatus.complete,
      );
    } catch (_) {
      // Mid-stream failure: keep whatever text arrived as a stopped-partial turn (never lose it).
      await repo.finalizeAssistantMessage(assistantId, MessageStatus.stoppedPartial);
    } finally {
      state = state.copyWith(isGenerating: false);
    }
  }

  /// Halt the in-flight reply within ~1s (FR-014); the partial text is retained by [send]'s
  /// finalize path as `stoppedPartial`.
  Future<void> stop() async {
    if (!state.isGenerating) return;
    _stopRequested = true;
    await ref.read(gemmaServiceProvider).stop();
  }
}

final chatControllerProvider =
    NotifierProvider<ChatController, ChatState>(ChatController.new);

/// Reactive ordered messages for a conversation (FR-013/FR-020) — the streaming assistant turn's
/// content updates live as deltas land.
final chatMessagesProvider =
    StreamProvider.autoDispose.family<List<Message>, int>((ref, conversationId) {
  return ref.watch(conversationRepositoryProvider).watchMessages(conversationId);
});
