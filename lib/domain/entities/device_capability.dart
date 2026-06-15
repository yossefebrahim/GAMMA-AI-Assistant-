import 'package:meta/meta.dart';

/// Why a device cannot run the model (drives the honest blocked message, FR-004/FR-006).
enum IneligibleReason { insufficientMemory, unsupportedAbi }

/// Transient value object computed at preflight (FR-003…FR-006). Never persisted.
@immutable
class DeviceCapability {
  const DeviceCapability({
    required this.ramMb,
    required this.abis,
    required this.meetsRamBaseline,
    required this.supportsArm64,
    required this.isEligible,
    required this.reason,
  });

  /// `device_info_plus` `physicalRamSize`, in MB.
  final int ramMb;

  /// `supportedAbis`.
  final List<String> abis;

  /// `ramMb >= [ramBaselineMb]` (R4 — real 8 GB devices report ~7400–7700 MB).
  final bool meetsRamBaseline;

  final bool supportsArm64;

  /// `meetsRamBaseline && supportsArm64`.
  final bool isEligible;

  /// `null` when eligible.
  final IneligibleReason? reason;

  /// Hard RAM floor in MB (FR-003). Real 8 GB devices report ~7400–7700 MB because `totalMem`
  /// excludes kernel/DMA/baseband-reserved memory, so testing against 8192/8000 would falsely
  /// reject genuine 8 GB phones (R4). Below this → ineligible ([IneligibleReason.insufficientMemory]).
  static const int ramBaselineMb = 7000;

  /// "Below recommended 8 GB" informational threshold. An eligible device reporting under this
  /// (i.e. in 7000–7699 MB) is allowed but soft-warned about low headroom (R4) — never blocked.
  static const int recommendedRamMb = 7700;

  static const String requiredAbi = 'arm64-v8a';

  /// Derive a capability verdict from raw probe values (FR-003, R4). ABI is checked first so a
  /// non-arm64 device with ample RAM still reports the architecture reason.
  factory DeviceCapability.fromProbe({
    required int ramMb,
    required List<String> abis,
  }) {
    final supportsArm64 = abis.contains(requiredAbi);
    final meetsRamBaseline = ramMb >= ramBaselineMb;
    final isEligible = supportsArm64 && meetsRamBaseline;
    final IneligibleReason? reason = isEligible
        ? null
        : !supportsArm64
        ? IneligibleReason.unsupportedAbi
        : IneligibleReason.insufficientMemory;
    return DeviceCapability(
      ramMb: ramMb,
      abis: List.unmodifiable(abis),
      meetsRamBaseline: meetsRamBaseline,
      supportsArm64: supportsArm64,
      isEligible: isEligible,
      reason: reason,
    );
  }

  /// Derive a capability verdict for macOS (Apple Silicon) — 007 macOS support, constitution v2.1.0
  /// Principle V macOS tier. The Android `arm64-v8a` ABI string and the Android RAM under-reporting
  /// do NOT apply here: macOS reports full physical (unified) memory and Apple Silicon reports
  /// `arm64`. Intel (x86_64) Macs are reported [IneligibleReason.unsupportedAbi] because
  /// flutter_gemma ships no x86_64 desktop backend — caught up front, never a runtime native-load
  /// crash (FR-002).
  factory DeviceCapability.fromMacProbe({
    required int ramMb,
    required bool isAppleSilicon,
  }) {
    final meetsRamBaseline = ramMb >= ramBaselineMb;
    final isEligible = isAppleSilicon && meetsRamBaseline;
    final IneligibleReason? reason = isEligible
        ? null
        : !isAppleSilicon
        ? IneligibleReason.unsupportedAbi
        : IneligibleReason.insufficientMemory;
    return DeviceCapability(
      ramMb: ramMb,
      abis: List.unmodifiable(
        isAppleSilicon ? const <String>['arm64'] : const <String>['x86_64'],
      ),
      meetsRamBaseline: meetsRamBaseline,
      supportsArm64: isAppleSilicon,
      isEligible: isEligible,
      reason: reason,
    );
  }

  /// Eligible device that is still below the comfortable 8 GB recommendation (informational only,
  /// never a block). Drives the US5 soft-warn band messaging.
  bool get isSoftWarn => isEligible && ramMb < recommendedRamMb;
}
