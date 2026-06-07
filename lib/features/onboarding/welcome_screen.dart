import 'package:ai_assistant/app/router.dart';
import 'package:ai_assistant/app/theme/app_colors.dart';
import 'package:ai_assistant/app/theme/app_spacing.dart';
import 'package:ai_assistant/app/theme/app_text.dart';
import 'package:ai_assistant/app/widgets/primary_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// First-run welcome (FR-001/FR-023, SC-010): a dark screen, shown first, that explains the
/// on-device privacy guarantee before anything else. Dot-matrix wordmark, lowercase voice, a
/// single monochrome primary action.
class WelcomeScreen extends ConsumerWidget {
  const WelcomeScreen({super.key});

  static const Key explainerKey = Key('welcome-privacy-explainer');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colors = theme.extension<AppColors>()!;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.heroPadding),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Spacer(),
              Text(
                'gemma',
                style: AppText.dotMatrix(fontSize: 56, color: colors.textPrimary),
              ),
              const SizedBox(height: AppSpacing.s12),
              Text('everything runs on your device.', style: theme.textTheme.titleMedium),
              const SizedBox(height: AppSpacing.s24),
              Text(
                key: explainerKey,
                'your conversations never leave this phone. the model runs fully on-device — no '
                'servers, no accounts, no telemetry. the only time the app uses the network is the '
                'one-time model download.',
                style: theme.textTheme.bodyLarge?.copyWith(color: colors.textSecondary),
              ),
              const SizedBox(height: AppSpacing.s24),
              Text(AppText.spec('private · offline · on-device'), style: theme.textTheme.labelSmall),
              const Spacer(flex: 2),
              PrimaryButton(
                label: 'get started',
                onPressed: () => Navigator.of(context).pushNamed(AppRoutes.license),
              ),
              const SizedBox(height: AppSpacing.s8),
            ],
          ),
        ),
      ),
    );
  }
}
