import 'package:ai_assistant/core/memory/facts_block_composer.dart';
import 'package:ai_assistant/core/memory/system_instruction_composer.dart';
import 'package:ai_assistant/data/repositories/drift_memory_repository.dart';
import 'package:ai_assistant/data/repositories/settings_repository.dart';
import 'package:ai_assistant/domain/entities/memory.dart';
import 'package:ai_assistant/domain/entities/model_capabilities.dart';
import 'package:ai_assistant/infrastructure/gemma/flutter_gemma_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Shared system-instruction composition for the chat session (005, data-model §4 "session
/// boundary"). The same three-part composition — facts block + memory-capture instruction + device
/// tool-use instruction — is needed at THREE sites: [ChatController._refreshSession],
/// [MemoryController._refreshSession], and the `modelSessionProvider` loadModel path. Centralizing
/// it here means the gating rules (which flags compose which parts) can only ever change in one
/// place (F3 — the drift hazard the audit caught).

/// Pure composition: render the facts block from [activeFacts] (only when [memoryEnabled]) and feed
/// it, with the capability-derived flags, into [SystemInstructionComposer.compose]. Returns null
/// when every part is absent (byte-parity guarantee 29). No I/O — safe on any isolate.
String? composeSessionInstruction({
  required ModelCapabilities caps,
  required bool memoryEnabled,
  required List<Memory> activeFacts,
}) {
  final factsBlock = memoryEnabled
      ? FactsBlockComposer.compose(activeFacts)
      : null;
  return SystemInstructionComposer.compose(
    factsBlock: factsBlock,
    memoryCapture: caps.functionCalling && memoryEnabled,
    deviceTools: caps.functionCalling,
  );
}

/// Read live state → compose → push to the seam via [GemmaService.startSession]. No-op when no
/// model is loaded (cold start / between sessions): the instruction is composed fresh at load time
/// by `modelSessionProvider`. Used by both controllers' `_refreshSession` (data-model §4 session
/// boundary, FR-014/FR-017).
Future<void> refreshSessionInstruction(Ref ref) async {
  final gemma = ref.read(gemmaServiceProvider);
  if (!gemma.isLoaded) return;

  final activeFacts = await ref.read(memoryRepositoryProvider).listActive();
  final instruction = composeSessionInstruction(
    caps: gemma.capabilities,
    memoryEnabled: ref.read(memoryEnabledProvider),
    activeFacts: activeFacts,
  );

  await gemma.startSession(systemInstruction: instruction);
}
