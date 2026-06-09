import 'package:meta/meta.dart';

/// A single image persisted alongside one user [Message] (FR-012, FR-017, FR-018). The image
/// **bytes** live as an app-private file (OS-encrypted, FR-024); this entity holds only the stored
/// path + an optional MIME hint, which map to the `messages.imagePath` / `messages.imageMimeType`
/// columns (drift schema v2).
///
/// 1:0..1 with a message (a message has zero or one image — FR-002). Its lifecycle is tied to its
/// conversation: the file is deleted when the conversation is deleted (FR-019).
@immutable
class ImageAttachment {
  const ImageAttachment({required this.path, this.mimeType});

  /// Absolute app-private path under `…/images/` — the stored copy, NOT the picker temp file.
  final String path;

  /// Optional MIME type (e.g. `image/jpeg`); best-effort, for rendering/debugging.
  final String? mimeType;

  @override
  bool operator ==(Object other) =>
      other is ImageAttachment && other.path == path && other.mimeType == mimeType;

  @override
  int get hashCode => Object.hash(path, mimeType);
}
