# Contract: MediaPickerService

**Feature**: `002-image-input-vision` | FR-001, FR-002 | Principle VII (testability discipline)

The single seam over image acquisition (`image_picker`). Concrete `ImagePickerService` lives in
`lib/infrastructure/media/`; the composer/attachment controller depend on this interface and test
with `FakeMediaPickerService`. Single image only (FR-002) — no multi-pick method exists.

## Interface

```dart
/// A picked-but-not-yet-persisted image (the picker's temp-file path).
class PickedImage {
  const PickedImage({required this.path, this.mimeType});
  final String path;       // picker temp path; copied into app-private storage on send
  final String? mimeType;
}

abstract interface class MediaPickerService {
  /// Capture a new photo with the camera. Returns null if the user cancels.
  /// Throws [MediaAccessException] if camera access is unavailable (caller resolves via
  /// MediaPermissionService — see media_permission.md).
  Future<PickedImage?> pickFromCamera();

  /// Choose an existing image from the photo library (Android Photo Picker — permissionless on
  /// modern Android). Returns null if the user cancels.
  Future<PickedImage?> pickFromLibrary();
}

/// Raised when acquisition fails because access is denied (distinct from user cancel = null).
class MediaAccessException implements Exception {
  const MediaAccessException(this.source);   // 'camera' | 'library'
  final String source;
}
```

## Semantics & guarantees

| # | Behavior | Source |
|---|----------|--------|
| 1 | Exactly one image is returned (or null on cancel). | FR-002 |
| 2 | Images are downscaled at pick time (`maxWidth/maxHeight 1536`, `imageQuality 90`) to bound size. | R2/R4 |
| 3 | Cancel returns `null` (not an error) → composer returns to its prior state, no message. | Edge: cancel picker |
| 4 | Library path uses the system Photo Picker → no storage permission on modern Android. | R2/R3 |
| 5 | Returned `path` is a temp file; the caller persists it via `ImageFileStore` on send. | R5 |
| 6 | No network I/O. | Principle I |

## Concrete mapping (ImagePickerService → image_picker)

- `pickFromCamera` → `ImagePicker().pickImage(source: ImageSource.camera, maxWidth: 1536,
  maxHeight: 1536, imageQuality: 90)`.
- `pickFromLibrary` → `ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 1536,
  maxHeight: 1536, imageQuality: 90)`.
- `XFile` → `PickedImage(path: x.path, mimeType: x.mimeType)`; `null` → `null`.

## Test double — `FakeMediaPickerService`

- Scriptable to return a `PickedImage`, `null` (cancel), or throw `MediaAccessException`.
- Lets the attachment controller be tested for pick → preview → replace → remove without a device.
