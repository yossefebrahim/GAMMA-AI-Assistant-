import 'dart:async';

import 'package:ai_assistant/domain/services/media_permission_service.dart';
import 'package:ai_assistant/domain/services/media_picker_service.dart';
import 'package:ai_assistant/features/chat/chat_providers.dart';
import 'package:ai_assistant/features/chat/recording_controller.dart';
import 'package:ai_assistant/infrastructure/media/image_picker_service.dart';
import 'package:ai_assistant/infrastructure/media/permission_handler_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:meta/meta.dart';

/// The previewed-but-unsent image in the composer (data-model: transient composer state). Holds the
/// picker's temp-file path; copied into app-private storage on send (R5). At most one at a time
/// (FR-002); picking another replaces it (FR-003).
@immutable
class PendingAttachment {
  const PendingAttachment({required this.path, this.mimeType});

  final String path;
  final String? mimeType;

  @override
  bool operator ==(Object other) =>
      other is PendingAttachment &&
      other.path == path &&
      other.mimeType == mimeType;

  @override
  int get hashCode => Object.hash(path, mimeType);
}

/// How the attachment flow needs the UI to route a missing permission (US4, FR-009/FR-010). `none`
/// while there is nothing to explain.
enum AttachmentPrompt { none, permissionDenied, permissionPermanentlyDenied }

/// Composer attachment state: the pending image, a transient [note] (e.g. cleared on a model
/// switch — FR-008), a [permissionPrompt] routing hint (US4), and a pick/processing [error]
/// ("pick another" — FR-021).
@immutable
class AttachmentState {
  const AttachmentState({
    this.pending,
    this.note,
    this.permissionPrompt = AttachmentPrompt.none,
    this.error,
  });

  final PendingAttachment? pending;
  final String? note;
  final AttachmentPrompt permissionPrompt;
  final String? error;

  bool get hasPending => pending != null;

  AttachmentState copyWith({
    PendingAttachment? pending,
    bool clearPending = false,
    String? note,
    bool clearNote = false,
    AttachmentPrompt? permissionPrompt,
    String? error,
    bool clearError = false,
  }) {
    return AttachmentState(
      pending: clearPending ? null : (pending ?? this.pending),
      note: clearNote ? null : (note ?? this.note),
      permissionPrompt: permissionPrompt ?? this.permissionPrompt,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

/// Owns the composer's pending-attachment lifecycle (FR-001/FR-002/FR-003): pick from camera or
/// library, preview, remove, replace, clear. The permission lifecycle around the camera path is
/// layered on in US4 (T041); capability-driven clearing is layered on in US2 (T032). Pick errors
/// are surfaced for those phases to route.
class AttachmentController extends Notifier<AttachmentState> {
  /// The brief note shown when a pending image is dropped because the new model can't take images.
  static const String clearedOnModelSwitchNote =
      'image removed — this model does not accept images';

  /// Surfaced when a picked image is too large / unusable, so the user can pick another (FR-021).
  static const String pickAnotherError =
      "that image can't be used — pick another";

  /// One attachment per message (003 spec Q3): attaching an image replaces a pending voice clip.
  static const String clipReplacedNote =
      'one attachment per message — voice clip removed';

  @override
  AttachmentState build() {
    // Capability-driven clearing (FR-008): if the active model flips to image-unsupported while an
    // image is pending, drop it and surface a brief note. Capabilities are DATA (Principle III).
    //
    // Guard on a genuinely LOADED model (modelSessionReadyProvider): a loading or FAILED session
    // also reports textOnly, but that is not a "this model can't take images" situation — the chat
    // screen surfaces loading/failure on its own. Dropping the image there would mislead the user
    // (002 audit: a 0.16.x model-load failure surfaced as "image removed — this model does not
    // accept images"). The note now fires only on a real switch to a loaded text-only model.
    ref.listen(modelCapabilitiesProvider, (previous, next) {
      final ready = ref.read(modelSessionReadyProvider);
      if (!next.image && state.pending != null && ready) {
        state = const AttachmentState(note: clearedOnModelSwitchNote);
      }
      // The audio edition of the same rule (003 US2, FR-008/FR-009): a pending clip is cleared
      // (with its note, set by the recording controller) ONLY for a genuinely loaded
      // audio-incapable model — never during loading/error (the 002 conflation lesson).
      if (!next.audio && ready) {
        unawaited(
          ref
              .read(recordingControllerProvider.notifier)
              .clearForCapabilityFlip(),
        );
      }
    });
    return const AttachmentState();
  }

  MediaPickerService get _picker => ref.read(mediaPickerServiceProvider);
  MediaPermissionService get _permission =>
      ref.read(mediaPermissionServiceProvider);

  /// Pick from the photo library (permissionless Photo Picker on modern Android, R3). A returned
  /// image becomes the pending attachment (replacing any existing one); a cancel leaves state as-is.
  /// A legacy device that denies media access falls back to the explainer (FR-009/FR-011).
  Future<void> pickFromLibrary() async {
    try {
      final picked = await _picker.pickFromLibrary();
      _setPending(picked);
    } on MediaAccessException {
      state = state.copyWith(
        permissionPrompt: AttachmentPrompt.permissionDenied,
      );
    }
  }

  /// Capture from the camera, resolving the camera permission first (FR-009/FR-010): proceed when
  /// granted, request when askable, and route to an explainer (with a settings path) when denied or
  /// permanently denied/restricted. Declining never blocks text chat (FR-011) — it only sets a
  /// dismissible prompt.
  Future<void> pickFromCamera() async {
    final status = await _permission.cameraStatus();
    switch (status) {
      case MediaPermissionStatus.granted:
        await _capture();
      case MediaPermissionStatus.denied:
        final result = await _permission.requestCamera();
        if (result == MediaPermissionStatus.granted) {
          await _capture();
        } else if (result == MediaPermissionStatus.permanentlyDenied ||
            result == MediaPermissionStatus.restricted) {
          state = state.copyWith(
            permissionPrompt: AttachmentPrompt.permissionPermanentlyDenied,
          );
        } else {
          state = state.copyWith(
            permissionPrompt: AttachmentPrompt.permissionDenied,
          );
        }
      case MediaPermissionStatus.permanentlyDenied:
      case MediaPermissionStatus.restricted:
        state = state.copyWith(
          permissionPrompt: AttachmentPrompt.permissionPermanentlyDenied,
        );
    }
  }

  Future<void> _capture() async {
    try {
      final picked = await _picker.pickFromCamera();
      _setPending(picked);
    } on MediaAccessException {
      state = state.copyWith(
        permissionPrompt: AttachmentPrompt.permissionDenied,
      );
    }
  }

  void _setPending(PickedImage? picked) {
    if (picked == null) {
      return; // cancel — leave the prior state untouched (FR-003 / edge: cancel)
    }
    // One attachment per message (003 spec Q3): attaching an image discards a pending/in-progress
    // voice clip (the recording controller deletes its temp file and stops any preview) and the
    // one-attachment note rides with the surviving image.
    final recording = ref.read(recordingControllerProvider);
    final replacedClip = recording.hasClip || recording.isRecording;
    if (replacedClip) {
      unawaited(
        ref.read(recordingControllerProvider.notifier).discardForImageAttach(),
      );
    }
    state = AttachmentState(
      pending: PendingAttachment(path: picked.path, mimeType: picked.mimeType),
      note: replacedClip ? clipReplacedNote : null,
    );
  }

  /// Reject the pending image and prompt for another (FR-021) — called when the image store rejects
  /// an oversized/unreadable file at send time. Keeps text chat usable.
  void rejectPending() =>
      state = const AttachmentState(error: pickAnotherError);

  /// Open the OS app-settings page so the user can grant a permanently-denied permission (FR-010).
  Future<void> openSettings() async {
    await _permission.openSettings();
  }

  /// Dismiss the permission explainer (FR-011) — leaves any pending image and keeps text chat
  /// fully usable.
  void dismissPrompt() => state = state.copyWith(
    permissionPrompt: AttachmentPrompt.none,
    clearNote: true,
  );

  /// Remove the pending attachment (FR-003).
  void remove() => state = const AttachmentState();

  /// Clear all transient state — called after a successful send.
  void clear() => state = const AttachmentState();
}

final attachmentControllerProvider =
    NotifierProvider<AttachmentController, AttachmentState>(
      AttachmentController.new,
    );
