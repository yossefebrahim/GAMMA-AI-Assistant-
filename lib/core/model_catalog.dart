import 'package:ai_assistant/domain/entities/model_capabilities.dart';

/// The single default model this slice ships (constitution: Gemma 4 E2B, ~2.4 GB).
///
/// Lean-scope (Principle IX): one model, no catalog UI yet. The download URL is the open,
/// redistributable source referenced by clarification Q1 — set it to the actual published
/// `.litertlm` artifact before an on-device run. It is the ONLY outbound URL in the app
/// (Principle I); nothing else leaves the device.
abstract final class ModelCatalog {
  /// Stable model id (PK of the `model_install` row).
  static const String modelId = 'gemma-4-e2b';

  /// Whether the default model understands images — DATA, not a per-model `if` (Principle III,
  /// 002 R1). Gemma 4 E2B is image-capable; this value flows catalog → `loadModel` →
  /// `GemmaService.capabilities` → `modelCapabilitiesProvider`, which the composer gates on.
  static const bool supportsImage = true;

  /// Whether the default model understands audio — DATA, same flow as [supportsImage] (Principle
  /// III, 003). Verified empirically for Gemma 4 E2B by the 003 Phase 0 spike (word-perfect
  /// grounding on the A34, GPU backend — specs/003-audio-input/spike-findings.md).
  static const bool supportsAudio = true;

  /// Whether the default model can call local tools — DATA, same flow as [supportsImage]/
  /// [supportsAudio] (Principle III, 004 R5). Verified empirically for Gemma 4 E2B by the 004 Phase
  /// 0 spike (83.3% no-instruction correct-call floor, 0 hallucinated tools, GPU — GATE PASSED,
  /// specs/004-function-calling/spike-findings.md). Drives tool declaration to the model AND the
  /// flag-off byte-parity regression (SC-007).
  static const bool supportsFunctionCalling = true;

  /// The active model's capabilities as a single data value (Principle III). Passed into
  /// `GemmaService.loadModel` so the seam enables the matching modalities and reports them back.
  static const ModelCapabilities capabilities = ModelCapabilities(
    image: supportsImage,
    audio: supportsAudio,
    functionCalling: supportsFunctionCalling,
  );

  /// Human label, shown lowercased per the design voice: `model ( gemma 4 e2b )`.
  static const String displayName = 'gemma 4 e2b';

  /// Mono spec-line descriptor, e.g. `GEMMA 4 E2B · 2.4GB · ARM64-V8A`.
  static const String specLine = 'GEMMA 4 E2B · 2.4GB · ARM64-V8A';

  /// On-disk filename of the verified model after the atomic `.part` → final rename (R2).
  static const String fileName = 'gemma-4-e2b.litertlm';

  /// Download filename while in flight (never loadable as a model — FR-011).
  static const String partFileName = 'gemma-4-e2b.litertlm.part';

  /// Subdirectory (under the models root) where the model file lives.
  static const String directory = 'models';

  /// Top-level **public** folder on shared storage where the model is stored so it SURVIVES an
  /// APK uninstall/reinstall (the whole point: a 2.4 GB re-download every wipe is the pain).
  /// On Android the model lands at `<shared-storage-root>/AiAssistant/models/` (e.g.
  /// `/storage/emulated/0/AiAssistant/models/`), which is outside `/Android/data/<pkg>/` and so is
  /// NOT deleted on uninstall. Reading/writing it needs the one-time "all files access" grant
  /// (`MANAGE_EXTERNAL_STORAGE`); the grant itself is per-install and must be re-given after a
  /// reinstall, but the multi-GB file is kept. Off-Android (tests/desktop) the downloader falls
  /// back to app-private storage and this constant is unused.
  static const String publicAppDirectory = 'AiAssistant';

  /// Open, redistributable source for the one-time download (clarification Q1).
  /// Public `litert-community` Gemma 4 E2B `.litertlm` artifact — NO HuggingFace token/auth needed
  /// (downloaded with a plain GET via background_downloader). Verified ~2.41 GB, resolves
  /// 302 → CDN → 200. The ONLY outbound URL in the app (Principle I); nothing else leaves the device.
  static const String downloadUrl =
      'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it.litertlm';
}
