/// The permission states the UI must distinguish to drive the "explain why / guide to settings,
/// never fail silently" flow (FR-009/FR-010).
enum MediaPermissionStatus { granted, denied, permanentlyDenied, restricted }

/// The single seam over runtime permissions (`permission_handler`). The concrete
/// `PermissionHandlerService` lives in `lib/infrastructure/media/` (enforced by
/// tool/check_plugin_seam.sh); the attachment/recording controllers depend on this interface and
/// unit-test with `FakeMediaPermissionService`.
///
/// **Camera** (002) and **microphone** (003) are modeled — one seam, two permissions, the same
/// enum and explainer decision tree (003 contracts/media_permission.md). The photo library is
/// permissionless on modern Android (the Photo Picker grants per-image access), so the library
/// path is attempted directly (R3).
abstract interface class MediaPermissionService {
  /// Current camera permission status.
  Future<MediaPermissionStatus> cameraStatus();

  /// Prompt for camera access; returns the resulting status.
  Future<MediaPermissionStatus> requestCamera();

  /// Current microphone permission status (003). Never prompts.
  Future<MediaPermissionStatus> micStatus();

  /// Prompt for microphone access; returns the resulting status. The ONLY prompting call on the
  /// mic path — invoked only from the user's mic tap (request on first use, 003 FR-010; never at
  /// app launch).
  Future<MediaPermissionStatus> requestMic();

  /// Current "all files access" (`MANAGE_EXTERNAL_STORAGE`) status. Never prompts. Gates whether
  /// the model can be downloaded to / read from the public, uninstall-surviving storage folder
  /// (`ModelCatalog.publicAppDirectory`). Always `granted` off-Android.
  Future<MediaPermissionStatus> storageStatus();

  /// Prompt for "all files access". On Android 11+ this opens the system all-files-access settings
  /// page and returns the resulting status when the user comes back. Invoked only from the model
  /// download flow (request on first use, never at app launch), so the model file persists across
  /// reinstalls.
  Future<MediaPermissionStatus> requestStorage();

  /// Open the OS app-settings page so the user can change a permanently-denied permission
  /// (FR-010). Shared by the camera, mic, and storage flows.
  Future<void> openSettings();
}
