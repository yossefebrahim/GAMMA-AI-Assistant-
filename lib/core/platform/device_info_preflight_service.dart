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
    // Android-only (Principle IX). On any other platform there is no arm64 Android device, so
    // report ineligible-by-ABI rather than crashing.
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
