# Contract: MediaPermissionService

**Feature**: `002-image-input-vision` | FR-009, FR-010, FR-011 | Principle V (Graceful Degradation)

The single seam over runtime permissions (`permission_handler`). Concrete
`PermissionHandlerService` lives in `lib/infrastructure/media/`; the attachment controller depends on
this interface and tests with `FakeMediaPermissionService`. Drives the "explain why / guide to
settings, never fail silently" flow.

## Interface

```dart
/// Mirrors the permission states the UI must distinguish (FR-009/FR-010).
enum MediaPermissionStatus { granted, denied, permanentlyDenied, restricted }

abstract interface class MediaPermissionService {
  /// Current camera permission status (the photo library is permissionless on modern Android —
  /// the Photo Picker grants per-image access — so only camera is modeled here).
  Future<MediaPermissionStatus> cameraStatus();

  /// Prompt for camera access; returns the resulting status.
  Future<MediaPermissionStatus> requestCamera();

  /// Open the OS app-settings page so the user can change a permanently-denied permission.
  Future<void> openSettings();
}
```

## Semantics & guarantees

| # | Behavior | Source |
|---|----------|--------|
| 1 | `denied` (askable) → caller requests; on grant proceed, else show an explainer. | FR-009 |
| 2 | `permanentlyDenied`/`restricted` → caller shows an explainer + an "open settings" action (`openSettings`). | FR-010 |
| 3 | Declining never dead-ends: text chat stays fully usable (enforced by the controller). | FR-011 |
| 4 | Library acquisition is attempted directly (no prompt); a legacy denial falls back to the same explainer/settings path. | R3 |
| 5 | No network I/O. | Principle I |

## Concrete mapping (PermissionHandlerService → permission_handler)

- `cameraStatus` → `Permission.camera.status` mapped to `MediaPermissionStatus`.
- `requestCamera` → `Permission.camera.request()` mapped likewise.
- `openSettings` → `openAppSettings()`.

## Test double — `FakeMediaPermissionService`

- Scriptable status sequence (e.g. `denied` then `granted`, or `permanentlyDenied`) and an
  `openSettings()` call recorder — so the explainer/settings/decline branches (FR-009/FR-010/FR-011)
  are unit-testable without a device.
