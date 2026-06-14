import 'dart:io';

import 'package:ai_assistant/domain/services/media_permission_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

/// THE concrete [MediaPermissionService] over `permission_handler` — confined to
/// `lib/infrastructure/media/` (enforced by tool/check_plugin_seam.sh), so the attachment and
/// recording controllers test with `FakeMediaPermissionService` (002 R3 / 003 R5). **Camera**
/// (002) and **microphone** (003) are modeled; the photo library is permissionless on modern
/// Android (the Photo Picker). The status mapping is identical for both permissions
/// (003 contracts/media_permission.md #2).
class PermissionHandlerService implements MediaPermissionService {
  /// `permission_handler` implements Android/iOS (+web/windows for some permissions) but has NO
  /// macOS plugin, so calling `Permission.camera`/`.microphone` on macOS throws
  /// `MissingPluginException`. On macOS the OS shows its own TCC prompt the first time
  /// `record_macos` (or a file picker) touches the mic/camera, so the correct behavior is to report
  /// granted and let that native prompt happen (007 macOS support, FR-007). Mirrors the existing
  /// off-Android storage short-circuit below.
  static bool get _usesPermissionHandler => Platform.isAndroid || Platform.isIOS;

  @override
  Future<MediaPermissionStatus> cameraStatus() async => _usesPermissionHandler
      ? _map(await Permission.camera.status)
      : MediaPermissionStatus.granted;

  @override
  Future<MediaPermissionStatus> requestCamera() async => _usesPermissionHandler
      ? _map(await Permission.camera.request())
      : MediaPermissionStatus.granted;

  @override
  Future<MediaPermissionStatus> micStatus() async => _usesPermissionHandler
      ? _map(await Permission.microphone.status)
      : MediaPermissionStatus.granted;

  @override
  Future<MediaPermissionStatus> requestMic() async => _usesPermissionHandler
      ? _map(await Permission.microphone.request())
      : MediaPermissionStatus.granted;

  @override
  Future<MediaPermissionStatus> storageStatus() async {
    // Off-Android there is no all-files-access concept; treat as granted so the downloader uses
    // its app-private fallback path without a spurious permission block.
    if (!Platform.isAndroid) return MediaPermissionStatus.granted;
    return _map(await Permission.manageExternalStorage.status);
  }

  @override
  Future<MediaPermissionStatus> requestStorage() async {
    if (!Platform.isAndroid) return MediaPermissionStatus.granted;
    return _map(await Permission.manageExternalStorage.request());
  }

  @override
  Future<void> openSettings() async {
    // `openAppSettings()` is also unimplemented on macOS; it is only reached from the storage /
    // camera / mic permanently-denied paths, none of which occur on macOS (all granted above).
    if (!_usesPermissionHandler) return;
    await openAppSettings();
  }

  MediaPermissionStatus _map(PermissionStatus status) {
    if (status.isGranted || status.isLimited) {
      return MediaPermissionStatus.granted;
    }
    if (status.isPermanentlyDenied) {
      return MediaPermissionStatus.permanentlyDenied;
    }
    if (status.isRestricted) return MediaPermissionStatus.restricted;
    return MediaPermissionStatus.denied;
  }
}

/// App-wide [MediaPermissionService]. Overridable in tests with `FakeMediaPermissionService`.
final mediaPermissionServiceProvider = Provider<MediaPermissionService>(
  (ref) => PermissionHandlerService(),
);
