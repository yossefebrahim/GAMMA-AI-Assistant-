/// Audio capture constants (003 R3) — the single source of truth for the clip format and limits.
///
/// These are DATA, not UI policy: the recorder config, the file-store guard, and the recording
/// controller's validation all read from here (data-model.md §1). The format triple
/// (WAV / 16 kHz / mono / PCM16) is the model's input contract verified by the Phase 0 spike;
/// the caps are app-owned — the plugin enforces nothing (spike §1.4).
abstract final class AudioConstants {
  /// Model input contract: 16 kHz sample rate (research R1/R2).
  static const int sampleRateHz = 16000;

  /// Model input contract: mono.
  static const int channels = 1;

  /// The WAV/PCM16 container the recorder emits and the store persists.
  static const String wavMimeType = 'audio/wav';

  /// Maximum clip length — auto-stop at the cap keeps the clip (spec Q1 / FR-002, research R3).
  static const Duration maxClipDuration = Duration(seconds: 30);

  /// Minimum clip length — a shorter stop discards with a "too short" note (spec FR-002).
  static const Duration minClipDuration = Duration(milliseconds: 500);

  /// Persisted-file guard — double margin over a max-length clip
  /// (16,000 Hz × 2 B × 30 s ≈ 938 KB + 44-byte header; research R3).
  static const int maxPersistedBytes = 2 * 1024 * 1024;

  /// Canonical WAV header size for the PCM16 mono files the recorder emits.
  static const int wavHeaderBytes = 44;

  /// PCM16 mono @ 16 kHz data rate: bytes of audio payload per second.
  static const int bytesPerSecond = sampleRateHz * 2 * channels;

  /// Derive a clip's duration from its WAV byte length — `(bytes − 44) / 32000` seconds
  /// (data-model.md §1). No extra DB column needed; clamps at zero for degenerate files.
  static Duration durationFromBytes(int byteLength) {
    final payload = byteLength - wavHeaderBytes;
    if (payload <= 0) return Duration.zero;
    return Duration(
      milliseconds:
          (payload * Duration.millisecondsPerSecond) ~/ bytesPerSecond,
    );
  }

  /// The `m:ss` readout used by the recording elapsed display and the clip chip (e.g. `0:07`).
  static String formatDuration(Duration duration) {
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }
}
