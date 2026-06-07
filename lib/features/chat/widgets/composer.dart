import 'package:ai_assistant/app/theme/app_colors.dart';
import 'package:ai_assistant/app/theme/app_spacing.dart';
import 'package:ai_assistant/features/chat/chat_controller.dart';
import 'package:ai_assistant/features/chat/chat_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The input bar (design-system §8). Input affordances are gated by the active model's
/// capabilities as DATA (FR-016, Principle III): attach/mic appear only if the model supports
/// image/audio — text-only this slice, so neither renders. The send action is monochrome; while a
/// reply is generating it is replaced by the one prominent red affordance: stop.
class Composer extends ConsumerStatefulWidget {
  const Composer({super.key});

  static const Key sendKey = Key('composer-send');
  static const Key stopKey = Key('composer-stop');
  static const Key fieldKey = Key('composer-field');

  @override
  ConsumerState<Composer> createState() => _ComposerState();
}

class _ComposerState extends ConsumerState<Composer> {
  final TextEditingController _controller = TextEditingController();
  bool _hasText = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(() {
      final hasText = _controller.text.trim().isNotEmpty;
      if (hasText != _hasText) setState(() => _hasText = hasText);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _send() {
    final text = _controller.text;
    if (text.trim().isEmpty) return;
    _controller.clear();
    ref.read(chatControllerProvider.notifier).send(text);
  }

  void _stop() => ref.read(chatControllerProvider.notifier).stop();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.extension<AppColors>()!;
    final isGenerating = ref.watch(chatControllerProvider.select((s) => s.isGenerating));
    final capabilities = ref.watch(modelCapabilitiesProvider);

    return Container(
      decoration: BoxDecoration(
        color: colors.surfaceContainer,
        borderRadius: BorderRadius.circular(AppSpacing.radiusCard),
        border: Border.all(color: colors.outline),
      ),
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s8, vertical: AppSpacing.s4),
      child: Row(
        children: [
          // Capability-gated leading affordances (data-driven, never hardcoded — Principle III).
          if (capabilities.image)
            IconButton(
              onPressed: () {},
              icon: Icon(Icons.add_photo_alternate_outlined, color: colors.textSecondary),
            ),
          if (capabilities.audio)
            IconButton(
              onPressed: () {},
              icon: Icon(Icons.mic_none_outlined, color: colors.textSecondary),
            ),
          Expanded(
            child: TextField(
              key: Composer.fieldKey,
              controller: _controller,
              minLines: 1,
              maxLines: 5,
              textInputAction: TextInputAction.newline,
              style: theme.textTheme.bodyLarge,
              cursorColor: colors.textPrimary,
              decoration: InputDecoration(
                border: InputBorder.none,
                hintText: 'message',
                hintStyle: theme.textTheme.bodyLarge?.copyWith(color: colors.textMuted),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.s8,
                  vertical: AppSpacing.s12,
                ),
              ),
            ),
          ),
          if (isGenerating)
            _StopButton(onPressed: _stop)
          else
            _SendButton(onPressed: _hasText ? _send : null),
        ],
      ),
    );
  }
}

/// Monochrome send (design-system: send is NOT red).
class _SendButton extends StatelessWidget {
  const _SendButton({required this.onPressed});

  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<AppColors>()!;
    return IconButton(
      key: Composer.sendKey,
      onPressed: onPressed,
      icon: Icon(
        Icons.arrow_upward_rounded,
        color: onPressed == null ? colors.textMuted : colors.textPrimary,
      ),
    );
  }
}

/// The single prominent red affordance — stop generation (design-system §8). Accent fill,
/// onAccent square-stop glyph, only visible while generating.
class _StopButton extends StatelessWidget {
  const _StopButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<AppColors>()!;
    return IconButton(
      key: Composer.stopKey,
      onPressed: onPressed,
      style: IconButton.styleFrom(
        backgroundColor: colors.accent,
        foregroundColor: colors.onAccent,
      ),
      icon: const Icon(Icons.stop_rounded),
    );
  }
}
