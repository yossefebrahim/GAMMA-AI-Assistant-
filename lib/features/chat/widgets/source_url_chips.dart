import 'package:ai_assistant/app/theme/app_colors.dart';
import 'package:ai_assistant/app/theme/app_spacing.dart';
import 'package:ai_assistant/features/chat/tool_handler_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The tappable source-URL chips rendered beneath a web tool reply (006 T033, FR-013, SC-007).
///
/// One chip per grounding URL (the `sourceUrls` array persisted on the web tool row, data-model §3).
/// Tapping a chip opens the URL in the device browser via the [webUrlLauncherProvider] seam (so the
/// tap is testable with a fake — no real Android intent in widget tests). Chips render from the
/// persisted tool row, so they survive an app restart and appear regardless of the current web
/// toggle state (FR-025, SC-008), identically to the 004/005 tool chips.
///
/// Each chip's label is the URL host (`Uri.parse(url).host`) — compact, scannable, and naming the
/// real destination — falling back to the raw URL when the host is empty.
class SourceUrlChips extends ConsumerWidget {
  const SourceUrlChips({super.key, required this.urls});

  /// The grounding URLs from the web tool result's `sourceUrls` array.
  final List<String> urls;

  static const Key chipKey = Key('source-url-chip');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (urls.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final colors = theme.extension<AppColors>()!;

    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.s4),
        child: Wrap(
          spacing: AppSpacing.s8,
          runSpacing: AppSpacing.s8,
          children: [
            for (final url in urls)
              _SourceChip(
                url: url,
                onTap: () => ref.read(webUrlLauncherProvider).open(url),
                colors: colors,
                textStyle: theme.textTheme.labelSmall?.copyWith(
                  color: colors.textSecondary,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _SourceChip extends StatelessWidget {
  const _SourceChip({
    required this.url,
    required this.onTap,
    required this.colors,
    required this.textStyle,
  });

  final String url;
  final VoidCallback onTap;
  final AppColors colors;
  final TextStyle? textStyle;

  @override
  Widget build(BuildContext context) {
    final host = Uri.tryParse(url)?.host ?? '';
    final label = host.isEmpty ? url : host;
    return Semantics(
      button: true,
      label: 'open source $label',
      child: InkWell(
        key: SourceUrlChips.chipKey,
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppSpacing.radiusControl),
        // ≥48dp tap target (SC-013) via the constrained padded surface.
        child: Container(
          constraints: const BoxConstraints(minHeight: 48),
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.s12,
            vertical: AppSpacing.s8,
          ),
          decoration: BoxDecoration(
            color: colors.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(AppSpacing.radiusControl),
            border: Border.all(
              color: colors.outline,
              width: AppSpacing.hairline,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.open_in_new,
                size: AppSpacing.s16,
                color: colors.textSecondary,
              ),
              const SizedBox(width: AppSpacing.s4),
              Flexible(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: textStyle,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
