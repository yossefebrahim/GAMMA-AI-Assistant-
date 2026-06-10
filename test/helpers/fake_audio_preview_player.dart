import 'dart:async';

import 'package:ai_assistant/domain/services/audio_preview_player.dart';

/// In-memory [AudioPreviewPlayer] for unit/widget tests (contract: audio_preview_player.md "Test
/// double"). Records [play]/[stop] calls, exposes a drivable [state] stream, and scripts
/// completion ([completePlayback]) and failure ([throwOnPlay] → quiet return to idle, per
/// guarantee 4 — never a stuck `playing`).
class FakeAudioPreviewPlayer implements AudioPreviewPlayer {
  /// When true, [play] surfaces the unreadable-file path: no `playing` state, quiet idle.
  bool throwOnPlay = false;

  /// Every path handed to [play], in order.
  final List<String> playedPaths = <String>[];

  int stopCalls = 0;

  final StreamController<AudioPreviewState> _state =
      StreamController<AudioPreviewState>.broadcast();

  /// The most recent state (initially idle), for synchronous assertions.
  AudioPreviewState current = AudioPreviewState.idle;

  void _emit(AudioPreviewState next) {
    current = next;
    _state.add(next);
  }

  /// Script a natural end-of-clip: playing → idle.
  void completePlayback() => _emit(AudioPreviewState.idle);

  @override
  Future<void> play(String path) async {
    playedPaths.add(path);
    if (throwOnPlay) {
      _emit(AudioPreviewState.idle);
      return;
    }
    _emit(AudioPreviewState.playing);
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    _emit(AudioPreviewState.idle);
  }

  @override
  Stream<AudioPreviewState> get state => _state.stream;
}
