/// The permission states the UI must distinguish to drive the "explain why / guide to settings,
/// never fail silently" flow (FR-009/FR-010).
enum MediaPermissionStatus { granted, denied, permanentlyDenied, restricted }

/// The single seam over runtime permissions (`permission_handler`). The concrete
/// `PermissionHandlerService` lives in `lib/infrastructure/media/` (enforced by
/// tool/check_plugin_seam.sh); the attachment controller depends on this interface and unit-tests
/// with `FakeMediaPermissionService`.
///
/// Only **camera** is modeled: the photo library is permissionless on modern Android (the Photo
/// Picker grants per-image access), so the library path is attempted directly (R3).
abstract interface class MediaPermissionService {
  /// Current camera permission status.
  Future<MediaPermissionStatus> cameraStatus();

  /// Prompt for camera access; returns the resulting status.
  Future<MediaPermissionStatus> requestCamera();

  /// Open the OS app-settings page so the user can change a permanently-denied permission
  /// (FR-010).
  Future<void> openSettings();
}
