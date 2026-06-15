import 'dart:io' show Platform;

import 'package:ai_assistant/domain/entities/device_capability.dart';
import 'package:ai_assistant/domain/services/device_preflight_service.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// `device_info_plus`-backed [DevicePreflightService] (R4) — the ONLY file importing
/// `device_info_plus`. Reads `physicalRamSize` (MB) and `supportedAbis`; the eligibility logic
/// lives in [DeviceCapability.fromProbe]. No network (Principle I).
class DeviceInfoPreflightService implements DevicePreflightService {
  DeviceInfoPreflightService({DeviceInfoPlugin? deviceInfo})
    : _deviceInfo = deviceInfo ?? DeviceInfoPlugin();

  final DeviceInfoPlugin _deviceInfo;

  @override
  Future<DeviceCapability> check() async {
    // macOS (Apple Silicon) is a sanctioned secondary target (007, constitution v2.1.0). Read real
    // unified memory (`memorySize`, bytes) + arch; Intel reports ineligible-by-ABI (no x86_64
    // backend) rather than crashing at native load (FR-002).
    if (Platform.isMacOS) {
      final info = await _deviceInfo.macOsInfo;
      final ramMb = (info.memorySize / (1024 * 1024)).round();
      final isAppleSilicon = info.arch.toLowerCase().contains('arm');
      return DeviceCapability.fromMacProbe(
        ramMb: ramMb,
        isAppleSilicon: isAppleSilicon,
      );
    }
    // Other non-Android platforms (Windows/Linux/web) remain NON-GOALS (Principle IX). Report
    // ineligible-by-ABI rather than crashing.
    if (!Platform.isAndroid) {
      return DeviceCapability.fromProbe(ramMb: 0, abis: const <String>[]);
    }
    final info = await _deviceInfo.androidInfo;
    return DeviceCapability.fromProbe(
      ramMb: info.physicalRamSize,
      abis: info.supportedAbis,
    );
  }
}

final devicePreflightServiceProvider = Provider<DevicePreflightService>((ref) {
  return DeviceInfoPreflightService();
});
