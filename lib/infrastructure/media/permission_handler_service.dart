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
  @override
  Future<MediaPermissionStatus> cameraStatus() async =>
      _map(await Permission.camera.status);

  @override
  Future<MediaPermissionStatus> requestCamera() async =>
      _map(await Permission.camera.request());

  @override
  Future<MediaPermissionStatus> micStatus() async =>
      _map(await Permission.microphone.status);

  @override
  Future<MediaPermissionStatus> requestMic() async =>
      _map(await Permission.microphone.request());

  @override
  Future<void> openSettings() async {
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
