import 'dart:io';

import 'package:ai_assistant/data/images/image_file_store.dart';
import 'package:ai_assistant/domain/services/media_permission_service.dart';
import 'package:ai_assistant/domain/services/media_picker_service.dart';
import 'package:ai_assistant/features/chat/chat_providers.dart';
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
      other is PendingAttachment && other.path == path && other.mimeType == mimeType;

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
  static const String pickAnotherError = "that image can't be used — pick another";

  @override
  AttachmentState build() {
    // Capability-driven clearing (FR-008): if the active model flips to image-unsupported while an
    // image is pending, drop it and surface a brief note. Capabilities are DATA (Principle III).
    ref.listen(modelCapabilitiesProvider, (previous, next) {
      if (!next.image && state.pending != null) {
        state = const AttachmentState(note: clearedOnModelSwitchNote);
      }
    });
    return const AttachmentState();
  }

  MediaPickerService get _picker => ref.read(mediaPickerServiceProvider);
  MediaPermissionService get _permission => ref.read(mediaPermissionServiceProvider);

  /// Pick from the photo library (permissionless Photo Picker on modern Android, R3). A returned
  /// image becomes the pending attachment (replacing any existing one); a cancel leaves state as-is.
  /// A legacy device that denies media access falls back to the explainer (FR-009/FR-011).
  Future<void> pickFromLibrary() async {
    try {
      final picked = await _picker.pickFromLibrary();
      await _setPending(picked);
    } on MediaAccessException {
      state = state.copyWith(permissionPrompt: AttachmentPrompt.permissionDenied);
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
          state = state.copyWith(permissionPrompt: AttachmentPrompt.permissionPermanentlyDenied);
        } else {
          state = state.copyWith(permissionPrompt: AttachmentPrompt.permissionDenied);
        }
      case MediaPermissionStatus.permanentlyDenied:
      case MediaPermissionStatus.restricted:
        state = state.copyWith(permissionPrompt: AttachmentPrompt.permissionPermanentlyDenied);
    }
  }

  Future<void> _capture() async {
    try {
      final picked = await _picker.pickFromCamera();
      await _setPending(picked);
    } on MediaAccessException {
      state = state.copyWith(permissionPrompt: AttachmentPrompt.permissionDenied);
    }
  }

  Future<void> _setPending(PickedImage? picked) async {
    if (picked == null) return; // cancel — leave the prior state untouched (FR-003 / edge: cancel)
    // Best-effort pick-time rejection of an empty / oversized image (FR-021); the file store and
    // the seam validate authoritatively at send. A path we can't stat (e.g. a test temp file) is
    // allowed through — the later guards still apply.
    try {
      final length = await File(picked.path).length();
      if (length == 0 || length > ImageFileStore.maxBytes) {
        state = const AttachmentState(error: pickAnotherError);
        return;
      }
    } on FileSystemException {
      // Can't stat — defer to the store/seam guards.
    }
    state = AttachmentState(
      pending: PendingAttachment(path: picked.path, mimeType: picked.mimeType),
    );
  }

  /// Open the OS app-settings page so the user can grant a permanently-denied permission (FR-010).
  Future<void> openSettings() async {
    await _permission.openSettings();
  }

  /// Dismiss the permission explainer (FR-011) — leaves any pending image and keeps text chat
  /// fully usable.
  void dismissPrompt() =>
      state = state.copyWith(permissionPrompt: AttachmentPrompt.none, clearNote: true);

  /// Remove the pending attachment (FR-003).
  void remove() => state = const AttachmentState();

  /// Clear all transient state — called after a successful send.
  void clear() => state = const AttachmentState();
}

final attachmentControllerProvider =
    NotifierProvider<AttachmentController, AttachmentState>(AttachmentController.new);
