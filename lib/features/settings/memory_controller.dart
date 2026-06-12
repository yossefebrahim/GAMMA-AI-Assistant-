import 'package:ai_assistant/core/memory/facts_block_composer.dart';
import 'package:ai_assistant/core/memory/system_instruction_composer.dart';
import 'package:ai_assistant/data/repositories/drift_memory_repository.dart';
import 'package:ai_assistant/data/repositories/settings_repository.dart';
import 'package:ai_assistant/domain/entities/memory.dart';
import 'package:ai_assistant/domain/services/gemma_service.dart';
import 'package:ai_assistant/infrastructure/gemma/flutter_gemma_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Settings-screen controller for durable memory (005, US3). Mirrors [SettingsController] in shape:
/// holds no state of its own — facts come from [activeMemoriesProvider], the toggle from
/// [memoryEnabledProvider]. Every mutating method delegates to the repository or the enabled
/// provider, then — when the seam is loaded — refreshes the session via [GemmaService.startSession]
/// so changes take effect in the next conversation without a full model reload (FR-014/FR-017,
/// data-model §4 "session boundary").
///
/// `setEnabled` is the ONLY method that also touches the session; `add`/`edit`/`delete`/`clearAll`
/// mutate the repository only — the new state is picked up at the next [openConversation] call
/// (FR-008, data-model §4: "facts can't change mid-chat").
class MemoryController extends Notifier<void> {
  @override
  void build() {}

  // ---------------------------------------------------------------------------
  // Session-instruction helpers
  // ---------------------------------------------------------------------------

  /// Compose the current system instruction from live state and refresh the chat session.
  ///
  /// Called after toggling memory so the next conversation reflects the new setting (FR-014).
  /// If the model is not loaded yet (cold start, or between sessions) this is a no-op: the
  /// instruction will be composed fresh when the model loads (data-model §4 `loadModel`).
  Future<void> _refreshSession() async {
    final gemma = ref.read(gemmaServiceProvider);
    if (!gemma.isLoaded) return;

    final caps = gemma.capabilities;
    final functionCalling = caps.functionCalling;
    final memoryEnabled = ref.read(memoryEnabledProvider);

    final activeFacts = await ref.read(memoryRepositoryProvider).listActive();
    final factsBlock = memoryEnabled
        ? FactsBlockComposer.compose(activeFacts)
        : null;

    final instruction = SystemInstructionComposer.compose(
      factsBlock: factsBlock,
      memoryCapture: functionCalling && memoryEnabled,
      deviceTools: functionCalling,
    );

    await gemma.startSession(systemInstruction: instruction);
  }

  // ---------------------------------------------------------------------------
  // Repository mutations (add / edit / delete / clearAll)
  // ---------------------------------------------------------------------------

  /// Manually capture a fact (US3 — management screen, no tool round trip).
  /// [sourceConversationId] is null for manually-added facts (data-model §1).
  Future<UpsertResult> add({
    required String fact,
    required MemoryCategory category,
  }) {
    return ref
        .read(memoryRepositoryProvider)
        .upsert(fact: fact, category: category);
  }

  /// Edit an existing active fact's text and/or category. Applies from the next session
  /// (FR-017) — does NOT call [_refreshSession] (the chat layer handles this at conversation open).
  Future<void> edit(int id, String fact, MemoryCategory category) {
    return ref.read(memoryRepositoryProvider).editFact(id, fact, category);
  }

  /// Soft-delete a single fact. Returns `false` when the id is not active (e.g. already deleted).
  Future<bool> delete(int id) {
    return ref.read(memoryRepositoryProvider).softDeleteById(id);
  }

  /// Destructive clear — soft-deletes ALL active facts. No undo (the settings screen must confirm
  /// before calling this).
  Future<void> clearAll() {
    return ref.read(memoryRepositoryProvider).clearAll();
  }

  // ---------------------------------------------------------------------------
  // Toggle (also refreshes the session — FR-014)
  // ---------------------------------------------------------------------------

  /// Persist the memory-enabled preference and refresh the active chat session so the toggle
  /// takes effect immediately for the NEXT conversation (FR-014). The current in-flight conversation
  /// is unaffected (FR-008 — facts/instructions are fixed per conversation).
  Future<void> setEnabled(bool enabled) async {
    // 1. Persist + optimistically update the reactive provider.
    await ref.read(memoryEnabledProvider.notifier).set(enabled);
    // 2. Rebuild and push the new session instruction to the seam (no model reload).
    await _refreshSession();
  }
}

final memoryControllerProvider = NotifierProvider<MemoryController, void>(
  MemoryController.new,
);
