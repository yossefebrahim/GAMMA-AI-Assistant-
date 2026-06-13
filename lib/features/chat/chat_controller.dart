import 'dart:async';
import 'dart:io';

import 'package:ai_assistant/core/audio_constants.dart';
import 'package:ai_assistant/core/media_file_extension.dart';
import 'package:ai_assistant/core/tools/tool_registry.dart';
import 'package:ai_assistant/data/audio/audio_file_store.dart';
import 'package:ai_assistant/data/images/image_file_store.dart';
import 'package:ai_assistant/data/repositories/drift_conversation_repository.dart';
import 'package:ai_assistant/data/repositories/drift_memory_repository.dart';
import 'package:ai_assistant/data/repositories/settings_repository.dart';
import 'package:ai_assistant/domain/entities/audio_attachment.dart';
import 'package:ai_assistant/domain/entities/audio_input.dart';
import 'package:ai_assistant/domain/entities/chat_turn.dart';
import 'package:ai_assistant/domain/entities/generation_event.dart';
import 'package:ai_assistant/domain/entities/image_attachment.dart';
import 'package:ai_assistant/domain/entities/image_input.dart';
import 'package:ai_assistant/domain/entities/message.dart';
import 'package:ai_assistant/domain/entities/pending_recording.dart';
import 'package:ai_assistant/domain/entities/tool_outcome.dart';
import 'package:ai_assistant/domain/entities/web_access_override.dart';
import 'package:ai_assistant/domain/repositories/conversation_repository.dart';
import 'package:ai_assistant/domain/services/gemma_service.dart';
import 'package:ai_assistant/features/chat/attachment_controller.dart';
import 'package:ai_assistant/features/chat/chat_providers.dart';
import 'package:ai_assistant/features/chat/context_assembler.dart';
import 'package:ai_assistant/features/chat/recording_controller.dart';
import 'package:ai_assistant/features/chat/session_instruction.dart';
import 'package:ai_assistant/features/chat/tool_handler_providers.dart';
import 'package:ai_assistant/infrastructure/gemma/flutter_gemma_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Chat surface state: which conversation is open and whether a reply is generating. Messages
/// themselves come reactively from [chatMessagesProvider]; this holds only the control state.
class ChatState {
  const ChatState({
    this.conversationId,
    this.isGenerating = false,
    this.errorMessage,
  });

  final int? conversationId;
  final bool isGenerating;

  /// A clear, dismissible message surfaced on honest failure (e.g. an unprocessable image —
  /// FR-020 — or clip, 003 FR-022). Null when there is nothing to show.
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

  /// Shown when the active model/device cannot process the sent clip (003 FR-022, research R7.3).
  static const String audioErrorMessage =
      "couldn't process this audio — try a shorter clip, or send without it";

  @override
  ChatState build() {
    // One-time startup sweep: finalize any `running` tool rows left by a killed process to
    // `error('interrupted')` so reopened history never shows an in-flight chip (data-model §4
    // terminal-state guarantee). Fire-and-forget — it must not block the chat surface.
    unawaited(
      ref.read(conversationRepositoryProvider).sweepStaleToolInvocations(),
    );
    return const ChatState();
  }

  /// Point the chat at an existing conversation (US4) or null for a fresh thread. A pending voice
  /// clip belongs to the compose it was recorded in — it is cleared on the switch (003 spec Q3,
  /// data-model §4: conversation switch → idle, temp file deleted).
  ///
  /// MEMORY (005, T024 / data-model §4 "session boundary"): after updating state, a fresh system
  /// instruction is composed from the CURRENT active facts + flags, and [GemmaService.startSession]
  /// is called on the loaded model so the NEW conversation is grounded in facts saved in prior
  /// sessions (FR-008). If no model is loaded yet the composition is skipped — the session provider
  /// will compose and apply the instruction when the model loads via [loadModel]. Fire-and-forget:
  /// the chat surface is immediately usable; the session refresh completes asynchronously.
  Future<void> openConversation(int? conversationId) async {
    // Set state synchronously (before any await) so callers that read
    // chatControllerProvider.state.conversationId immediately after calling
    // openConversation see the new value without needing to await the Future.
    state = ChatState(conversationId: conversationId);
    // Mirror the open conversation into the memory-provenance notifier so a `remember_fact`
    // captured in this conversation records its sourceConversationId (F2 / contract guarantee 4).
    ref.read(activeConversationIdProvider.notifier).set(conversationId);
    await ref.read(recordingControllerProvider.notifier).reset();
    await _refreshSession();
  }

  /// Compose the current system instruction from live state and apply it to the chat session
  /// (data-model §4 session-boundary rule). No-op when no model is loaded (cold start / between
  /// sessions) — the instruction is composed fresh at [loadModel] time by the session provider.
  /// Delegates to the shared [refreshSessionInstruction] helper (F3 — one composition site).
  Future<void> _refreshSession() => refreshSessionInstruction(ref);

  /// Toggle the per-conversation web-access override (006 US3, T045, FR-008/FR-009/FR-032).
  ///
  /// Two effects, both BEFORE the next user turn:
  ///   1. Persist [override] on the conversation row via [ConversationRepository.setWebAccessOverride]
  ///      and refresh the family provider so the composer toggle reflects the new state immediately.
  ///   2. Recreate the model session with the RECOMPUTED tool list. A bare [GemmaService.startSession]
  ///      is NOT enough: the seam reuses the tool list baked at [loadModel], so a new
  ///      `systemInstruction` does not add/remove the web tools. Invalidating [modelSessionProvider]
  ///      forces it to recompute the triple-gated `declaredTools` and reload the model with the new
  ///      list — so flipping the override genuinely adds or removes `web_search`/`fetch_page` for the
  ///      next turn (FR-032). No-op on the session side when no conversation is open yet.
  Future<void> toggleWebAccess(WebAccessOverride override) async {
    final conversationId = state.conversationId;
    if (conversationId == null) return; // no thread to persist against yet
    await ref
        .read(conversationRepositoryProvider)
        .setWebAccessOverride(conversationId, override);
    // Re-read the persisted override so the composer toggle reflects the change immediately.
    ref.invalidate(conversationWebOverrideProvider(conversationId));
    // Recompute the declared tool list and recreate the session (the seam re-bakes tools at
    // loadModel — startSession alone would keep the stale list).
    ref.invalidate(modelSessionProvider);
    // Materialise the rebuilt session so the reload runs now (BEFORE the next turn), not lazily on
    // the next watcher. Swallow a load failure here — the chat surface stays usable and the next
    // send will surface any genuine model error.
    try {
      await ref.read(modelSessionProvider.future);
    } catch (_) {
      // Session reload failure is handled by the chat screen's _ModelError surface on next build.
    }
  }

  /// Send a turn (FR-012). [text] may be empty when an [image] or [audio] clip is attached
  /// (FR-004); at most one of the two is given (audio XOR image, 003 spec Q3 — enforced upstream
  /// by the controllers). Attachment bytes are copied into app-private storage at send, persisted
  /// on the user message, and read just-in-time for `generate` (Principle VIII — not retained
  /// after the call).
  Future<void> send(
    String text, {
    PendingAttachment? image,
    PendingRecording? audio,
  }) async {
    if (state.isGenerating) return; // single in-flight (Q4)
    final trimmed = text.trim();
    if (trimmed.isEmpty && image == null && audio == null) {
      return; // nothing to send (FR-004)
    }

    final repo = ref.read(conversationRepositoryProvider);
    final imageStore = ref.read(imageFileStoreProvider);
    final audioStore = ref.read(audioFileStoreProvider);

    // Persist the attachment bytes as an app-private file FIRST, and read the bytes just-in-time
    // for this prompt (FR-012, R5/R6). An oversized/unreadable file is rejected here, BEFORE any
    // row is created (002 DF-2: FileSystemException is caught alongside ArgumentError) — surface
    // "pick another" / "record again" and abort the send.
    ImageAttachment? imageAttachment;
    ImageInput? imageInput;
    if (image != null) {
      try {
        final storedPath = await imageStore.persist(
          image.path,
          extension: mediaFileExtension(
            mimeType: image.mimeType,
            path: image.path,
            fallback: '.jpg',
          ),
        );
        imageAttachment = ImageAttachment(
          path: storedPath,
          mimeType: image.mimeType,
        );
        imageInput = ImageInput(
          await imageStore.readBytes(storedPath),
          mimeType: image.mimeType,
        );
      } on ArgumentError {
        ref.read(attachmentControllerProvider.notifier).rejectPending();
        return;
      } on FileSystemException {
        ref.read(attachmentControllerProvider.notifier).rejectPending();
        return;
      }
    }
    AudioAttachment? audioAttachment;
    AudioInput? audioInput;
    if (audio != null) {
      final mimeType = audio.mimeType ?? AudioConstants.wavMimeType;
      try {
        final storedPath = await audioStore.persist(
          audio.path,
          mimeType: mimeType,
        );
        audioAttachment = AudioAttachment(path: storedPath, mimeType: mimeType);
        audioInput = AudioInput(
          await audioStore.readBytes(storedPath),
          mimeType: mimeType,
        );
      } on ArgumentError {
        await ref.read(recordingControllerProvider.notifier).rejectPending();
        return;
      } on FileSystemException {
        await ref.read(recordingControllerProvider.notifier).rejectPending();
        return;
      }
    }

    var conversationId = state.conversationId;
    if (conversationId == null) {
      // Lazy-create on first send of a fresh thread: the row didn't exist until now, so update the
      // provenance notifier too or a first-message `remember_fact` would still capture a null id
      // (F2 — the lazy-create gap the audit caught).
      conversationId = (await repo.createConversation()).id;
      ref.read(activeConversationIdProvider.notifier).set(conversationId);
    }

    await repo.appendUserMessage(
      conversationId,
      trimmed,
      image: imageAttachment,
      audio: audioAttachment,
    );

    // Assemble the sliding-window context (FR-017, Q2). Exclude the user turn just appended — it is
    // passed separately as the prompt — and let the assembler trim oldest turns to the token budget.
    final turns = await repo.loadTurns(conversationId);
    final priorMessages = turns.take(turns.length - 1).toList();
    final history = await _assembleHistory(
      priorMessages,
      imageStore,
      audioStore,
    );

    final assistantId = await repo.beginAssistantMessage(conversationId);
    _stopRequested = false;
    // Starting a fresh generation clears any prior error.
    state = state.copyWith(
      conversationId: conversationId,
      isGenerating: true,
      clearError: true,
    );
    // The send succeeded in starting — drop the pending attachment from the composer (FR-004).
    if (image != null) ref.read(attachmentControllerProvider.notifier).clear();
    if (audio != null) {
      await ref.read(recordingControllerProvider.notifier).clearAfterSend();
    }

    final gemma = ref.read(gemmaServiceProvider);

    try {
      final buffer = StringBuffer();
      final toolCall = await _pumpStream(
        gemma.generate(
          history: history,
          prompt: trimmed,
          image: imageInput,
          audio: audioInput,
        ),
        repo,
        assistantId,
        buffer,
      );
      if (toolCall == null) {
        // Text-only turn (parity with 003): finalize complete, or stoppedPartial on stop (FR-014).
        await repo.finalizeAssistantMessage(
          assistantId,
          _stopRequested
              ? MessageStatus.stoppedPartial
              : MessageStatus.complete,
        );
      } else {
        // The model asked to call a tool — run the data-model §4 state machine.
        await _runToolTurn(
          repo,
          gemma,
          conversationId,
          assistantId,
          buffer,
          toolCall,
        );
      }
    } on ImageProcessingException {
      // Honest failure (FR-020): finalize cleanly + surface a dismissible message. Image/audio
      // failures only arise from the INITIAL generate (the current prompt's media), so the
      // assistant row to finalize is always [assistantId]. Partial text was already persisted by
      // [_pumpStream]'s finally.
      await repo.finalizeAssistantMessage(
        assistantId,
        MessageStatus.stoppedPartial,
      );
      state = state.copyWith(errorMessage: imageErrorMessage);
    } on AudioProcessingException {
      // The audio edition of the same honest-failure rule (003 FR-022, US6). Narrowly scoped to the
      // current prompt's clip (guarantee 15).
      await repo.finalizeAssistantMessage(
        assistantId,
        MessageStatus.stoppedPartial,
      );
      state = state.copyWith(errorMessage: audioErrorMessage);
    } catch (_) {
      // Other mid-stream failures on the initial generate: keep whatever text arrived.
      await repo.finalizeAssistantMessage(
        assistantId,
        MessageStatus.stoppedPartial,
      );
    } finally {
      state = state.copyWith(isGenerating: false);
    }
  }

  /// Drain a [GenerationEvent] stream into [assistantId], appending [TextDelta] tokens to [buffer]
  /// with the throttled-persist machinery (the first delta lands immediately; then ≤ one write per
  /// [_flushInterval]; a final flush ALWAYS runs — including on stop and stream error — so no token
  /// is dropped, FR-014). Returns the terminating [ToolCallRequested] if the stream ended in one
  /// (guarantee 21), else null. Re-raises stream errors AFTER flushing the partial text.
  Future<ToolCallRequested?> _pumpStream(
    Stream<GenerationEvent> stream,
    ConversationRepository repo,
    int assistantId,
    StringBuffer buffer,
  ) async {
    var persistedLength = buffer.length;
    final flushClock = Stopwatch()..start();
    Future<void> flush() async {
      if (buffer.length == persistedLength) return;
      persistedLength = buffer.length;
      await repo.updateAssistantContent(assistantId, buffer.toString());
    }

    ToolCallRequested? toolCall;
    try {
      await for (final event in stream) {
        if (event is ToolCallRequested) {
          // The final event of the stream (guarantee 21) — stop draining and hand it back.
          toolCall = event;
          break;
        }
        buffer.write((event as TextDelta).token);
        if (persistedLength == 0 || flushClock.elapsed >= _flushInterval) {
          flushClock.reset();
          await flush();
        }
        if (_stopRequested) break;
      }
    } finally {
      // Persist anything still buffered on every exit path — normal end, stop, or error.
      await flush();
    }
    return toolCall;
  }

  /// The tool-turn state machine (data-model §4). Applies the ordering rule (empty assistant row
  /// deleted / text row finalized), persists the tool row, dispatches, finalizes the chip, then —
  /// unless stop ended the turn — resumes generation into a NEW assistant row. A second tool call
  /// on resume is chipped as an error and the turn ends as text (FR-006/FR-024). Never throws.
  Future<void> _runToolTurn(
    ConversationRepository repo,
    GemmaService gemma,
    int conversationId,
    int preCallAssistantId,
    StringBuffer preCallBuffer,
    ToolCallRequested call,
  ) async {
    // Ordering rule: history must read user → (optional text) → chip → answer. An empty streaming
    // assistant row is removed; one that already streamed text is finalized as complete.
    if (preCallBuffer.isEmpty) {
      await repo.deleteMessage(preCallAssistantId);
    } else {
      await repo.finalizeAssistantMessage(
        preCallAssistantId,
        MessageStatus.complete,
      );
    }

    // Coerce whole-valued doubles → int so the chip displays "300" not "300.0" (P2). The
    // dispatcher also coerces, so this is belt-and-suspenders on the dispatch side.
    final normalizedArgs = _normalizeToolArgs(call.name, call.args);

    final toolRowId = await repo.appendToolInvocation(
      conversationId: conversationId,
      toolName: call.name,
      args: normalizedArgs,
    );

    // Stop before dispatch → `skipped`, nothing executed, turn ends (FR-026). `skipped` is reserved
    // for exactly this case.
    if (_stopRequested) {
      await repo.finalizeToolInvocation(
        toolRowId,
        status: ToolCallStatus.skipped,
        summary: _appendExtras('skipped', call.extraCallCount),
      );
      return;
    }

    final outcome = await ref
        .read(toolDispatcherProvider)
        .dispatch(call.name, normalizedArgs);
    // The model-facing payload carries the full handler result — including the web tools' transient
    // `content`/`text` body, which the model needs to ground its reply on resume.
    final resultPayload = _resultPayloadOf(outcome);
    await repo.finalizeToolInvocation(
      toolRowId,
      status: outcome is ToolSuccess
          ? ToolCallStatus.success
          : ToolCallStatus.error,
      // The PERSISTED payload strips the web tools' body text so only metadata + source URLs land in
      // the DB (006 T049, Decision 4, FR-024, SC-008) — the snippet/extracted text is in-session only.
      result: _persistedResultPayloadOf(call.name, resultPayload),
      summary: _appendExtras(
        _summaryOf(outcome, toolName: call.name, args: normalizedArgs),
        call.extraCallCount,
      ),
    );

    // Stop after dispatch → the (fast, local) handler completed and the row finalized truthfully,
    // but no resume — the turn ends (FR-026); never a half-recorded execution.
    if (_stopRequested) return;

    // Resume: stream the final, grounded reply into a NEW assistant row. Errors here keep partial
    // text as stoppedPartial — never a crash (Principle V).
    final newAssistantId = await repo.beginAssistantMessage(conversationId);
    final resumeBuffer = StringBuffer();
    try {
      final secondCall = await _pumpStream(
        gemma.resumeWithToolResult(toolName: call.name, result: resultPayload),
        repo,
        newAssistantId,
        resumeBuffer,
      );
      if (secondCall == null) {
        await repo.finalizeAssistantMessage(
          newAssistantId,
          _stopRequested
              ? MessageStatus.stoppedPartial
              : MessageStatus.complete,
        );
      } else {
        // Second call on resume → its own error chip; the turn ends as text (FR-006/FR-024).
        if (resumeBuffer.isEmpty) {
          await repo.deleteMessage(newAssistantId);
        } else {
          await repo.finalizeAssistantMessage(
            newAssistantId,
            MessageStatus.complete,
          );
        }
        final secondRowId = await repo.appendToolInvocation(
          conversationId: conversationId,
          toolName: secondCall.name,
          args: secondCall.args,
        );
        await repo.finalizeToolInvocation(
          secondRowId,
          status: ToolCallStatus.error,
          // Canonical one-tool-per-turn message (contracts/web_research_tools.md §Dispatcher
          // coercion/bounding 3, FR-028, spike §4.3) — a second tool call on the resumed stream is
          // chipped-and-skipped, never executed.
          result: const {'error': 'call skipped — one tool per turn'},
          summary: 'call skipped — one tool per turn',
        );
      }
    } catch (_) {
      await repo.finalizeAssistantMessage(
        newAssistantId,
        MessageStatus.stoppedPartial,
      );
    }
  }

  /// The result map persisted on the chip AND fed to the model on resume. Success carries the
  /// handler payload; every failure carries `{error: reason}` so the model acknowledges it honestly
  /// (FR-022/023/025).
  Map<String, Object?> _resultPayloadOf(ToolOutcome outcome) =>
      switch (outcome) {
        ToolSuccess(:final result) => result,
        ToolUnknown(:final attemptedName) => {
          'error': 'unknown tool: $attemptedName',
        },
        ToolInvalidArgs(:final reason) => {'error': reason},
        ToolFailure(:final reason) => {'error': reason},
      };

  /// The payload PERSISTED on the tool row, derived from the model-facing [payload] (006 T049,
  /// Decision 4 / FR-024 / SC-008). Web tools strip their transient body text before the row is
  /// written so the DB only ever holds metadata + answer-grounding source URLs — never the Tavily
  /// `content` snippet bodies or the `fetch_page` extracted text:
  ///   • `web_search` → `{results:[{title,url},…], sourceUrls:[…]}` (drops each result's `content`
  ///     and `score`; a zero-results/`note`-only or `{error}` payload passes through unchanged).
  ///   • `fetch_page` → `{url, truncated, sourceUrls}` (drops `text`).
  ///   • all other tools (device/memory) and any `{error}` row → [payload] unchanged.
  /// The body text remains in [resultPayload] fed to [GemmaService.resumeWithToolResult] — only the
  /// DB write is stripped.
  Map<String, Object?> _persistedResultPayloadOf(
    String toolName,
    Map<String, Object?> payload,
  ) {
    // Error rows ({error: …}) and any non-web tool persist verbatim.
    if (payload.containsKey('error')) return payload;
    switch (toolName) {
      case 'web_search':
        final results = payload['results'];
        if (results is! List) {
          return payload; // unexpected shape — persist verbatim
        }
        return {
          'results': [
            for (final r in results)
              if (r is Map) {'title': r['title'], 'url': r['url']},
          ],
          // The zero-results path carries a `note` (and no sourceUrls) — preserve it verbatim so the
          // chip/history keep the "no results found" provenance (FR-033).
          'note': ?payload['note'],
          'sourceUrls': ?payload['sourceUrls'],
        };
      case 'fetch_page':
        return {
          'url': ?payload['url'],
          'truncated': ?payload['truncated'],
          'sourceUrls': ?payload['sourceUrls'],
        };
      default:
        return payload;
    }
  }

  /// The chip's quiet one-line summary (lowercase microcopy, display only — never fed to the model).
  ///
  /// [toolName] is threaded from [_runToolTurn] so memory tools get their spec-mandated wording
  /// (data-model §5 chip table) instead of the generic key-value fallback.
  String _summaryOf(
    ToolOutcome outcome, {
    required String toolName,
    Map<String, Object?> args = const <String, Object?>{},
  }) => switch (outcome) {
    ToolSuccess(:final result, :final truncated) =>
      _summarizeSuccess(toolName, result, args) +
          (truncated ? ' · truncated' : ''),
    ToolUnknown(:final attemptedName) => 'unknown tool: $attemptedName',
    ToolInvalidArgs(:final reason) => reason.toLowerCase(),
    ToolFailure(:final reason) => reason.toLowerCase(),
  };

  /// Note discarded parallel calls on the same chip (FR-024).
  String _appendExtras(String summary, int extra) => extra > 0
      ? '$summary · +$extra parallel ${extra == 1 ? 'call' : 'calls'} not executed'
      : summary;

  /// Routes success summary: memory tools get spec-mandated wording (data-model §5 chip table);
  /// device tools fall through to the generic [_summarizeResult].
  String _summarizeSuccess(
    String toolName,
    Map<String, Object?> result,
    Map<String, Object?> args,
  ) {
    switch (toolName) {
      case 'remember_fact':
        return _rememberFactSummary(result);
      case 'forget_fact':
        return _forgetFactSummary(result);
      case 'web_search':
        return _webSearchSummary(result, args);
      case 'fetch_page':
        return _fetchPageSummary(result, args);
      default:
        return _summarizeResult(result);
    }
  }

  /// Chip wording for a `web_search` success (006 T033, FR-012):
  ///   ≥1 result → `N results for "<query>"`
  ///   0 results → `0 results`
  ///
  /// The result count comes from the handler's `results` array; the query is the validated arg.
  String _webSearchSummary(
    Map<String, Object?> result,
    Map<String, Object?> args,
  ) {
    final results = result['results'];
    final count = results is List ? results.length : 0;
    if (count == 0) return '0 results';
    final query = (args['query'] as String?)?.trim() ?? '';
    return '$count results for "$query"';
  }

  /// Chip wording for a `fetch_page` success (006 T037, FR-016): `fetched <domain>`, where the
  /// domain is `Uri.parse(url).host` of the fetched URL (the handler echoes the final URL).
  String _fetchPageSummary(
    Map<String, Object?> result,
    Map<String, Object?> args,
  ) {
    final url = (result['url'] as String?) ?? (args['url'] as String?) ?? '';
    final host = Uri.tryParse(url)?.host ?? '';
    return host.isEmpty ? 'fetched' : 'fetched $host';
  }

  /// Chip wording for a `remember_fact` success (data-model §5):
  ///   created   → `remembered: <fact>`
  ///   superseded → `updated: <fact>`
  ///   unchanged → `noted: <fact>`
  ///
  /// The handler (T015) puts exactly one of `remembered`, `updated`, or `noted` in the result map,
  /// keyed by its outcome string, with the canonical fact as the value.
  String _rememberFactSummary(Map<String, Object?> result) {
    for (final key in const ['remembered', 'updated', 'noted']) {
      final value = result[key];
      if (value != null) return '$key: $value'.toLowerCase();
    }
    // Fallback: should never reach here if the handler follows the contract.
    return _summarizeResult(result);
  }

  /// Chip wording for a `forget_fact` success (data-model §5): `forgot #<id>`.
  ///
  /// The handler (T015) puts the forgotten id under the `forgot` key.
  String _forgetFactSummary(Map<String, Object?> result) {
    final id = result['forgot'];
    if (id != null) return 'forgot #$id';
    return _summarizeResult(result);
  }

  /// A generic, compact lowercase summary of a success result: up to three scalar `key value`
  /// pairs. Tool-agnostic by design (the dispatcher/controller stay generic); the chip also renders
  /// the full args/result. Device wording is tuned in quickstart V6 (T049).
  String _summarizeResult(Map<String, Object?> result) {
    final parts = <String>[];
    for (final entry in result.entries) {
      final value = entry.value;
      if (value is Map || value is List) continue;
      parts.add('${entry.key} $value'.toLowerCase());
      if (parts.length >= 3) break;
    }
    return parts.isEmpty ? 'done' : parts.join(' · ');
  }

  /// Minimum spacing between mid-stream persistence writes (~10 visible updates/s — smooth to
  /// read, while cutting the per-token DB→watch→rebuild churn that janked the keyboard and list).
  static const Duration _flushInterval = Duration(milliseconds: 100);

  /// Dismiss the current error message (FR-020) — the conversation stays usable.
  void dismissError() => state = state.copyWith(clearError: true);

  /// Assemble the sliding-window context (FR-017). Media-bearing history turns get their bytes
  /// read just-in-time so follow-ups keep referring to the earlier image/clip (FR-015/FR-016;
  /// 003 FR-016/FR-017); the bytes live only in the local maps handed to the assembler and are
  /// released after `generate` returns — they are not retained between turns (Principle VIII).
  /// The assembler itself stays pure (no file I/O) — bytes are injected via the id-keyed maps.
  Future<List<ChatTurn>> _assembleHistory(
    List<Message> priorMessages,
    ImageFileStore imageStore,
    AudioFileStore audioStore,
  ) async {
    final images = <int, ImageInput>{};
    final audio = <int, AudioInput>{};
    for (final message in priorMessages) {
      final messageImage = message.image;
      if (messageImage != null) {
        images[message.id] = ImageInput(
          await imageStore.readBytes(messageImage.path),
          mimeType: messageImage.mimeType,
        );
      }
      final messageAudio = message.audio;
      if (messageAudio != null) {
        audio[message.id] = AudioInput(
          await audioStore.readBytes(messageAudio.path),
          mimeType: messageAudio.mimeType,
        );
      }
    }
    // Reserve the R6 tool-use system-instruction budget when the active model can call tools
    // (~40 tokens off the top so a long history can't crowd it out).
    final reserveToolInstruction = ref
        .read(modelCapabilitiesProvider)
        .functionCalling;
    // Reserve the memory budget too (T025): the facts block (~225 tok) when memory is on AND ≥1
    // fact exists, and the capture instruction (~86 tok) when function calling AND memory are both
    // active — mirroring SystemInstructionComposer.compose's gating so the injected block can never
    // be crowded out by a long history.
    //
    // Session-boundary approximation: the reserve reflects CURRENT store state, while the injected
    // block is fixed at session start. A fact added mid-session reserves before the block exists
    // (conservative — harmless); facts cleared mid-session under-reserve for an already-injected
    // block (rare window, corrected at the next openConversation). The alternative — snapshotting
    // the composed-instruction flags at each startSession/loadModel site — was rejected for a
    // ≤311-token edge case.
    final memoryEnabled = ref.read(memoryEnabledProvider);
    final hasFacts =
        (await ref.read(memoryRepositoryProvider).activeCount()) > 0;
    // Reserve the web tool-use budget (~80 tok, 006 T032) when the web tools are declared — the
    // same triple gate the session provider applies (functionCalling AND webAccessEnabled AND a
    // valid key), so the injected web tool-use instruction is never crowded out by a long history.
    final webAccessEnabled = ref.read(webAccessEnabledProvider);
    final hasValidKey = await ref.read(secureKeyStoreProvider).hasValidKey();
    return ref
        .read(contextAssemblerProvider)
        .assemble(
          priorMessages,
          images: images,
          audio: audio,
          reserveToolInstruction: reserveToolInstruction,
          reserveMemoryBlock: memoryEnabled && hasFacts,
          reserveMemoryCaptureInstruction:
              reserveToolInstruction && memoryEnabled,
          reserveWebTools:
              reserveToolInstruction && webAccessEnabled && hasValidKey,
        );
  }

  /// Halt the in-flight reply within ~1s (FR-014); the partial text is retained by [send]'s
  /// finalize path as `stoppedPartial`.
  Future<void> stop() async {
    if (!state.isGenerating) return;
    _stopRequested = true;
    await ref.read(gemmaServiceProvider).stop();
  }
}

final chatControllerProvider = NotifierProvider<ChatController, ChatState>(
  ChatController.new,
);

/// Reactive ordered messages for a conversation (FR-013/FR-020) — the streaming assistant turn's
/// content updates live as deltas land.
final chatMessagesProvider = StreamProvider.autoDispose
    .family<List<Message>, int>((ref, conversationId) {
      return ref
          .watch(conversationRepositoryProvider)
          .watchMessages(conversationId);
    });

/// Coerces whole-valued doubles to int for any schema property declared as `integer`. Called in
/// [ChatController._runToolTurn] before [appendToolInvocation] so chips display `300` not `300.0`.
/// Fractional values are left untouched (the dispatcher's strict validator rejects them).
Map<String, Object?> _normalizeToolArgs(
  String name,
  Map<String, Object?> args,
) {
  final schema = ToolRegistry.byName(name)?.parameters;
  if (schema == null) return args;
  final properties =
      (schema['properties'] as Map?)?.cast<String, Object?>() ??
      const <String, Object?>{};
  final out = Map<String, Object?>.of(args);
  for (final entry in args.entries) {
    final propSchema = (properties[entry.key] as Map?)?.cast<String, Object?>();
    if (propSchema?['type'] != 'integer') continue;
    final v = entry.value;
    if (v is double && v.isFinite && v == v.roundToDouble()) {
      out[entry.key] = v.toInt();
    }
  }
  return out;
}
