import 'dart:typed_data';

import 'package:meta/meta.dart';

/// Transient image bytes handed across the `GemmaService` seam for the current prompt and for
/// replayed history turns (FR-012/FR-015/FR-016). Pure Dart (`dart:typed_data`) so the seam stays
/// plugin-free and unit-testable.
///
/// The bytes are read just-in-time from the stored file and are held only for the duration of a
/// `generate` call — never retained between turns (Principle VIII). Never persisted; the persisted
/// counterpart is [ImageAttachment].
///
/// Uses identity equality on purpose: a transient per-call byte carrier is never compared, and
/// value equality over [Uint8List] would scan the whole image needlessly.
@immutable
class ImageInput {
  const ImageInput(this.bytes, {this.mimeType});

  /// Raw image bytes read just-in-time from the stored file.
  final Uint8List bytes;

  /// Optional MIME hint (e.g. `image/jpeg`); best-effort.
  final String? mimeType;
}
