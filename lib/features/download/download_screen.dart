import 'package:ai_assistant/app/router.dart';
import 'package:ai_assistant/app/theme/app_colors.dart';
import 'package:ai_assistant/app/theme/app_spacing.dart';
import 'package:ai_assistant/app/theme/app_text.dart';
import 'package:ai_assistant/app/widgets/primary_button.dart';
import 'package:ai_assistant/core/model_catalog.dart';
import 'package:ai_assistant/features/download/download_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The one-time model download (FR-007–FR-010): a big dot-matrix `%`, a thin determinate bar, a
/// mono spec/bytes readout, and a monochrome cancel. Routes into chat on completion; offers retry
/// on failure. The download runs in the background (foreground service), so leaving this screen
/// does not stop it.
class DownloadScreen extends ConsumerStatefulWidget {
  const DownloadScreen({super.key});

  @override
  ConsumerState<DownloadScreen> createState() => _DownloadScreenState();
}

class _DownloadScreenState extends ConsumerState<DownloadScreen> {
  @override
  void initState() {
    super.initState();
    // Kick off the download once this screen mounts.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(downloadControllerProvider.notifier).start();
    });
  }

  String _formatBytes(int bytes) {
    if (bytes <= 0) return '0B';
    const units = ['B', 'KB', 'MB', 'GB'];
    var size = bytes.toDouble();
    var unit = 0;
    while (size >= 1024 && unit < units.length - 1) {
      size /= 1024;
      unit++;
    }
    final decimals = (size >= 10 || unit == 0) ? 0 : 1;
    return '${size.toStringAsFixed(decimals)}${units[unit]}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.extension<AppColors>()!;
    final state = ref.watch(downloadControllerProvider);
    // Soft-warn flag passed from the preflight gate: eligible but below the recommended 8 GB (R4).
    final softWarn = (ModalRoute.of(context)?.settings.arguments as bool?) ?? false;

    // Route into chat once the model is installed.
    ref.listen(downloadControllerProvider, (previous, next) {
      if (next.isComplete && mounted) {
        Navigator.of(context).pushReplacementNamed(AppRoutes.chat);
      }
    });

    final bytesLine = state.totalBytes != null
        ? '${_formatBytes(state.downloadedBytes)} / ${_formatBytes(state.totalBytes!)}'
        : _formatBytes(state.downloadedBytes);

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.heroPadding),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Spacer(),
              Text('model ( ${ModelCatalog.displayName} )', style: theme.textTheme.titleMedium),
              const SizedBox(height: AppSpacing.s24),
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(
                    '${state.percent}',
                    style: AppText.dotMatrix(fontSize: 72, color: colors.textPrimary),
                  ),
                  Text('%', style: AppText.dotMatrix(fontSize: 32, color: colors.textSecondary)),
                ],
              ),
              const SizedBox(height: AppSpacing.s16),
              _ProgressBar(fraction: state.fraction),
              const SizedBox(height: AppSpacing.s12),
              Text(
                AppText.spec(
                  state.stalled ? '$bytesLine · stalled…' : '$bytesLine · ${ModelCatalog.specLine}',
                ),
                style: theme.textTheme.labelSmall,
              ),
              if (softWarn) ...[
                const SizedBox(height: AppSpacing.s12),
                Text(
                  'this device is below the recommended 8 gb of memory — the model will run, '
                  'but may be slow.',
                  style: theme.textTheme.bodyMedium?.copyWith(color: colors.textSecondary),
                ),
              ],
              const Spacer(flex: 2),
              if (state.isFailed) ...[
                Text(
                  state.error ?? 'download failed',
                  style: theme.textTheme.bodyMedium?.copyWith(color: colors.accent),
                ),
                const SizedBox(height: AppSpacing.s12),
                PrimaryButton(
                  label: 'retry',
                  onPressed: () => ref.read(downloadControllerProvider.notifier).retry(),
                ),
              ] else
                // Monochrome cancel (download cancel is NOT destructive-red; design-system §8).
                SizedBox(
                  height: AppSpacing.minTouchTarget,
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: () => ref.read(downloadControllerProvider.notifier).cancel(),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: colors.textPrimary,
                      side: BorderSide(color: colors.outline),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(AppSpacing.radiusControl),
                      ),
                    ),
                    child: const Text('cancel'),
                  ),
                ),
              const SizedBox(height: AppSpacing.s8),
            ],
          ),
        ),
      ),
    );
  }
}

/// A thin determinate bar — white fill on a hairline `outline` track (design-system §7), no
/// Material progress indicator (which would tint with the red accent).
class _ProgressBar extends StatelessWidget {
  const _ProgressBar({required this.fraction});

  final double fraction;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<AppColors>()!;
    return ClipRRect(
      borderRadius: BorderRadius.circular(2),
      child: Container(
        height: 4,
        color: colors.outline,
        child: FractionallySizedBox(
          alignment: Alignment.centerLeft,
          widthFactor: fraction.clamp(0.0, 1.0),
          child: Container(color: colors.textPrimary),
        ),
      ),
    );
  }
}
