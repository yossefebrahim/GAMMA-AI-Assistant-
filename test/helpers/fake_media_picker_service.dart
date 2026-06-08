import 'package:ai_assistant/domain/services/media_picker_service.dart';

/// In-memory [MediaPickerService] for unit/widget tests (contract: media_picker.md "Test double").
///
/// Scriptable per source to return a [PickedImage], `null` (user cancel), or throw a
/// [MediaAccessException] — so the attachment controller can be tested for
/// pick → preview → replace → remove and the denied path without a device.
class FakeMediaPickerService implements MediaPickerService {
  /// What [pickFromCamera] returns (null = cancel).
  PickedImage? cameraResult;

  /// What [pickFromLibrary] returns (null = cancel).
  PickedImage? libraryResult;

  /// When true, [pickFromCamera] throws [MediaAccessException].
  bool throwCameraAccess = false;

  /// When true, [pickFromLibrary] throws [MediaAccessException].
  bool throwLibraryAccess = false;

  // --- call recorders ---
  int cameraCalls = 0;
  int libraryCalls = 0;

  @override
  Future<PickedImage?> pickFromCamera() async {
    cameraCalls++;
    if (throwCameraAccess) throw const MediaAccessException('camera');
    return cameraResult;
  }

  @override
  Future<PickedImage?> pickFromLibrary() async {
    libraryCalls++;
    if (throwLibraryAccess) throw const MediaAccessException('library');
    return libraryResult;
  }
}
