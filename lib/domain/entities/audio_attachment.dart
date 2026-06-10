import 'package:meta/meta.dart';

/// A single voice clip persisted alongside one user [Message] (FR-018/FR-019). Mirrors
/// [ImageAttachment]: the audio **bytes** live as an app-private file under `…/audio/`; this
/// entity holds only the stored path + an optional MIME hint, mapping to the
/// `messages.audioPath` / `messages.audioMimeType` columns (drift schema v3).
///
/// 1:0..1 with a message, and exclusive with an image (audio XOR image — spec Q3). Its lifecycle
/// is tied to its conversation: the file is deleted when the conversation is deleted.
@immutable
class AudioAttachment {
  const AudioAttachment({required this.path, this.mimeType});

  /// Absolute app-private path under `…/audio/` — the stored copy, NOT the recorder temp file.
  final String path;

  /// Optional MIME type (`audio/wav`); best-effort, for rendering/debugging.
  final String? mimeType;

  @override
  bool operator ==(Object other) =>
      other is AudioAttachment && other.path == path && other.mimeType == mimeType;

  @override
  int get hashCode => Object.hash(path, mimeType);
}
