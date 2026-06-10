import 'dart:async';

import 'package:ai_assistant/domain/services/audio_recorder_service.dart';

/// In-memory [AudioRecorderService] for unit/widget tests (contract: audio_recorder.md "Test
/// double"). Scriptable: [start] succeeds or throws [RecorderUnavailableException]; [stop]
/// returns [nextStop] (a [RecordedAudio] with configurable duration/path, or null); the
/// [amplitude] stream is drivable via [emitAmplitude]; call order is recorded in [calls] for
/// resource-rule assertions. Injected via Riverpod overrides — no plugin in any test.
class FakeAudioRecorderService implements AudioRecorderService {
  /// When true, [start] throws [RecorderUnavailableException] (mic busy / hardware error).
  bool throwOnStart = false;

  /// What the next [stop] returns. Tests typically set this to a [RecordedAudio] pointing at a
  /// temp file they created.
  RecordedAudio? nextStop;

  /// Call order recorder: 'start' | 'stop' | 'cancel'.
  final List<String> calls = <String>[];

  final StreamController<double> _amplitude = StreamController<double>.broadcast();
  bool _recording = false;

  /// Drive the amplitude stream from the test (the pulsing-indicator input).
  void emitAmplitude(double level) => _amplitude.add(level);

  @override
  Future<void> start() async {
    calls.add('start');
    if (throwOnStart) {
      throw const RecorderUnavailableException('fake recorder unavailable');
    }
    _recording = true;
  }

  @override
  Future<RecordedAudio?> stop() async {
    calls.add('stop');
    _recording = false;
    return nextStop;
  }

  @override
  Future<void> cancel() async {
    calls.add('cancel');
    _recording = false;
  }

  @override
  Future<bool> get isRecording async => _recording;

  @override
  Stream<double> get amplitude => _amplitude.stream;
}
