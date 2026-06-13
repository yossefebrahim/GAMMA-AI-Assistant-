import 'package:meta/meta.dart';

/// Capabilities of the active model, surfaced as DATA (Constitution Principle III).
///
/// The UI gates input affordances (image/audio pickers) and the seam gates tool declaration
/// ([functionCalling]) from this value object, never from hardcoded per-model branches — the
/// shared mechanism across features 002 (vision), 003 (audio), and 004–006 (function calling +
/// memory + web). Each feature reads the flag it owns; an unsupported modality is simply not
/// exposed.
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

  /// The text-only capability set (no image/audio/tools) — a convenient default and test fixture.
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
  int get hashCode =>
      Object.hash(text, image, audio, functionCalling, thinking);
}
