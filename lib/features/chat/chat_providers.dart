import 'package:ai_assistant/core/model_catalog.dart';
import 'package:ai_assistant/core/tools/tool_registry.dart';
import 'package:ai_assistant/data/model/background_model_downloader.dart';
import 'package:ai_assistant/data/repositories/drift_memory_repository.dart';
import 'package:ai_assistant/data/repositories/settings_repository.dart';
import 'package:ai_assistant/domain/entities/model_capabilities.dart';
import 'package:ai_assistant/domain/entities/tool_spec.dart';
import 'package:ai_assistant/domain/services/audio_preview_player.dart';
import 'package:ai_assistant/domain/services/audio_recorder_service.dart';
import 'package:ai_assistant/domain/services/gemma_service.dart';
import 'package:ai_assistant/features/chat/session_instruction.dart';
import 'package:ai_assistant/infrastructure/gemma/flutter_gemma_service.dart';
import 'package:ai_assistant/infrastructure/media/audioplayers_preview_player.dart';
import 'package:ai_assistant/infrastructure/media/record_audio_recorder_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Thrown when chat is opened but no installed model exists on disk.
class ModelUnavailableException implements Exception {
  const ModelUnavailableException();
  @override
  String toString() => 'ModelUnavailableException: no installed model found';
}

/// Absolute path of the verified installed model, or null (FR-009/FR-010). Overridable in tests.
final installedModelPathProvider = FutureProvider<String?>((ref) async {
  return ref.read(modelDownloaderProvider).installedModelPath();
});

/// The capabilities declared by [ModelCatalog] — wrapped in a provider so integration tests
/// can override them (e.g. `ModelCapabilities.textOnly`) without touching the catalog constant.
/// Production reads this from the catalog; tests override with the capabilities they want to exercise.
final catalogCapabilitiesProvider = Provider<ModelCapabilities>((ref) {
  return ModelCatalog.capabilities;
});

/// Loads the model into the [gemmaServiceProvider] when first watched (entering chat) and releases
/// it when no longer watched (leaving chat) — autoDispose IS the resource-hygiene mechanism
/// (FR-029, Principle VIII). App-background release is handled separately by the chat screen's
/// `AppLifecycleListener` (R5: `onDispose` does not fire on backgrounding), which closes the
/// service and invalidates this provider so it reloads on resume.
final modelSessionProvider = FutureProvider.autoDispose<GemmaService>((
  ref,
) async {
  final path = await ref.watch(installedModelPathProvider.future);
  if (path == null) {
    throw const ModelUnavailableException();
  }
  final gemma = ref.read(gemmaServiceProvider);
  if (!gemma.isLoaded) {
    final caps = ref.read(catalogCapabilitiesProvider);
    final functionCalling = caps.functionCalling;
    final memoryEnabled = ref.read(memoryEnabledProvider);

    // Compose the declared tool list (T016, data-model §4, R6):
    //   • deviceTools declared whenever functionCalling is on (004 guarantee 18 — structural
    //     coupling: passing tools without functionCalling throws StateError).
    //   • memoryTools additionally declared when functionCalling AND memoryEnabled (R6).
    //   • flag-off → empty list → byte-parity with 003 (guarantee 19).
    final tools = <ToolSpec>[
      if (functionCalling) ...ToolRegistry.deviceTools,
      if (functionCalling && memoryEnabled) ...ToolRegistry.memoryTools,
    ];

    // Compose the system instruction (T023, data-model §4) via the shared helper (F3 — one
    // composition site shared with both controllers' _refreshSession):
    //   • factsBlock: the id-prefixed category-ordered block, or null when memory is off.
    //   • memoryCapture: true only when the model can call tools AND memory is on (R5 capture
    //     instruction is the reliability lever; ~86 tokens; accounted in ContextAssembler).
    //   • deviceTools: true whenever functionCalling — includes the ~40-token device tool-use
    //     instruction (ToolRegistry.systemInstruction, 004 R6).
    //   • compose() returns null when all parts are absent → byte-parity guarantee 29.
    final activeFacts = await ref.read(memoryRepositoryProvider).listActive();
    final systemInstruction = composeSessionInstruction(
      caps: caps,
      memoryEnabled: memoryEnabled,
      activeFacts: activeFacts,
    );

    await gemma.loadModel(
      path,
      capabilities: caps,
      tools: tools,
      systemInstruction: systemInstruction,
    );
  }
  // Release on leaving chat (no more listeners) — exactly one active model at a time.
  ref.onDispose(() async {
    await gemma.close();
  });
  return gemma;
});

/// The active model's capabilities as DATA (Principle III) — the composer renders input
/// affordances from this, never from a hardcoded per-model branch (FR-005/FR-006). Derived from the
/// live [modelSessionProvider] so the attach control flips on a model switch with no restart
/// (FR-007): while the model is loading or unavailable, it falls back to text-only.
final modelCapabilitiesProvider = Provider<ModelCapabilities>((ref) {
  final session = ref.watch(modelSessionProvider);
  return session.maybeWhen(
    data: (gemma) =>
        gemma.isLoaded ? gemma.capabilities : ModelCapabilities.textOnly,
    orElse: () => ModelCapabilities.textOnly,
  );
});

/// App-wide [AudioRecorderService] (003 R2) — the capture seam, overridable in tests with
/// `FakeAudioRecorderService`. The platform recorder is released with the provider.
final audioRecorderServiceProvider = Provider<AudioRecorderService>((ref) {
  final service = RecordAudioRecorderService();
  ref.onDispose(service.dispose);
  return service;
});

/// App-wide [AudioPreviewPlayer] (003 R4, composer preview only — spec Q2) — overridable in tests
/// with `FakeAudioPreviewPlayer`. The platform player is released with the provider.
final audioPreviewPlayerProvider = Provider<AudioPreviewPlayer>((ref) {
  final player = AudioplayersPreviewPlayer();
  ref.onDispose(player.dispose);
  return player;
});

/// Whether the model session is actually LOADED (data state), as opposed to loading or failed.
///
/// [modelCapabilitiesProvider] reports `textOnly` (image:false) in all three of loading / failed /
/// genuinely-text-only — the chat screen surfaces loading and failure separately (`_ModelLoading` /
/// `_ModelError`). This provider lets capability-driven consumers tell a REAL switch to a text-only
/// model apart from a transient load/reload, so a pending image isn't dropped with the misleading
/// "this model does not accept images" note while the model is merely loading or failed (002 audit).
final modelSessionReadyProvider = Provider<bool>((ref) {
  return ref
      .watch(modelSessionProvider)
      .maybeWhen(data: (gemma) => gemma.isLoaded, orElse: () => false);
});
