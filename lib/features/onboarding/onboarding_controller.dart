import 'package:ai_assistant/core/platform/device_info_preflight_service.dart';
import 'package:ai_assistant/data/repositories/settings_repository.dart';
import 'package:ai_assistant/domain/entities/device_capability.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Result of acknowledging the license and preflighting the device (FR-003/FR-005).
class PreflightOutcome {
  const PreflightOutcome._({
    required this.eligible,
    this.softWarn = false,
    this.reason,
  });

  /// Device passed preflight; proceed to download. [softWarn] flags an eligible-but-low-headroom
  /// device ("below recommended 8 GB").
  const PreflightOutcome.eligible({bool softWarn = false})
    : this._(eligible: true, softWarn: softWarn);

  /// Device failed preflight; route to the blocked screen with [reason].
  const PreflightOutcome.blocked(IneligibleReason reason)
    : this._(eligible: false, reason: reason);

  final bool eligible;
  final bool softWarn;
  final IneligibleReason? reason;
}

/// Drives onboarding: persists the one-time license acknowledgment (clarification Q1), then runs
/// the device preflight (FR-003) BEFORE any download is offered. Exposes `isChecking` as state so
/// the license screen can disable its action while the check runs.
class OnboardingController extends Notifier<bool> {
  @override
  bool build() => false;

  /// Acknowledge the license, then preflight. The license ack gates this — the download is never
  /// offered until it completes (Q1).
  Future<PreflightOutcome> acknowledgeAndPreflight() async {
    state = true;
    try {
      await ref
          .read(settingsRepositoryProvider)
          .acknowledgeLicense(DateTime.now().toUtc());
      final capability = await ref.read(devicePreflightServiceProvider).check();
      if (capability.isEligible) {
        return PreflightOutcome.eligible(softWarn: capability.isSoftWarn);
      }
      return PreflightOutcome.blocked(capability.reason!);
    } finally {
      state = false;
    }
  }
}

final onboardingControllerProvider =
    NotifierProvider<OnboardingController, bool>(OnboardingController.new);
