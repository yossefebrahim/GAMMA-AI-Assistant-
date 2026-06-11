import 'dart:io' show Platform;

import 'package:ai_assistant/domain/services/device_info_tool_service.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/services.dart' show MethodChannel, PlatformException, MissingPluginException;

/// `device_info_plus` + `battery_plus` + a ~10-line StatFs `MethodChannel`-backed
/// [DeviceInfoToolService] (004 R4) — the ONLY importer of `battery_plus` (confined to
/// `lib/infrastructure/tools/`, enforced by tool/check_plugin_seam.sh). Read-only, zero runtime
/// permissions.
///
/// Every probe is independently guarded so a single failure degrades that field to `'unknown'`
/// rather than failing the whole snapshot (Principle V). The service never throws.
class PlatformDeviceInfoToolService implements DeviceInfoToolService {
  PlatformDeviceInfoToolService({
    DeviceInfoPlugin? deviceInfo,
    Battery? battery,
    MethodChannel? storageChannel,
  })  : _deviceInfo = deviceInfo ?? DeviceInfoPlugin(),
        _battery = battery ?? Battery(),
        _storageChannel = storageChannel ?? _defaultStorageChannel;

  /// The free-storage channel — a StatFs read in MainActivity (R4: rejected the unmaintained 0.x
  /// `disk_space_plus`; an in-repo channel is ~10 lines of Kotlin in an Android-only app).
  static const MethodChannel _defaultStorageChannel =
      MethodChannel('ai_assistant/device_storage');

  final DeviceInfoPlugin _deviceInfo;
  final Battery _battery;
  final MethodChannel _storageChannel;

  static const String _unknown = 'unknown';

  @override
  Future<Map<String, Object?>> read(Map<String, Object?> args) async {
    final result = <String, Object?>{};

    // Hardware + OS (device_info_plus). Android-only (Principle IX).
    try {
      if (Platform.isAndroid) {
        final info = await _deviceInfo.androidInfo;
        result['model'] = '${info.manufacturer} ${info.model}'.trim();
        result['androidVersion'] = 'Android ${info.version.release}';
        result['sdkInt'] = info.version.sdkInt;
        result['ramTotalMb'] = info.physicalRamSize;
      } else {
        result['model'] = _unknown;
        result['androidVersion'] = _unknown;
      }
    } catch (_) {
      result['model'] = _unknown;
      result['androidVersion'] = _unknown;
    }

    // Battery (battery_plus).
    try {
      result['batteryLevel'] = await _battery.batteryLevel;
    } catch (_) {
      result['batteryLevel'] = _unknown;
    }
    try {
      result['batteryState'] = _stateName(await _battery.batteryState);
    } catch (_) {
      result['batteryState'] = _unknown;
    }

    // Free/total storage (StatFs channel). A missing channel (non-Android, or the method not
    // registered) degrades to unknown rather than throwing (MissingPluginException).
    try {
      final storage =
          await _storageChannel.invokeMapMethod<String, Object?>('getStorage');
      result['storageFreeBytes'] = storage?['freeBytes'] ?? _unknown;
      result['storageTotalBytes'] = storage?['totalBytes'] ?? _unknown;
    } on MissingPluginException {
      result['storageFreeBytes'] = _unknown;
      result['storageTotalBytes'] = _unknown;
    } on PlatformException {
      result['storageFreeBytes'] = _unknown;
      result['storageTotalBytes'] = _unknown;
    } catch (_) {
      result['storageFreeBytes'] = _unknown;
      result['storageTotalBytes'] = _unknown;
    }

    return result;
  }

  String _stateName(BatteryState state) => switch (state) {
        BatteryState.charging => 'charging',
        BatteryState.discharging => 'discharging',
        BatteryState.full => 'full',
        BatteryState.connectedNotCharging => 'connected not charging',
        BatteryState.unknown => _unknown,
      };
}
