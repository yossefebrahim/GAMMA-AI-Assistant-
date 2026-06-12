import 'dart:async';
import 'dart:io';

import 'package:ai_assistant/core/audio_constants.dart';
import 'package:ai_assistant/domain/entities/pending_recording.dart';
import 'package:ai_assistant/domain/services/audio_preview_player.dart';
import 'package:ai_assistant/domain/services/audio_recorder_service.dart';
import 'package:ai_assistant/domain/services/media_permission_service.dart';
import 'package:ai_assistant/features/chat/attachment_controller.dart';
import 'package:ai_assistant/features/chat/chat_providers.dart';
import 'package:ai_assistant/infrastructure/media/permission_handler_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:meta/meta.dart';

/// Where the composer's voice flow currently is (data-model.md §4).
enum RecordingPhase { idle, recording, previewing }

/// How the recording flow needs the UI to route a missing mic permission (003 US4,
/// FR-010/FR-011/FR-012). `none` while there is nothing to explain.
enum MicPermissionPrompt { none, denied, permanentlyDenied, restricted }

/// Composer recording state: the [phase], the live [elapsed] readout while recording, the
/// previewed-but-unsent [clip], a transient [note] ("too short", "limit reached", …), an inline
/// [error] (recorder unavailable / "record again"), the mic [permissionPrompt] routing hint, and
/// whether the preview player is currently playing.
@immutable
class RecordingState {
  const RecordingState({
    this.phase = RecordingPhase.idle,
    this.elapsed = Duration.zero,
    this.clip,
    this.note,
    this.error,
    this.permissionPrompt = MicPermissionPrompt.none,
    this.isPreviewPlaying = false,
  });

  final RecordingPhase phase;

  /// Live recording time, ticking at ≥1/s (SC-004). Zero outside [RecordingPhase.recording].
  final Duration elapsed;

  /// The pending clip (path only, never bytes — Principle VIII). Non-null iff previewing.
  final PendingRecording? clip;

  final String? note;
  final String? error;
  final MicPermissionPrompt permissionPrompt;
  final bool isPreviewPlaying;

  bool get isRecording => phase == RecordingPhase.recording;
  bool get hasClip => clip != null;

  RecordingState copyWith({
    RecordingPhase? phase,
    Duration? elapsed,
    PendingRecording? clip,
    bool clearClip = false,
    String? note,
    bool clearNote = false,
    String? error,
    bool clearError = false,
    MicPermissionPrompt? permissionPrompt,
    bool? isPreviewPlaying,
  }) {
    return RecordingState(
      phase: phase ?? this.phase,
      elapsed: elapsed ?? this.elapsed,
      clip: clearClip ? null : (clip ?? this.clip),
      note: clearNote ? null : (note ?? this.note),
      error: clearError ? null : (error ?? this.error),
      permissionPrompt: permissionPrompt ?? this.permissionPrompt,
      isPreviewPlaying: isPreviewPlaying ?? this.isPreviewPlaying,
    );
  }
}

/// Owns the composer's voice-clip lifecycle (003 US1/US4/US6): the idle → recording → previewing
/// state machine of data-model.md §4, the mic permission decision tree (the 002 camera tree,
/// mic edition), the 30 s cap timer + auto-stop and 500 ms minimum (data constants, T004 — the
/// recorder service is policy-free), temp-file cleanup on discard/replace/switch, and ownership
/// of the preview player (stopped on any exit from previewing — Principle VIII).
class RecordingController extends Notifier<RecordingState> {
  /// All microcopy lowercase per the design voice (Principle X).
  static const String tooShortNote =
      'too short — record at least half a second';
  static const String limitReachedNote =
      'limit reached — recording stopped at 30 seconds';
  static const String interruptedKeptNote = 'recording stopped — clip kept';
  static const String interruptedDiscardedNote =
      'recording stopped — too short to keep';
  static const String imageReplacedNote =
      'one attachment per message — image removed';
  static const String clearedOnModelSwitchNote =
      'voice clip removed — this model does not accept audio';
  static const String recorderUnavailableError =
      "couldn't start recording — the microphone is unavailable";
  static const String persistFailedError =
      "couldn't use that recording — record again";

  Timer? _ticker;
  Timer? _capTimer;
  StreamSubscription<AudioPreviewState>? _playerSub;

  @override
  RecordingState build() {
    ref.onDispose(() {
      _cancelTimers();
      _playerSub?.cancel();
      _playerSub = null;
    });
    return const RecordingState();
  }

  AudioRecorderService get _recorder => ref.read(audioRecorderServiceProvider);
  AudioPreviewPlayer get _player => ref.read(audioPreviewPlayerProvider);
  MediaPermissionService get _permission =>
      ref.read(mediaPermissionServiceProvider);

  /// Track the preview player's real state so the chip's play/stop toggle is honest even when
  /// playback completes naturally or fails quietly (contract guarantee 4). Subscribed lazily on
  /// first playback — the platform player is never instantiated for audio-free sessions.
  void _ensurePlayerTracking() {
    _playerSub ??= _player.state.listen((playerState) {
      state = state.copyWith(
        isPreviewPlaying: playerState == AudioPreviewState.playing,
      );
    });
  }

  /// Stop playback only if the player was ever touched this session — avoids instantiating the
  /// platform player just to stop nothing.
  Future<void> _stopPlayerIfTracked() async {
    if (_playerSub != null) await _player.stop();
  }

  /// The mic tap: resolve permission (request on FIRST USE — FR-010, never at launch/build), then
  /// start recording. While previewing, a mic tap is a re-record: the old clip is replaced
  /// (data-model §4). The decision tree is the 002 camera tree verbatim
  /// (contracts/media_permission.md #3); declining never blocks text chat — only a dismissible
  /// prompt is set (FR-012).
  Future<void> onMicTap() async {
    if (state.isRecording) return; // stop has its own affordance
    switch (await _permission.micStatus()) {
      case MediaPermissionStatus.granted:
        await _start();
      case MediaPermissionStatus.denied:
        final result = await _permission.requestMic();
        if (result == MediaPermissionStatus.granted) {
          await _start();
        } else if (result == MediaPermissionStatus.permanentlyDenied) {
          state = state.copyWith(
            permissionPrompt: MicPermissionPrompt.permanentlyDenied,
          );
        } else if (result == MediaPermissionStatus.restricted) {
          state = state.copyWith(
            permissionPrompt: MicPermissionPrompt.restricted,
          );
        } else {
          state = state.copyWith(permissionPrompt: MicPermissionPrompt.denied);
        }
      case MediaPermissionStatus.permanentlyDenied:
        state = state.copyWith(
          permissionPrompt: MicPermissionPrompt.permanentlyDenied,
        );
      case MediaPermissionStatus.restricted:
        state = state.copyWith(
          permissionPrompt: MicPermissionPrompt.restricted,
        );
    }
  }

  Future<void> _start() async {
    // Re-record replaces: drop the old clip (and its temp file) before capturing anew.
    if (state.hasClip) {
      await _stopPlayerIfTracked();
      await _deleteTemp(state.clip!.path);
    }
    try {
      await _recorder.start();
    } on RecorderUnavailableException {
      // Honest failure, composer-inline (FR-021/Principle V): the mic could not be acquired.
      state = RecordingState(
        error: recorderUnavailableError,
        permissionPrompt: state.permissionPrompt,
      );
      return;
    }
    state = const RecordingState(phase: RecordingPhase.recording);
    _startTimers();
  }

  void _startTimers() {
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (state.isRecording) {
        state = state.copyWith(
          elapsed: state.elapsed + const Duration(seconds: 1),
        );
      }
    });
    // The cap is the CONTROLLER's policy (contract guarantee 3): auto-stop keeps the clip with a
    // "limit reached" note (FR-002, spec Q1).
    _capTimer = Timer(AudioConstants.maxClipDuration, () {
      _finishRecording(capReached: true);
    });
  }

  void _cancelTimers() {
    _ticker?.cancel();
    _ticker = null;
    _capTimer?.cancel();
    _capTimer = null;
  }

  /// The stop tap (and the cap's auto-stop): keep the clip when it meets the minimum, discard
  /// with a note when it doesn't (FR-002).
  Future<void> stopRecording() => _finishRecording(capReached: false);

  Future<void> _finishRecording({required bool capReached}) async {
    if (!state.isRecording) return;
    _cancelTimers();
    final recorded = await _recorder.stop();
    if (recorded == null) {
      state = const RecordingState();
      return;
    }
    if (recorded.durationMs < AudioConstants.minClipDuration.inMilliseconds) {
      await _deleteTemp(recorded.path);
      state = const RecordingState(note: tooShortNote);
      return;
    }
    _promote(recorded, note: capReached ? limitReachedNote : null);
  }

  /// Promote the captured clip to the pending-attachment (previewing) state. One attachment per
  /// message (spec Q3): a new clip replaces any pending image, with a note.
  void _promote(RecordedAudio recorded, {String? note}) {
    final attachments = ref.read(attachmentControllerProvider.notifier);
    var effectiveNote = note;
    if (ref.read(attachmentControllerProvider).pending != null) {
      attachments.remove();
      effectiveNote = imageReplacedNote;
    }
    state = RecordingState(
      phase: RecordingPhase.previewing,
      clip: PendingRecording(
        path: recorded.path,
        mimeType: recorded.mimeType ?? AudioConstants.wavMimeType,
        durationMs: recorded.durationMs,
      ),
      note: effectiveNote,
    );
  }

  /// Remove the pending clip (the chip's ×): stop any preview, delete the temp file, back to
  /// idle (data-model §4 — nothing persists from a cancelled compose).
  Future<void> removeClip() async {
    final clip = state.clip;
    await _stopPlayerIfTracked();
    if (clip != null) await _deleteTemp(clip.path);
    state = const RecordingState();
  }

  /// Play the pending clip from the start (composer preview only — spec Q2).
  Future<void> playPreview() async {
    final clip = state.clip;
    if (clip == null) return;
    _ensurePlayerTracking();
    await _player.play(clip.path);
  }

  /// Stop the preview and release the platform player (Principle VIII).
  Future<void> stopPreview() => _stopPlayerIfTracked();

  /// Called by the chat controller once a send has started: the clip is persisted in app-private
  /// storage, so the composer temp file is dropped and the preview stops (data-model §4: send →
  /// persist → idle).
  Future<void> clearAfterSend() async {
    final clip = state.clip;
    await _stopPlayerIfTracked();
    if (clip != null) await _deleteTemp(clip.path);
    state = const RecordingState();
  }

  /// The send-time persistence failure path (002 DF-2 applied to audio): the clip could not be
  /// stored — drop it and surface the inline "record again" error. No message row was created.
  Future<void> rejectPending() async {
    final clip = state.clip;
    await _stopPlayerIfTracked();
    if (clip != null) await _deleteTemp(clip.path);
    state = const RecordingState(error: persistFailedError);
  }

  /// Conversation switch (or new chat): a pending clip belongs to the compose it was recorded in
  /// — discard recording/clip and stop playback (data-model §4).
  Future<void> reset() async {
    _cancelTimers();
    if (state.isRecording) await _recorder.cancel();
    final clip = state.clip;
    await _stopPlayerIfTracked();
    if (clip != null) await _deleteTemp(clip.path);
    state = const RecordingState();
  }

  /// Capability flip (US2, FR-008): the GENUINELY-LOADED model lost audio — clear anything
  /// pending with a note. The loaded-vs-loading guard lives in the caller (the attachment
  /// controller's listener checks `modelSessionReadyProvider` — the 002 conflation lesson);
  /// this is a no-op when nothing audio is pending.
  Future<void> clearForCapabilityFlip() async {
    if (!state.isRecording && !state.hasClip) return;
    _cancelTimers();
    if (state.isRecording) await _recorder.cancel();
    final clip = state.clip;
    await _stopPlayerIfTracked();
    if (clip != null) await _deleteTemp(clip.path);
    state = const RecordingState(note: clearedOnModelSwitchNote);
  }

  /// An image was attached while a clip was pending (spec Q3): the clip is discarded — the
  /// attachment controller surfaces the one-attachment note alongside the surviving image.
  Future<void> discardForImageAttach() async {
    if (!state.isRecording && !state.hasClip) return;
    _cancelTimers();
    if (state.isRecording) await _recorder.cancel();
    final clip = state.clip;
    await _stopPlayerIfTracked();
    if (clip != null) await _deleteTemp(clip.path);
    state = const RecordingState();
  }

  /// App backgrounded / audio focus lost (FR-021, US6): a live recording stops and keeps the
  /// clip when it meets the minimum (note), discards it otherwise (note); any preview playback
  /// is released (Principle VIII).
  Future<void> onAppBackgrounded() async {
    if (state.isRecording) {
      _cancelTimers();
      final recorded = await _recorder.stop();
      if (recorded == null) {
        state = const RecordingState(note: interruptedDiscardedNote);
      } else if (recorded.durationMs <
          AudioConstants.minClipDuration.inMilliseconds) {
        await _deleteTemp(recorded.path);
        state = const RecordingState(note: interruptedDiscardedNote);
      } else {
        _promote(recorded, note: interruptedKeptNote);
      }
      return;
    }
    if (state.isPreviewPlaying) {
      await _stopPlayerIfTracked();
    }
  }

  /// Dismiss the mic permission explainer (FR-012) — the composer stays fully usable.
  void dismissPrompt() =>
      state = state.copyWith(permissionPrompt: MicPermissionPrompt.none);

  /// Open the OS app-settings page so the user can grant a permanently-denied mic permission
  /// (FR-011, shared `openSettings()` on the permission seam).
  Future<void> openSettings() => _permission.openSettings();

  /// Dismiss the transient note/error line.
  void dismissMessage() =>
      state = state.copyWith(clearNote: true, clearError: true);

  Future<void> _deleteTemp(String path) =>
      ref.read(tempFileDeleterProvider)(path);
}

/// Deletes an unsent recorder temp file (the controller's cleanup duty —
/// contracts/audio_recorder.md #4). Injectable: widget tests run in flutter_test's fake-async
/// zone, where real file-I/O futures never complete, so they override this with an in-memory
/// no-op while unit tests keep the real deletion.
final tempFileDeleterProvider = Provider<Future<void> Function(String path)>((
  ref,
) {
  return (path) async {
    final file = File(path);
    if (await file.exists()) {
      await file.delete();
    }
  };
});

final recordingControllerProvider =
    NotifierProvider<RecordingController, RecordingState>(
      RecordingController.new,
    );
