import 'dart:io';

import 'package:ai_assistant/core/audio_constants.dart';
import 'package:ai_assistant/domain/services/audio_recorder_service.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

/// THE concrete [AudioRecorderService] over `record ^7.0.0` — confined to
/// `lib/infrastructure/media/` (enforced by tool/check_plugin_seam.sh), so the recording
/// controller tests with `FakeAudioRecorderService` (003 R2).
///
/// Captures straight into the model's input contract — WAV container, 16 kHz, mono, 16-bit PCM
/// (`AudioEncoder.wav` emits PCM16) — so no transcoding step exists to fail (contract guarantee 1;
/// flutter_gemma's own example proves this exact pairing). Policy-free: the 30 s cap and 500 ms
/// minimum belong to the recording controller (guarantee 3). NEVER prompts for permission —
/// callers resolve it via `MediaPermissionService` first (guarantee 2; we deliberately do not use
/// `record`'s own `hasPermission`, which both checks and prompts — research R5).
class RecordAudioRecorderService implements AudioRecorderService {
  final AudioRecorder _recorder = AudioRecorder();

  /// dBFS floor for amplitude normalization: `record` reports ~-160..0 dBFS; everything at or
  /// below -60 dB renders as silence on the pulsing indicator.
  static const double _silenceFloorDb = -60.0;

  @override
  Future<void> start() async {
    try {
      final dir = await getTemporaryDirectory();
      final path =
          '${dir.path}/rec_${DateTime.now().microsecondsSinceEpoch}.wav';
      await _recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.wav,
          sampleRate: AudioConstants.sampleRateHz,
          numChannels: AudioConstants.channels,
        ),
        path: path,
      );
    } catch (error) {
      // Fail fast with the typed failure (guarantee 2) — mic busy, hardware error, etc. The
      // controller surfaces a clear composer message; never a silent no-op.
      throw RecorderUnavailableException(
        'could not start the recorder',
        cause: error,
      );
    }
  }

  @override
  Future<RecordedAudio?> stop() async {
    final path = await _recorder.stop();
    if (path == null) return null;
    final file = File(path);
    if (!await file.exists()) return null;
    // The file IS PCM16 mono @16 kHz, so its byte length is the exact duration (data-model §1) —
    // no separate clock to drift from the captured audio.
    final durationMs = AudioConstants.durationFromBytes(
      await file.length(),
    ).inMilliseconds;
    return RecordedAudio(
      path: path,
      mimeType: AudioConstants.wavMimeType,
      durationMs: durationMs,
    );
  }

  @override
  Future<void> cancel() async {
    // `record`'s cancel stops and deletes the temp file (guarantee 4).
    await _recorder.cancel();
  }

  @override
  Future<bool> get isRecording => _recorder.isRecording();

  @override
  Stream<double> get amplitude => _recorder
      .onAmplitudeChanged(const Duration(milliseconds: 100))
      .map(
        (amp) => ((amp.current - _silenceFloorDb) / -_silenceFloorDb).clamp(
          0.0,
          1.0,
        ),
      );

  /// Release the platform recorder. Not part of the seam — called by the owning provider's
  /// dispose.
  Future<void> dispose() => _recorder.dispose();
}
