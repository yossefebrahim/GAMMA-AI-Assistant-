import 'dart:typed_data';

import 'package:meta/meta.dart';

/// Transient audio bytes handed across the `GemmaService` seam for the current prompt and for
/// replayed history turns (FR-013/FR-016/FR-017). Mirrors [ImageInput]: pure Dart
/// (`dart:typed_data`) so the seam stays plugin-free and unit-testable.
///
/// The bytes are WAV 16 kHz mono PCM16 file bytes, read just-in-time from the stored file and held
/// only for the duration of a `generate` call — never retained between turns (Principle VIII).
/// Never persisted; the persisted counterpart is [AudioAttachment]. Duration is derivable via
/// `AudioConstants.durationFromBytes`.
@immutable
class AudioInput {
  const AudioInput(this.bytes, {this.mimeType});

  /// Raw WAV file bytes read just-in-time from the stored file.
  final Uint8List bytes;

  /// Optional MIME hint (`audio/wav`); best-effort.
  final String? mimeType;
}
