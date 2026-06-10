import 'package:meta/meta.dart';

/// The previewed-but-unsent voice clip in the composer (data-model.md §1: composer-transient).
/// Holds the recorder's temp-file **path only, never decoded bytes** (Principle VIII); promoted
/// into app-private storage via `AudioFileStore.persist` only at send.
@immutable
class PendingRecording {
  const PendingRecording({required this.path, this.mimeType, required this.durationMs});

  /// The recorder temp file (app cache).
  final String path;

  /// Optional MIME hint (`audio/wav`); best-effort.
  final String? mimeType;

  /// Reported by the recorder at stop; drives the chip label and min/max validation.
  final int durationMs;

  @override
  bool operator ==(Object other) =>
      other is PendingRecording &&
      other.path == path &&
      other.mimeType == mimeType &&
      other.durationMs == durationMs;

  @override
  int get hashCode => Object.hash(path, mimeType, durationMs);
}
