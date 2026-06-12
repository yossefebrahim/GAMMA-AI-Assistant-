import 'package:ai_assistant/domain/services/media_picker_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

/// THE concrete [MediaPickerService] over `image_picker` — confined to `lib/infrastructure/media/`
/// (enforced by tool/check_plugin_seam.sh), so the composer/attachment controller test with
/// `FakeMediaPickerService` (002 R2). Single image only (FR-002).
///
/// Images are downscaled at pick time (`maxWidth/maxHeight 1536`, `imageQuality 90`) natively, off
/// the Dart UI isolate, so the stored copy is modest and stays under flutter_gemma's 10 MB cap
/// (R2/R4). The library path uses the system Photo Picker → no storage permission on modern Android
/// (R3). The returned `path` is a temp file; the caller persists it via `ImageFileStore` on send.
class ImagePickerService implements MediaPickerService {
  ImagePickerService([ImagePicker? picker]) : _picker = picker ?? ImagePicker();

  final ImagePicker _picker;

  static const double _maxDimension = 1536;
  static const int _quality = 90;

  @override
  Future<PickedImage?> pickFromCamera() => _pick(ImageSource.camera);

  @override
  Future<PickedImage?> pickFromLibrary() => _pick(ImageSource.gallery);

  Future<PickedImage?> _pick(ImageSource source) async {
    final file = await _picker.pickImage(
      source: source,
      maxWidth: _maxDimension,
      maxHeight: _maxDimension,
      imageQuality: _quality,
    );
    if (file == null) {
      return null; // user cancelled → not an error (contract #3)
    }
    return PickedImage(path: file.path, mimeType: file.mimeType);
  }
}

/// App-wide [MediaPickerService]. Overridable in tests with `FakeMediaPickerService`.
final mediaPickerServiceProvider = Provider<MediaPickerService>(
  (ref) => ImagePickerService(),
);
