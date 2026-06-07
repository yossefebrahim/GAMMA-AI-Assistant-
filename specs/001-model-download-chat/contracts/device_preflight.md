# Contract: DevicePreflightService

**Feature**: `001-model-download-chat` | FR-003–FR-006, Principle V

Abstraction over `device_info_plus` (R4). The only seam for device-capability checks. Concrete
`DeviceInfoPreflightService` (in `lib/core/platform/`) is the only file importing
`device_info_plus`; the onboarding controller depends on this interface and tests with a fake.

## Interface

```dart
enum IneligibleReason { insufficientMemory, unsupportedAbi }

class DeviceCapability {
  final int ramMb;                 // device_info_plus physicalRamSize (MB)
  final List<String> abis;         // supportedAbis
  final bool meetsRamBaseline;     // ramMb >= 7000
  final bool supportsArm64;        // abis.contains('arm64-v8a')
  final bool isEligible;           // meetsRamBaseline && supportsArm64
  final IneligibleReason? reason;  // null when eligible
}

abstract interface class DevicePreflightService {
  /// Inspect the device BEFORE any download (FR-003). Pure read; no side effects.
  Future<DeviceCapability> check();
}
```

## Semantics & guarantees

| # | Behavior | Source |
|---|----------|--------|
| 1 | Runs before the download is offered/started; if `!isEligible`, the download MUST NOT start. | FR-003, FR-004 |
| 2 | RAM gate: `ramMb >= 7000` (real 8 GB devices report ~7400–7700 MB). | FR-003, R4 |
| 3 | ABI gate: requires `arm64-v8a`. | FR-003, R4 |
| 4 | On ineligibility, `reason` drives an honest, specific message; the app stays running (no crash/OOM). | FR-004, FR-006 |
| 5 | Eligible devices pass silently and proceed. | FR-005 |
| 6 | Guarded by `Platform.isAndroid`; no network. | Principle I, R4 |

## Concrete mapping (device_info_plus ≥ 11.4.0)

- `DeviceInfoPlugin().androidInfo` → `physicalRamSize` (MB), `supportedAbis`.
- `meetsRamBaseline = physicalRamSize >= 7000`; `supportsArm64 = supportedAbis.contains('arm64-v8a')`.
- Optional soft-warn band 6500–7000 MB ("below recommended 8 GB") — informational, not a block.

## Test double — `FakeDevicePreflightService`

Returns a canned `DeviceCapability`. Test matrix: eligible (8 GB/arm64), insufficient memory
(6 GB), unsupported ABI (armeabi-v7a / x86 emulator), and boundary (exactly 7000 MB → eligible).
Drives the onboarding gate UI without a device.
