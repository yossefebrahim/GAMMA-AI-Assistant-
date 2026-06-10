# Contract — AudioRecorderService (new seam, 003)

Domain interface in `lib/domain/services/audio_recorder_service.dart` (pure Dart); concrete
`RecordAudioRecorderService` over `record ^7.0.0` confined to `lib/infrastructure/media/`
(seam-guard rule added to `tool/check_plugin_seam.sh`).

```dart
abstract interface class AudioRecorderService {
  /// Starts capturing WAV 16kHz mono PCM16 to an app-cache temp file.
  /// Throws RecorderUnavailableException if the mic can't be acquired (busy/hardware).
  /// NEVER triggers a permission prompt — callers resolve permission via MediaPermissionService first.
  Future<void> start();

  /// Stops and returns the captured clip, or null if nothing was captured.
  Future<RecordedAudio?> stop();

  /// Discards an in-progress recording and deletes its temp file.
  Future<void> cancel();

  /// True while capturing.
  Future<bool> get isRecording;

  /// Normalized mic level 0..1 while recording (drives the pulsing indicator), ~10 Hz.
  Stream<double> get amplitude;
}

class RecordedAudio { final String path; final String? mimeType; final int durationMs; }
class RecorderUnavailableException implements Exception { final String message; final Object? cause; }
```

## Guarantees

1. Output format is exactly the model contract (WAV container, 16 kHz, mono, 16-bit PCM) —
   `RecordConfig(encoder: AudioEncoder.wav, sampleRate: 16000, numChannels: 1)` from the shared
   audio constants; no transcoding step exists.
2. `start` fails fast with `RecorderUnavailableException` (mic held elsewhere, hardware error);
   it never silently no-ops and never prompts for permission.
3. The **controller** owns the 30 s cap timer and auto-stop (data constant, not buried in the
   plugin layer) and the 500 ms minimum check on `stop` — the service is policy-free.
4. Temp files live in app cache; `cancel` deletes; an unsent stop's temp file is deleted by the
   controller on remove/replace/switch (nothing persists from a cancelled compose).
5. Recorder/native resources are released on `stop`/`cancel` and the service is safe to restart;
   backgrounding mid-capture is surfaced by the controller (lifecycle listener) calling `stop`
   and applying the keep-if-≥min rule (FR-021).
6. No network I/O, ever.

## FakeAudioRecorderService

Scriptable: `start` succeeds / throws `RecorderUnavailableException`; `stop` returns a
`RecordedAudio` with configurable duration/path or null; amplitude stream drivable by the test;
records call order (start/stop/cancel) for resource-rule assertions. Injected via Riverpod
overrides; no plugin in any unit/widget test.
