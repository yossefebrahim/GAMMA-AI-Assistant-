import 'package:ai_assistant/app/theme/app_colors.dart';
import 'package:ai_assistant/app/theme/app_spacing.dart';
import 'package:ai_assistant/features/chat/attachment_controller.dart';
import 'package:ai_assistant/features/chat/chat_controller.dart';
import 'package:ai_assistant/features/chat/chat_providers.dart';
import 'package:ai_assistant/features/chat/widgets/attachment_preview.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The input bar (design-system §8). Input affordances are gated by the active model's
/// capabilities as DATA (FR-005/FR-006, Principle III): the attach control appears only when the
/// model supports images. With an image-capable model, tapping it offers camera / photo library,
/// the pending image previews above the field, and send is enabled with an image OR text (FR-004).
/// The send action is monochrome; while a reply is generating it is replaced by the one prominent
/// red affordance: stop.
class Composer extends ConsumerStatefulWidget {
  const Composer({super.key});

  static const Key sendKey = Key('composer-send');
  static const Key stopKey = Key('composer-stop');
  static const Key fieldKey = Key('composer-field');
  static const Key attachKey = Key('composer-attach');
  static const Key cameraOptionKey = Key('composer-source-camera');
  static const Key libraryOptionKey = Key('composer-source-library');
  static const Key permissionExplainerKey = Key('composer-perm-explainer');
  static const Key permissionGrantKey = Key('composer-perm-grant');
  static const Key permissionSettingsKey = Key('composer-perm-settings');
  static const Key permissionDismissKey = Key('composer-perm-dismiss');
  static const Key attachmentMessageKey = Key('composer-attachment-message');

  @override
  ConsumerState<Composer> createState() => _ComposerState();
}

enum _PickSource { camera, library }

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
    final pending = ref.read(attachmentControllerProvider).pending;
    if (text.trim().isEmpty && pending == null) return; // image OR text required (FR-004)
    _controller.clear();
    // The chat controller persists the image and clears the pending attachment on success (T027).
    ref.read(chatControllerProvider.notifier).send(text, image: pending);
  }

  void _stop() => ref.read(chatControllerProvider.notifier).stop();

  /// Show the permission explainer (FR-009/FR-010) — never a silent failure. Offers "grant" (retry,
  /// only when the permission is still askable), "open settings" (for a permanently-denied
  /// permission), and "not now". Dismissing leaves text chat fully usable (FR-011).
  Future<void> _showPermissionExplainer(AttachmentPrompt prompt) async {
    final controller = ref.read(attachmentControllerProvider.notifier);
    final theme = Theme.of(context);
    final colors = theme.extension<AppColors>()!;
    final canAskAgain = prompt == AttachmentPrompt.permissionDenied;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: Composer.permissionExplainerKey,
        backgroundColor: colors.surface,
        title: Text('camera access needed', style: theme.textTheme.titleMedium),
        content: Text(
          'to take a photo, allow camera access. you can still type and attach from your photo '
          'library.',
          style: theme.textTheme.bodyMedium?.copyWith(color: colors.textSecondary),
        ),
        actions: [
          TextButton(
            key: Composer.permissionDismissKey,
            onPressed: () {
              Navigator.of(dialogContext).pop();
              controller.dismissPrompt();
            },
            child: Text('not now', style: TextStyle(color: colors.textSecondary)),
          ),
          if (canAskAgain)
            TextButton(
              key: Composer.permissionGrantKey,
              onPressed: () {
                Navigator.of(dialogContext).pop();
                controller.dismissPrompt();
                controller.pickFromCamera();
              },
              child: Text('grant', style: TextStyle(color: colors.textPrimary)),
            ),
          TextButton(
            key: Composer.permissionSettingsKey,
            onPressed: () {
              Navigator.of(dialogContext).pop();
              controller.dismissPrompt();
              controller.openSettings();
            },
            child: Text('open settings', style: TextStyle(color: colors.textPrimary)),
          ),
        ],
      ),
    );
  }

  Future<void> _openSourceChooser() async {
    final controller = ref.read(attachmentControllerProvider.notifier);
    final source = await showModalBottomSheet<_PickSource>(
      context: context,
      backgroundColor: Theme.of(context).extension<AppColors>()!.surface,
      builder: (context) => const _SourceSheet(),
    );
    switch (source) {
      case _PickSource.camera:
        await controller.pickFromCamera();
      case _PickSource.library:
        await controller.pickFromLibrary();
      case null:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.extension<AppColors>()!;
    final isGenerating = ref.watch(chatControllerProvider.select((s) => s.isGenerating));
    final capabilities = ref.watch(modelCapabilitiesProvider);
    final pending = ref.watch(attachmentControllerProvider.select((s) => s.pending));
    // A brief note (cleared-on-model-switch, FR-008) or a "pick another" error (FR-021).
    final attachmentMessage =
        ref.watch(attachmentControllerProvider.select((s) => s.error ?? s.note));
    final canSend = _hasText || pending != null;

    // Route a missing camera permission to the explainer — never a silent no-op (FR-009/FR-010).
    ref.listen(
      attachmentControllerProvider.select((s) => s.permissionPrompt),
      (previous, next) {
        if (next != AttachmentPrompt.none) {
          _showPermissionExplainer(next);
        }
      },
    );

    return Container(
      decoration: BoxDecoration(
        color: colors.surfaceContainer,
        borderRadius: BorderRadius.circular(AppSpacing.radiusCard),
        border: Border.all(color: colors.outline),
      ),
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s8, vertical: AppSpacing.s4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (attachmentMessage != null)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.s8, left: AppSpacing.s8),
              child: Text(
                attachmentMessage,
                key: Composer.attachmentMessageKey,
                style: theme.textTheme.labelSmall?.copyWith(color: colors.textSecondary),
              ),
            ),
          if (pending != null)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.s8, left: AppSpacing.s4),
              child: AttachmentPreview(
                path: pending.path,
                onRemove: () => ref.read(attachmentControllerProvider.notifier).remove(),
                onReplace: _openSourceChooser,
              ),
            ),
          Row(
            children: [
              // Capability-gated attach affordance (data-driven, never hardcoded — Principle III).
              if (capabilities.image)
                IconButton(
                  key: Composer.attachKey,
                  tooltip: 'attach image',
                  onPressed: _openSourceChooser,
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
                _SendButton(onPressed: canSend ? _send : null),
            ],
          ),
        ],
      ),
    );
  }
}

/// The camera / photo-library chooser (design-system: monochrome sheet, hairline separators).
class _SourceSheet extends StatelessWidget {
  const _SourceSheet();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.extension<AppColors>()!;
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            key: Composer.cameraOptionKey,
            leading: Icon(Icons.photo_camera_outlined, color: colors.textPrimary),
            title: Text('camera', style: theme.textTheme.bodyLarge),
            onTap: () => Navigator.of(context).pop(_PickSource.camera),
          ),
          Divider(height: AppSpacing.hairline, color: colors.outline),
          ListTile(
            key: Composer.libraryOptionKey,
            leading: Icon(Icons.photo_library_outlined, color: colors.textPrimary),
            title: Text('photo library', style: theme.textTheme.bodyLarge),
            onTap: () => Navigator.of(context).pop(_PickSource.library),
          ),
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
