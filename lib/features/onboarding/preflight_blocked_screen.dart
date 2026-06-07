import 'package:ai_assistant/app/theme/app_colors.dart';
import 'package:ai_assistant/app/theme/app_spacing.dart';
import 'package:ai_assistant/app/theme/app_text.dart';
import 'package:ai_assistant/domain/entities/device_capability.dart';
import 'package:flutter/material.dart';

/// Honest, reason-specific dead-end shown when preflight fails (FR-004/FR-006, Principle V): the
/// device cannot run the model, explained clearly, with NO download offered — no crash, no OOM.
/// US5 (T046/T047) hardens this with soft-warn messaging.
class PreflightBlockedScreen extends StatelessWidget {
  const PreflightBlockedScreen({super.key, required this.reason});

  final IneligibleReason reason;

  String get _headline => switch (reason) {
        IneligibleReason.insufficientMemory => 'not enough memory',
        IneligibleReason.unsupportedAbi => 'unsupported processor',
      };

  String get _detail => switch (reason) {
        IneligibleReason.insufficientMemory =>
          'gemma 4 e2b needs about 8 gb of ram to run on-device. this device reports less, so the '
              'model would run out of memory. the download will not start.',
        IneligibleReason.unsupportedAbi =>
          'the model requires a 64-bit arm processor (arm64-v8a). this device uses a different '
              'architecture, so the model cannot run here. the download will not start.',
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.extension<AppColors>()!;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.heroPadding),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                AppText.spec('device not supported'),
                style: theme.textTheme.labelSmall?.copyWith(color: colors.accent),
              ),
              const SizedBox(height: AppSpacing.s12),
              Text(_headline, style: theme.textTheme.titleLarge),
              const SizedBox(height: AppSpacing.s16),
              Text(
                _detail,
                style: theme.textTheme.bodyLarge?.copyWith(color: colors.textSecondary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
