import 'package:ai_assistant/domain/entities/device_capability.dart';

/// Abstraction over `device_info_plus` (R4) — the only seam for device-capability checks.
///
/// The concrete `DeviceInfoPreflightService` (in `lib/core/platform/`) is the only file importing
/// `device_info_plus`; the onboarding controller depends on this interface and tests with
/// `FakeDevicePreflightService`. See
/// `specs/001-model-download-chat/contracts/device_preflight.md`.
abstract interface class DevicePreflightService {
  /// Inspect the device BEFORE any download (FR-003). Pure read; no side effects, no network.
  /// If the result is not eligible, the download MUST NOT start (FR-004).
  Future<DeviceCapability> check();
}
