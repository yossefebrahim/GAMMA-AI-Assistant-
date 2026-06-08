import 'package:meta/meta.dart';

/// A picked-but-not-yet-persisted image — the picker's temp-file path (FR-001/FR-002). The caller
/// copies it into app-private storage via `ImageFileStore` on send (R5); a cancelled compose leaves
/// nothing persisted.
@immutable
class PickedImage {
  const PickedImage({required this.path, this.mimeType});

  /// The picker's temp-file path.
  final String path;

  /// Optional MIME type reported by the picker.
  final String? mimeType;
}

/// The single seam over image acquisition (`image_picker`). The concrete `ImagePickerService` lives
/// in `lib/infrastructure/media/` (enforced by tool/check_plugin_seam.sh); the composer/attachment
/// controller depend on this interface and unit-test with `FakeMediaPickerService`. Single image
/// only (FR-002) — there is deliberately no multi-pick method.
abstract interface class MediaPickerService {
  /// Capture a new photo with the camera. Returns `null` if the user cancels.
  ///
  /// Throws [MediaAccessException] if camera access is unavailable — the caller resolves access via
  /// `MediaPermissionService` (see media_permission.md).
  Future<PickedImage?> pickFromCamera();

  /// Choose an existing image from the photo library (the Android Photo Picker — permissionless on
  /// modern Android). Returns `null` if the user cancels.
  Future<PickedImage?> pickFromLibrary();
}

/// Raised when acquisition fails because access is denied — distinct from a user cancel (`null`).
class MediaAccessException implements Exception {
  const MediaAccessException(this.source);

  /// `'camera'` | `'library'`.
  final String source;

  @override
  String toString() => 'MediaAccessException: $source access denied';
}
