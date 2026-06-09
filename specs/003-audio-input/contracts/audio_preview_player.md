# Contract — AudioPreviewPlayer (new seam, 003, spec Q2 scope)

Minimal playback for the **composer preview chip only** (history chips are static this slice).
Domain interface in `lib/domain/services/audio_preview_player.dart`; concrete implementation over
`audioplayers ^6.7.0` confined to `lib/infrastructure/media/` (seam-guard rule added).

```dart
abstract interface class AudioPreviewPlayer {
  /// Plays the local file from the start. Restarting while playing is allowed (stops first).
  Future<void> play(String path);

  /// Stops playback and releases the platform player.
  Future<void> stop();

  /// idle → playing → idle (on completion, stop, or error). Drives the chip's play/stop toggle.
  Stream<AudioPreviewState> get state;
}
enum AudioPreviewState { idle, playing }
```

## Guarantees

1. Plays local app-private files only; no network sources accepted (Principle I).
2. Exactly one preview plays at a time (a `play` interrupts any prior playback).
3. The platform player is released on `stop`, on chip remove/replace/send, on conversation
   switch, and on backgrounding (Principle VIII) — wired in the controller via the existing
   lifecycle listener.
4. An unreadable/corrupt file surfaces as a quiet return to `idle` plus the composer-inline error
   path — never a crash or a stuck `playing` state.
5. Playback errors never affect the pending attachment itself (the clip stays attached and
   sendable; FR-023's broken-state rule applies only to genuinely unreadable files at send/render).

## FakeAudioPreviewPlayer

Drivable state stream; records `play(path)`/`stop()` calls; scriptable completion and failure.
