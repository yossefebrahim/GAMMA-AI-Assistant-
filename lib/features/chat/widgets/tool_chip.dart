import 'package:ai_assistant/app/theme/app_colors.dart';
import 'package:ai_assistant/app/theme/app_spacing.dart';
import 'package:ai_assistant/app/theme/app_text.dart';
import 'package:ai_assistant/app/widgets/dot_pulse.dart';
import 'package:ai_assistant/domain/entities/message.dart';
import 'package:ai_assistant/domain/entities/tool_outcome.dart';
import 'package:flutter/material.dart';

/// The function-call chip (design-system §8; 004 data-model §5). MONOCHROME: a mono uppercase
/// `TOOL · GET_DEVICE_INFO` tag, an optional args summary, and a quiet result line — never a
/// colored banner. Red is the sanctioned accent for the ERROR state ONLY (Principle VI/X).
/// Non-interactive in v1 (no tap target, so no 48dp floor applies); carries a [Semantics] label so
/// a screen reader announces the tool, its status, and its summary.
///
/// Rendered for any `role == tool` row regardless of the active model's capabilities (FR-010 — a
/// persisted chip outlives the capability that produced it).
class ToolChip extends StatelessWidget {
  const ToolChip({super.key, required this.message});

  final Message message;

  static const Key tagKey = Key('tool-chip-tag');
  static const Key argsKey = Key('tool-chip-args');
  static const Key contentKey = Key('tool-chip-content');
  static const Key runningKey = Key('tool-chip-running');

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.extension<AppColors>()!;
    final status = message.toolStatus ?? ToolCallStatus.running;
    final isError = status == ToolCallStatus.error;
    final isRunning = status == ToolCallStatus.running;

    final name = message.toolName ?? 'tool';
    final argsSummary = _argsSummary(message.toolArgs);
    // The result/status line: the persisted summary, or a spec word for transient/empty states.
    final line = switch (status) {
      ToolCallStatus.running => null,
      ToolCallStatus.skipped =>
        message.content.isNotEmpty ? message.content : 'skipped',
      _ => message.content,
    };

    final chip = Container(
      constraints: BoxConstraints(
        maxWidth: MediaQuery.sizeOf(context).width * 0.82,
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s12,
        vertical: AppSpacing.s8,
      ),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(AppSpacing.radiusControl),
        // The error state is the one sanctioned red use — a hairline accent border, not a fill.
        border: Border.all(
          color: isError ? colors.accent : colors.outline,
          width: AppSpacing.hairline,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isError) ...[
                Icon(
                  Icons.error_outline,
                  size: AppSpacing.s16,
                  color: colors.accent,
                ),
                const SizedBox(width: AppSpacing.s4),
              ],
              Flexible(
                child: Text(
                  AppText.spec('tool · $name'),
                  key: ToolChip.tagKey,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: isError ? colors.accent : colors.textSecondary,
                  ),
                ),
              ),
            ],
          ),
          if (argsSummary != null) ...[
            const SizedBox(height: AppSpacing.s4),
            Text(
              AppText.spec(argsSummary),
              key: ToolChip.argsKey,
              style: theme.textTheme.labelSmall?.copyWith(
                color: colors.textSecondary,
              ),
            ),
          ],
          if (isRunning) ...[
            const SizedBox(height: AppSpacing.s4),
            Padding(
              key: ToolChip.runningKey,
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.s4),
              child: DotPulse(color: colors.textSecondary),
            ),
          ] else if (line != null && line.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.s4),
            Text(
              line,
              key: ToolChip.contentKey,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colors.textSecondary,
              ),
            ),
          ],
        ],
      ),
    );

    return Semantics(
      label: _semanticsLabel(name, status, line),
      container: true,
      // Present ONE crafted label to the screen reader instead of the raw uppercase tag + lines.
      child: ExcludeSemantics(
        child: Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.s4),
            child: chip,
          ),
        ),
      ),
    );
  }

  /// Compact mono args summary (`section: battery`), or null when there are no args.
  String? _argsSummary(Map<String, Object?>? args) {
    if (args == null || args.isEmpty) return null;
    return args.entries.map((e) => '${e.key}: ${e.value}').join(' · ');
  }

  String _semanticsLabel(String name, ToolCallStatus status, String? line) {
    final statusWord = switch (status) {
      ToolCallStatus.running => 'running',
      ToolCallStatus.success => 'success',
      ToolCallStatus.error => 'error',
      ToolCallStatus.skipped => 'skipped',
    };
    final detail = (line != null && line.isNotEmpty) ? ' — $line' : '';
    return 'tool $name: $statusWord$detail';
  }
}
