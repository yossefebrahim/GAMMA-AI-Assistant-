/// Playback state for the composer preview chip's play/stop toggle:
/// idle → playing → idle (on completion, stop, or error).
enum AudioPreviewState { idle, playing }

/// Minimal playback seam for the **composer preview chip only** (003 spec Q2 — history chips are
/// static this slice). The concrete `AudioplayersPreviewPlayer` (over `audioplayers ^6.7.0`) lives
/// in `lib/infrastructure/media/` (enforced by tool/check_plugin_seam.sh); the recording
/// controller depends on this interface and unit-tests with `FakeAudioPreviewPlayer`.
///
/// Guarantees (contracts/audio_preview_player.md): plays local app-private files only — no network
/// sources (Principle I); exactly one preview at a time (a `play` interrupts any prior playback);
/// the platform player is released on [stop] — the controller wires release on chip
/// remove/replace/send, conversation switch, and backgrounding (Principle VIII); an
/// unreadable/corrupt file surfaces as a quiet return to [AudioPreviewState.idle], never a crash
/// or a stuck `playing` state, and never affects the pending attachment itself.
abstract interface class AudioPreviewPlayer {
  /// Plays the local file from the start. Restarting while playing is allowed (stops first).
  Future<void> play(String path);

  /// Stops playback and releases the platform player.
  Future<void> stop();

  /// Drives the chip's play/stop toggle.
  Stream<AudioPreviewState> get state;
}
