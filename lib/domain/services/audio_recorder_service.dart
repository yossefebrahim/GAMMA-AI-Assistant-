/// The seam over voice-clip capture (003 contracts/audio_recorder.md). The concrete
/// `RecordAudioRecorderService` (over `record ^7.0.0`) lives in `lib/infrastructure/media/`
/// (enforced by tool/check_plugin_seam.sh); the recording controller depends on this interface and
/// unit-tests with `FakeAudioRecorderService`.
///
/// The service is **policy-free**: the 30 s cap timer / auto-stop and the 500 ms minimum check
/// belong to the recording controller (data constants, not plugin-layer policy — guarantee 3).
/// It NEVER prompts for permission (callers resolve permission via `MediaPermissionService`
/// first — guarantee 2) and performs no network I/O, ever (guarantee 6).
abstract interface class AudioRecorderService {
  /// Starts capturing WAV 16 kHz mono PCM16 to an app-cache temp file (guarantee 1 — the model's
  /// exact input contract, no transcoding step exists). Throws [RecorderUnavailableException] if
  /// the mic can't be acquired (busy/hardware) — it never silently no-ops.
  Future<void> start();

  /// Stops and returns the captured clip, or null if nothing was captured. Native resources are
  /// released and the service is safe to restart (guarantee 5).
  Future<RecordedAudio?> stop();

  /// Discards an in-progress recording and deletes its temp file (guarantee 4).
  Future<void> cancel();

  /// True while capturing.
  Future<bool> get isRecording;

  /// Normalized mic level 0..1 while recording (drives the pulsing indicator), ~10 Hz.
  Stream<double> get amplitude;
}

/// The captured clip a [AudioRecorderService.stop] returns: a temp path in app cache (deleted by
/// the controller on remove/replace/switch — nothing persists from a cancelled compose).
class RecordedAudio {
  const RecordedAudio({
    required this.path,
    this.mimeType,
    required this.durationMs,
  });

  /// App-cache temp file holding the WAV bytes.
  final String path;

  /// Best-effort MIME hint (`audio/wav`).
  final String? mimeType;

  /// Captured length, reported by the recorder at stop.
  final int durationMs;
}

/// Thrown by [AudioRecorderService.start] when the mic can't be acquired (held elsewhere,
/// hardware error) — fail fast with a clear message, never a silent no-op (guarantee 2,
/// FR-021/Principle V).
class RecorderUnavailableException implements Exception {
  const RecorderUnavailableException(this.message, {this.cause});
  final String message;
  final Object? cause;

  @override
  String toString() => 'RecorderUnavailableException: $message';
}
