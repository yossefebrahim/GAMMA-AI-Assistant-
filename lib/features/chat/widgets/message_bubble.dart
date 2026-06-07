import 'package:ai_assistant/app/theme/app_colors.dart';
import 'package:ai_assistant/app/theme/app_spacing.dart';
import 'package:ai_assistant/app/theme/app_text.dart';
import 'package:ai_assistant/app/widgets/dot_pulse.dart';
import 'package:ai_assistant/domain/entities/message.dart';
import 'package:flutter/material.dart';

/// A single turn (design-system §8). Differentiation is by **alignment + subtle fill, never
/// color**: the user turn is right-aligned with a `surfaceContainerHigh` fill; the assistant turn
/// is left-aligned and borderless with no fill. A streaming assistant turn with no text yet shows
/// the dot-matrix pulse; a stopped-partial turn keeps its text with a quiet mono tag.
class MessageBubble extends StatelessWidget {
  const MessageBubble({super.key, required this.message});

  final Message message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.extension<AppColors>()!;
    final isUser = message.isUser;
    final isStreaming = message.status == MessageStatus.streaming;
    final isStoppedPartial = message.status == MessageStatus.stoppedPartial;

    final bubble = Container(
      constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.82),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s16,
        vertical: AppSpacing.s12,
      ),
      decoration: isUser
          ? BoxDecoration(
              color: colors.surfaceContainerHigh,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(AppSpacing.radiusCard),
                topRight: Radius.circular(AppSpacing.radiusCard),
                bottomLeft: Radius.circular(AppSpacing.radiusCard),
                bottomRight: Radius.circular(AppSpacing.s4),
              ),
            )
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (isStreaming && message.content.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.s4),
              child: DotPulse(color: colors.accent),
            )
          else
            Text(
              message.content,
              style: theme.textTheme.bodyLarge?.copyWith(color: colors.textPrimary),
            ),
          if (isStoppedPartial) ...[
            const SizedBox(height: AppSpacing.s8),
            Text(AppText.spec('stopped'), style: theme.textTheme.labelSmall),
          ],
        ],
      ),
    );

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.s4),
        child: bubble,
      ),
    );
  }
}
