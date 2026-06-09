# Contract — MediaPermissionService mic extensions (003)

Extends the 002 contract in place; the camera surface is unchanged.

```dart
abstract interface class MediaPermissionService {
  Future<MediaPermissionStatus> cameraStatus();   // 002, unchanged
  Future<MediaPermissionStatus> requestCamera();  // 002, unchanged
  Future<MediaPermissionStatus> micStatus();      // NEW
  Future<MediaPermissionStatus> requestMic();     // NEW
  Future<void> openSettings();                    // 002, unchanged (shared)
}
// MediaPermissionStatus { granted, denied, permanentlyDenied, restricted } — unchanged
```

Concrete: `PermissionHandlerService` (`permission_handler ^12.0.0`, already pinned) maps the new
methods to `Permission.microphone`. Stays confined to `lib/infrastructure/media/`.

## Guarantees

1. `micStatus()` never prompts; `requestMic()` is the only prompting call and is invoked only
   from the user's mic tap (request on first use — FR-010; never at app launch).
2. Status mapping is identical to camera: platform "ask again allowed" → `denied`; "don't ask
   again"/blocked → `permanentlyDenied`; managed-device restriction → `restricted`.
3. The decision tree is the 002 camera tree verbatim, applied by the recording controller:
   granted → start recording · denied → request → granted ? record : explainer · permanentlyDenied
   → explainer with **open settings** action (grant button hidden) · restricted → explainer
   (no grant path). The explainer is the existing monochrome dialog pattern; dismissing it always
   returns to a fully usable composer (FR-012) — enforced in the controller, not assumed.
4. AndroidManifest adds exactly `<uses-permission android:name="android.permission.RECORD_AUDIO"/>`
   — no broader audio/storage permissions (002 minimal-surface posture).

## FakeMediaPermissionService (extended)

Scripts independent status sequences for camera and mic; records `requestMic()` and
`openSettings()` calls. Existing 002 camera tests are untouched.
