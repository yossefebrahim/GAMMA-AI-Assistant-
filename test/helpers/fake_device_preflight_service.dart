import 'package:ai_assistant/domain/entities/device_capability.dart';
import 'package:ai_assistant/domain/services/device_preflight_service.dart';

/// In-memory [DevicePreflightService] for unit/widget tests (contract: device_preflight.md).
///
/// Returns a canned [DeviceCapability]. Use the named constructors for the contract test matrix:
/// eligible (8 GB/arm64), insufficient memory (6 GB), unsupported ABI, and the 7000 MB boundary.
class FakeDevicePreflightService implements DevicePreflightService {
  FakeDevicePreflightService(this.capability);

  /// Build the verdict from raw probe values, exercising the real derivation logic.
  FakeDevicePreflightService.fromProbe({
    required int ramMb,
    required List<String> abis,
  }) : capability = DeviceCapability.fromProbe(ramMb: ramMb, abis: abis);

  /// A supported device: 8 GB-class RAM reporting ~7600 MB, arm64-v8a.
  FakeDevicePreflightService.eligible()
    : capability = DeviceCapability.fromProbe(
        ramMb: 7600,
        abis: const ['arm64-v8a'],
      );

  /// A 6 GB device (reports ~5800 MB) → insufficient memory.
  FakeDevicePreflightService.insufficientMemory()
    : capability = DeviceCapability.fromProbe(
        ramMb: 5800,
        abis: const ['arm64-v8a'],
      );

  /// A non-arm64 device (e.g. an x86 emulator) → unsupported ABI.
  FakeDevicePreflightService.unsupportedAbi()
    : capability = DeviceCapability.fromProbe(
        ramMb: 8000,
        abis: const ['x86_64', 'x86'],
      );

  DeviceCapability capability;

  @override
  Future<DeviceCapability> check() async => capability;
}
