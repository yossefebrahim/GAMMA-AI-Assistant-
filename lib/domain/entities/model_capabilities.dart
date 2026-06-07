import 'package:meta/meta.dart';

/// Capabilities of the active model, surfaced as DATA (Constitution Principle III).
///
/// The UI renders input affordances from this value object, never from hardcoded per-model
/// branches. This slice restricts interaction to text (FR-016) via scope, so non-text modalities
/// are read but not exposed.
@immutable
class ModelCapabilities {
  const ModelCapabilities({
    this.text = true,
    this.image = false,
    this.audio = false,
    this.functionCalling = false,
    this.thinking = false,
  });

  /// Always true — a usable model produces text.
  final bool text;
  final bool image;
  final bool audio;
  final bool functionCalling;
  final bool thinking;

  /// The capability set this slice ships against (FR-016).
  static const ModelCapabilities textOnly = ModelCapabilities();

  @override
  bool operator ==(Object other) =>
      other is ModelCapabilities &&
      other.text == text &&
      other.image == image &&
      other.audio == audio &&
      other.functionCalling == functionCalling &&
      other.thinking == thinking;

  @override
  int get hashCode => Object.hash(text, image, audio, functionCalling, thinking);
}
