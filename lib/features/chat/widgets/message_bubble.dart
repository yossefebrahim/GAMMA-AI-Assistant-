import 'dart:io';

import 'package:ai_assistant/app/theme/app_colors.dart';
import 'package:ai_assistant/app/theme/app_spacing.dart';
import 'package:ai_assistant/app/theme/app_text.dart';
import 'package:ai_assistant/app/widgets/dot_pulse.dart';
import 'package:ai_assistant/domain/entities/message.dart';
import 'package:ai_assistant/features/chat/widgets/audio_chip.dart';
import 'package:flutter/material.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

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
      // sizeOf (NOT MediaQuery.of): subscribing to all MediaQuery aspects rebuilt every visible
      // bubble on every frame of the keyboard inset animation. Size doesn't change with insets.
      constraints: BoxConstraints(
        maxWidth: MediaQuery.sizeOf(context).width * 0.82,
      ),
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
          // The attached image renders in place above any text (FR-012). Persisted history is
          // shown regardless of the active model's current capabilities (FR-017) — this reads from
          // the stored file, not from `capabilities`.
          if (message.image != null) ...[
            _BubbleImage(path: message.image!.path),
            if (message.content.isNotEmpty)
              const SizedBox(height: AppSpacing.s8),
          ],
          // The attached voice clip renders as a static chip — duration label, no playback this
          // slice (003 spec Q2/FR-018) — again independent of current capabilities.
          if (message.audio != null) ...[
            AudioChip.history(path: message.audio!.path),
            if (message.content.isNotEmpty)
              const SizedBox(height: AppSpacing.s8),
          ],
          if (isStreaming && message.content.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.s4),
              child: DotPulse(color: colors.accent),
            )
          else if (message.content.isNotEmpty ||
              (message.image == null && message.audio == null))
            // Assistant turns render markdown (styled via the GptMarkdownThemeData tokens in
            // AppTheme); user turns stay literal — what was typed is what history shows.
            if (isUser)
              Text(
                message.content,
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: colors.textPrimary,
                ),
              )
            else
              GptMarkdown(
                message.content,
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: colors.textPrimary,
                ),
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

/// The in-bubble image (R6): rounded, hairline border, contained, height-capped, with a screen-
/// reader label (Principle VI). A missing file shows a quiet monochrome placeholder rather than a
/// crash (FR-012 — history may outlive a file in degraded states).
class _BubbleImage extends StatelessWidget {
  const _BubbleImage({required this.path});

  final String path;

  static const double _maxHeight = 240;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<AppColors>()!;
    return Semantics(
      label: 'attached image',
      image: true,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppSpacing.radiusControl),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppSpacing.radiusControl),
            border: Border.all(
              color: colors.outline,
              width: AppSpacing.hairline,
            ),
          ),
          constraints: const BoxConstraints(maxHeight: _maxHeight),
          child: Image.file(
            File(path),
            fit: BoxFit.contain,
            // Decode at the displayed height, not the stored resolution: a full 1536px decode is
            // a ~12 MB texture for a ≤240dp slot, felt as jank on every list/keyboard relayout.
            cacheHeight: (_maxHeight * MediaQuery.devicePixelRatioOf(context))
                .round(),
            errorBuilder: (context, error, stack) => Padding(
              padding: const EdgeInsets.all(AppSpacing.s24),
              child: Icon(
                Icons.broken_image_outlined,
                color: colors.textSecondary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
