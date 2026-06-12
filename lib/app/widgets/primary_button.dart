import 'package:ai_assistant/app/theme/app_colors.dart';
import 'package:ai_assistant/app/theme/app_spacing.dart';
import 'package:ai_assistant/app/theme/app_text.dart';
import 'package:ai_assistant/app/widgets/dot_pulse.dart';
import 'package:flutter/material.dart';

/// The monochrome primary action (design-system §2: primary buttons are NOT red — the accent is
/// reserved for active/destructive states). White-on-black in dark, black-on-white in light, a
/// full-width 48dp target (accessibility floor). Shows a dot-matrix pulse while [loading].
class PrimaryButton extends StatelessWidget {
  const PrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.loading = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<AppColors>()!;
    return SizedBox(
      width: double.infinity,
      height: AppSpacing.minTouchTarget,
      child: FilledButton(
        onPressed: loading ? null : onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: colors.textPrimary,
          foregroundColor: colors.bg,
          disabledBackgroundColor: colors.surfaceContainerHigh,
          disabledForegroundColor: colors.textMuted,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppSpacing.radiusControl),
          ),
          textStyle: AppText.titleM,
        ),
        child: loading ? DotPulse(color: colors.bg, dotSize: 5) : Text(label),
      ),
    );
  }
}
