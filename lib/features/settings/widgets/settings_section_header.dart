import 'package:ai_assistant/app/theme/app_colors.dart';
import 'package:ai_assistant/app/theme/app_spacing.dart';
import 'package:ai_assistant/app/theme/app_text.dart';
import 'package:flutter/material.dart';

/// The ONE shared settings section header (P09-3): a spec-styled, secondary-text label with the
/// section's standard padding. Used across the settings, memory, and web-research screens so the
/// padding + styling live in exactly one place.
class SettingsSectionHeader extends StatelessWidget {
  const SettingsSectionHeader({required this.label, super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.extension<AppColors>()!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.s16,
        AppSpacing.s16,
        AppSpacing.s16,
        AppSpacing.s8,
      ),
      child: Text(
        AppText.spec(label),
        style: theme.textTheme.labelSmall?.copyWith(
          color: colors.textSecondary,
        ),
      ),
    );
  }
}
