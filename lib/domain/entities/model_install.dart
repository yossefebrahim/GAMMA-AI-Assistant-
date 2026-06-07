import 'package:meta/meta.dart';

/// Install state of the single default model (FR-009, FR-010).
enum ModelInstallState { notInstalled, downloading, installed }

/// Tracks the single default model (FR-009, FR-010, FR-030). One row in `model_install`.
///
/// Capabilities are deliberately NOT stored here — they are read live from
/// `GemmaService.capabilities` of the active model (Principle III: capabilities are data, not
/// persisted config).
@immutable
class ModelInstall {
  const ModelInstall({
    required this.id,
    required this.state,
    this.filePath,
    this.sizeBytes,
    this.installedAt,
  });

  /// Constant model id, e.g. `gemma-4-e2b`.
  final String id;

  final ModelInstallState state;

  /// Absolute app-private path to the verified `.litertlm`; `null` unless [state] is
  /// [ModelInstallState.installed].
  final String? filePath;

  /// On-disk size, shown to the user (FR-030).
  final int? sizeBytes;

  final DateTime? installedAt;

  /// The authoritative "is the model usable" check (R2): installed AND a file path recorded.
  /// (Callers still verify the file exists on disk.)
  bool get isUsable => state == ModelInstallState.installed && filePath != null;

  @override
  bool operator ==(Object other) =>
      other is ModelInstall &&
      other.id == id &&
      other.state == state &&
      other.filePath == filePath &&
      other.sizeBytes == sizeBytes &&
      other.installedAt == installedAt;

  @override
  int get hashCode => Object.hash(id, state, filePath, sizeBytes, installedAt);
}
