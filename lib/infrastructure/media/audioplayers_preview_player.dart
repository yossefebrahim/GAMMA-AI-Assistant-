import 'dart:async';

import 'package:ai_assistant/domain/services/audio_preview_player.dart';
import 'package:audioplayers/audioplayers.dart';

/// THE concrete [AudioPreviewPlayer] over `audioplayers ^6.7.0` — confined to
/// `lib/infrastructure/media/` (enforced by tool/check_plugin_seam.sh), so the recording
/// controller tests with `FakeAudioPreviewPlayer` (003 R4).
///
/// Composer-preview scope only (spec Q2): one small local WAV via [DeviceFileSource] — local
/// app-private files only, never a network source (guarantee 1). A single platform player means
/// exactly one preview at a time; [play] interrupts any prior playback (guarantee 2). [stop]
/// releases the platform player (guarantee 3). An unreadable file surfaces as a quiet return to
/// idle — never a crash or a stuck `playing` state (guarantee 4).
class AudioplayersPreviewPlayer implements AudioPreviewPlayer {
  AudioplayersPreviewPlayer() {
    _playerSub = _player.onPlayerStateChanged.listen((playerState) {
      _emit(
        playerState == PlayerState.playing
            ? AudioPreviewState.playing
            : AudioPreviewState.idle,
      );
    });
  }

  final AudioPlayer _player = AudioPlayer();
  late final StreamSubscription<PlayerState> _playerSub;
  final StreamController<AudioPreviewState> _state =
      StreamController<AudioPreviewState>.broadcast();
  AudioPreviewState _current = AudioPreviewState.idle;

  void _emit(AudioPreviewState next) {
    if (next == _current) return;
    _current = next;
    _state.add(next);
  }

  @override
  Future<void> play(String path) async {
    try {
      // Interrupt-on-play (guarantee 2): restarting while playing stops first.
      await _player.stop();
      await _player.play(DeviceFileSource(path));
    } catch (_) {
      // Unreadable/corrupt file: quiet return to idle (guarantee 4). The composer-inline error
      // path is the controller's; the pending clip itself is unaffected (guarantee 5).
      _emit(AudioPreviewState.idle);
    }
  }

  @override
  Future<void> stop() async {
    try {
      await _player.stop();
      await _player.release();
    } finally {
      _emit(AudioPreviewState.idle);
    }
  }

  @override
  Stream<AudioPreviewState> get state => _state.stream;

  /// Release everything. Not part of the seam — called by the owning provider's dispose.
  Future<void> dispose() async {
    await _playerSub.cancel();
    await _player.dispose();
    await _state.close();
  }
}
