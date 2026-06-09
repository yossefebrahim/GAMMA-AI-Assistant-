import 'package:ai_assistant/data/images/image_file_store.dart';
import 'package:ai_assistant/data/repositories/drift_conversation_repository.dart';
import 'package:ai_assistant/domain/entities/chat_turn.dart';
import 'package:ai_assistant/domain/entities/image_attachment.dart';
import 'package:ai_assistant/domain/entities/image_input.dart';
import 'package:ai_assistant/domain/entities/message.dart';
import 'package:ai_assistant/domain/services/gemma_service.dart';
import 'package:ai_assistant/features/chat/attachment_controller.dart';
import 'package:ai_assistant/features/chat/context_assembler.dart';
import 'package:ai_assistant/infrastructure/gemma/flutter_gemma_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Chat surface state: which conversation is open and whether a reply is generating. Messages
/// themselves come reactively from [chatMessagesProvider]; this holds only the control state.
class ChatState {
  const ChatState({this.conversationId, this.isGenerating = false, this.errorMessage});

  final int? conversationId;
  final bool isGenerating;

  /// A clear, dismissible message surfaced on honest failure (e.g. an unprocessable image —
  /// FR-020). Null when there is nothing to show.
  final String? errorMessage;

  ChatState copyWith({
    int? conversationId,
    bool? isGenerating,
    String? errorMessage,
    bool clearError = false,
  }) {
    return ChatState(
      conversationId: conversationId ?? this.conversationId,
      isGenerating: isGenerating ?? this.isGenerating,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    );
  }
}

/// Owns send/stream/stop for the chat (FR-012–FR-014). Persists the user turn, opens a `streaming`
/// assistant turn, consumes the [GemmaService] token stream appending deltas, and finalizes the
/// turn as `complete` or — on stop — `stoppedPartial`, retaining 100% of the produced text
/// (SC-005). Only one generation is in flight at a time (Q4).
class ChatController extends Notifier<ChatState> {
  bool _stopRequested = false;

  /// Shown when the active model/device cannot process an attached image (FR-020).
  static const String imageErrorMessage =
      "couldn't process this image — try another, or send without it";

  @override
  ChatState build() => const ChatState();

  /// Point the chat at an existing conversation (US4) or null for a fresh thread.
  void openConversation(int? conversationId) {
    state = ChatState(conversationId: conversationId);
  }

  /// Send a turn (FR-012). [text] may be empty when an [image] is attached (FR-004). When an image
  /// is present it is copied into app-private storage, persisted on the user message, and its bytes
  /// are read just-in-time and handed to `generate` (Principle VIII — not retained after the call).
  Future<void> send(String text, {PendingAttachment? image}) async {
    if (state.isGenerating) return; // single in-flight (Q4)
    final trimmed = text.trim();
    if (trimmed.isEmpty && image == null) return; // nothing to send (FR-004)

    final repo = ref.read(conversationRepositoryProvider);
    final imageStore = ref.read(imageFileStoreProvider);

    // Persist the image bytes as an app-private file FIRST, and read the bytes just-in-time for this
    // prompt (FR-012, R5). An oversized/unreadable image is rejected here (FR-021) before anything
    // is created — surface "pick another" and abort the send.
    ImageAttachment? attachment;
    ImageInput? imageInput;
    if (image != null) {
      try {
        final storedPath =
            await imageStore.persist(image.path, extension: _extensionOf(image.path));
        attachment = ImageAttachment(path: storedPath, mimeType: image.mimeType);
        imageInput = ImageInput(await imageStore.readBytes(storedPath), mimeType: image.mimeType);
      } on ArgumentError {
        ref.read(attachmentControllerProvider.notifier).rejectPending();
        return;
      }
    }

    var conversationId = state.conversationId;
    conversationId ??= (await repo.createConversation()).id;

    await repo.appendUserMessage(conversationId, trimmed, image: attachment);

    // Assemble the sliding-window context (FR-017, Q2). Exclude the user turn just appended — it is
    // passed separately as the prompt — and let the assembler trim oldest turns to the token budget.
    final turns = await repo.loadTurns(conversationId);
    final priorMessages = turns.take(turns.length - 1).toList();
    final history = await _assembleHistory(priorMessages, imageStore);

    final assistantId = await repo.beginAssistantMessage(conversationId);
    _stopRequested = false;
    // Starting a fresh generation clears any prior error.
    state = state.copyWith(conversationId: conversationId, isGenerating: true, clearError: true);
    // The send succeeded in starting — drop the pending attachment from the composer (FR-004).
    if (image != null) ref.read(attachmentControllerProvider.notifier).clear();

    final gemma = ref.read(gemmaServiceProvider);
    final buffer = StringBuffer();

    // Persisting EVERY delta re-queried and rebuilt the whole message list per token (a DB write →
    // drift watch → ListView rebuild, ~dozens of times/s), which is most of the streaming jank.
    // Throttle: the first delta lands immediately (the bubble swaps its pulse for text right
    // away), then at most one write per [_flushInterval]; [flush] is ALWAYS called again before
    // finalize — including the stop and error paths — so no produced token is ever dropped
    // (FR-014) and the persisted turn always ends complete.
    var persistedLength = 0;
    final flushClock = Stopwatch()..start();
    Future<void> flush() async {
      if (buffer.length == persistedLength) return;
      persistedLength = buffer.length;
      await repo.updateAssistantContent(assistantId, buffer.toString());
    }

    try {
      await for (final delta
          in gemma.generate(history: history, prompt: trimmed, image: imageInput)) {
        buffer.write(delta);
        if (persistedLength == 0 || flushClock.elapsed >= _flushInterval) {
          flushClock.reset();
          await flush();
        }
        // Retain every delta the model produced before honoring stop (FR-014): the post-loop
        // flush below persists anything still buffered, so breaking here drops nothing.
        if (_stopRequested) break;
      }
      await flush();
      await repo.finalizeAssistantMessage(
        assistantId,
        _stopRequested ? MessageStatus.stoppedPartial : MessageStatus.complete,
      );
    } on ImageProcessingException {
      // Honest failure (FR-020): finalize the turn cleanly (no hang/crash) and surface a clear,
      // dismissible message. Any partial text already streamed is retained.
      await flush();
      await repo.finalizeAssistantMessage(assistantId, MessageStatus.stoppedPartial);
      state = state.copyWith(errorMessage: imageErrorMessage);
    } catch (_) {
      // Other mid-stream failures: keep whatever text arrived as a stopped-partial turn.
      await flush();
      await repo.finalizeAssistantMessage(assistantId, MessageStatus.stoppedPartial);
    } finally {
      state = state.copyWith(isGenerating: false);
    }
  }

  /// Minimum spacing between mid-stream persistence writes (~10 visible updates/s — smooth to
  /// read, while cutting the per-token DB→watch→rebuild churn that janked the keyboard and list).
  static const Duration _flushInterval = Duration(milliseconds: 100);

  /// Dismiss the current error message (FR-020) — the conversation stays usable.
  void dismissError() => state = state.copyWith(clearError: true);

  /// Assemble the sliding-window context (FR-017). Image-bearing history turns get their bytes read
  /// just-in-time so follow-ups keep referring to the earlier image (FR-015/FR-016); the bytes live
  /// only in the local map handed to the assembler and are released after `generate` returns — they
  /// are not retained between turns (Principle VIII).
  Future<List<ChatTurn>> _assembleHistory(
    List<Message> priorMessages,
    ImageFileStore imageStore,
  ) async {
    final images = <int, ImageInput>{};
    for (final message in priorMessages) {
      final image = message.image;
      if (image != null) {
        images[message.id] =
            ImageInput(await imageStore.readBytes(image.path), mimeType: image.mimeType);
      }
    }
    return ref.read(contextAssemblerProvider).assemble(priorMessages, images: images);
  }

  /// The dotted extension of a picker temp path, defaulting to `.jpg`.
  String _extensionOf(String path) {
    final dot = path.lastIndexOf('.');
    final slash = path.lastIndexOf('/');
    if (dot > slash && dot != -1 && dot < path.length - 1) return path.substring(dot);
    return '.jpg';
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
