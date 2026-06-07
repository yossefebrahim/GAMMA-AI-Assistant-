import 'dart:async';

import 'package:ai_assistant/app/router.dart';
import 'package:ai_assistant/app/theme/app_colors.dart';
import 'package:ai_assistant/app/theme/app_spacing.dart';
import 'package:ai_assistant/app/theme/app_text.dart';
import 'package:ai_assistant/app/widgets/primary_button.dart';
import 'package:ai_assistant/domain/entities/device_capability.dart';
import 'package:ai_assistant/features/onboarding/onboarding_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// One-time model-license acknowledgment (clarification Q1). The continue action is gated on the
/// checkbox — the download is never offered until the user acknowledges. On continue we persist
/// the ack and preflight the device (FR-003): eligible → download, otherwise → blocked.
class LicenseScreen extends ConsumerStatefulWidget {
  const LicenseScreen({super.key});

  static const Key checkboxKey = Key('license-acknowledge-checkbox');
  static const Key continueKey = Key('license-continue-button');

  @override
  ConsumerState<LicenseScreen> createState() => _LicenseScreenState();
}

class _LicenseScreenState extends ConsumerState<LicenseScreen> {
  bool _accepted = false;

  Future<void> _continue() async {
    final outcome =
        await ref.read(onboardingControllerProvider.notifier).acknowledgeAndPreflight();
    if (!mounted) return;
    final navigator = Navigator.of(context);
    if (outcome.eligible) {
      // Pass the soft-warn flag so the download screen can show the "below recommended 8 GB"
      // notice (R4) — informational, never a block.
      unawaited(navigator.pushReplacementNamed(AppRoutes.download, arguments: outcome.softWarn));
    } else {
      unawaited(navigator.pushReplacementNamed(
        AppRoutes.preflightBlocked,
        arguments: outcome.reason ?? IneligibleReason.insufficientMemory,
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.extension<AppColors>()!;
    final isChecking = ref.watch(onboardingControllerProvider);

    return Scaffold(
      appBar: AppBar(title: Text(AppText.spec('model license'), style: theme.textTheme.labelSmall)),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.heroPadding),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: AppSpacing.s8),
              Text('the model ( ${'gemma 4 e2b'} )', style: theme.textTheme.titleLarge),
              const SizedBox(height: AppSpacing.s16),
              Expanded(
                child: SingleChildScrollView(
                  child: Text(
                    'the default model is provided under its own license. it is downloaded once and '
                    'then runs entirely on your device. by continuing you acknowledge the model '
                    'license and that the one-time download will use your network connection.',
                    style: theme.textTheme.bodyLarge?.copyWith(color: colors.textSecondary),
                  ),
                ),
              ),
              CheckboxListTile(
                key: LicenseScreen.checkboxKey,
                value: _accepted,
                onChanged: isChecking ? null : (value) => setState(() => _accepted = value ?? false),
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
                activeColor: colors.textPrimary,
                checkColor: colors.bg,
                title: Text(
                  'i acknowledge the model license',
                  style: theme.textTheme.bodyMedium,
                ),
              ),
              const SizedBox(height: AppSpacing.s12),
              PrimaryButton(
                key: LicenseScreen.continueKey,
                label: 'continue',
                loading: isChecking,
                onPressed: _accepted ? _continue : null,
              ),
              const SizedBox(height: AppSpacing.s8),
            ],
          ),
        ),
      ),
    );
  }
}
