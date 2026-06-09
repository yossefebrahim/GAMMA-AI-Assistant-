import 'package:ai_assistant/core/model_catalog.dart';
import 'package:ai_assistant/data/model/background_model_downloader.dart';
import 'package:ai_assistant/domain/entities/model_capabilities.dart';
import 'package:ai_assistant/domain/services/gemma_service.dart';
import 'package:ai_assistant/infrastructure/gemma/flutter_gemma_service.dart';
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

/// Loads the model into the [gemmaServiceProvider] when first watched (entering chat) and releases
/// it when no longer watched (leaving chat) — autoDispose IS the resource-hygiene mechanism
/// (FR-029, Principle VIII). App-background release is handled separately by the chat screen's
/// `AppLifecycleListener` (R5: `onDispose` does not fire on backgrounding), which closes the
/// service and invalidates this provider so it reloads on resume.
final modelSessionProvider = FutureProvider.autoDispose<GemmaService>((ref) async {
  final path = await ref.watch(installedModelPathProvider.future);
  if (path == null) {
    throw const ModelUnavailableException();
  }
  final gemma = ref.read(gemmaServiceProvider);
  if (!gemma.isLoaded) {
    // Capabilities flow as DATA from the catalog into the seam (Principle III, FR-006) — the seam
    // enables the matching modalities and reports them back via `capabilities`.
    await gemma.loadModel(path, capabilities: ModelCatalog.capabilities);
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
    data: (gemma) => gemma.isLoaded ? gemma.capabilities : ModelCapabilities.textOnly,
    orElse: () => ModelCapabilities.textOnly,
  );
});

/// Whether the model session is actually LOADED (data state), as opposed to loading or failed.
///
/// [modelCapabilitiesProvider] reports `textOnly` (image:false) in all three of loading / failed /
/// genuinely-text-only — the chat screen surfaces loading and failure separately (`_ModelLoading` /
/// `_ModelError`). This provider lets capability-driven consumers tell a REAL switch to a text-only
/// model apart from a transient load/reload, so a pending image isn't dropped with the misleading
/// "this model does not accept images" note while the model is merely loading or failed (002 audit).
final modelSessionReadyProvider = Provider<bool>((ref) {
  return ref.watch(modelSessionProvider).maybeWhen(
        data: (gemma) => gemma.isLoaded,
        orElse: () => false,
      );
});
