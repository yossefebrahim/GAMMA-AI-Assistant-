import 'package:ai_assistant/app/theme/app_colors.dart';
import 'package:ai_assistant/app/theme/app_spacing.dart';
import 'package:ai_assistant/features/chat/attachment_controller.dart';
import 'package:ai_assistant/features/chat/chat_controller.dart';
import 'package:ai_assistant/features/chat/chat_providers.dart';
import 'package:ai_assistant/features/chat/recording_controller.dart';
import 'package:ai_assistant/features/chat/widgets/attachment_preview.dart';
import 'package:ai_assistant/features/chat/widgets/audio_chip.dart';
import 'package:ai_assistant/features/chat/widgets/recording_indicator.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The input bar (design-system §8). Input affordances are gated by the active model's
/// capabilities as DATA (FR-005/FR-006, Principle III): the attach control appears only when the
/// model supports images, the mic only when it supports audio (003 US2). With an image-capable
/// model, tapping attach offers camera / photo library and the pending image previews above the
/// field; with an audio-capable model, the mic records one voice clip (tap to record — red
/// pulsing state with elapsed time — tap to stop, 003 US1) and the pending clip previews as a
/// removable chip with playback. Send is enabled with text OR an attachment (FR-004; audio XOR
/// image, spec Q3). The send action is monochrome; red is reserved for the live recording state,
/// its stop control, and stop-generation (Principle X).
class Composer extends ConsumerStatefulWidget {
  const Composer({super.key});

  static const Key sendKey = Key('composer-send');
  static const Key stopKey = Key('composer-stop');
  static const Key fieldKey = Key('composer-field');
  static const Key attachKey = Key('composer-attach');
  static const Key micKey = Key('composer-mic');
  static const Key recordStopKey = Key('composer-record-stop');
  static const Key cameraOptionKey = Key('composer-source-camera');
  static const Key libraryOptionKey = Key('composer-source-library');
  static const Key permissionExplainerKey = Key('composer-perm-explainer');
  static const Key permissionGrantKey = Key('composer-perm-grant');
  static const Key permissionSettingsKey = Key('composer-perm-settings');
  static const Key permissionDismissKey = Key('composer-perm-dismiss');
  static const Key micPermissionExplainerKey = Key(
    'composer-mic-perm-explainer',
  );
  static const Key micPermissionGrantKey = Key('composer-mic-perm-grant');
  static const Key micPermissionSettingsKey = Key('composer-mic-perm-settings');
  static const Key micPermissionDismissKey = Key('composer-mic-perm-dismiss');
  static const Key attachmentMessageKey = Key('composer-attachment-message');
  static const Key recordingMessageKey = Key('composer-recording-message');

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
    final pendingImage = ref.read(attachmentControllerProvider).pending;
    final pendingClip = ref.read(recordingControllerProvider).clip;
    if (text.trim().isEmpty && pendingImage == null && pendingClip == null) {
      return; // attachment OR text required (FR-004)
    }
    _controller.clear();
    // The chat controller persists the attachment and clears the pending state on success (T027).
    ref
        .read(chatControllerProvider.notifier)
        .send(text, image: pendingImage, audio: pendingClip);
  }

  void _stop() => ref.read(chatControllerProvider.notifier).stop();

  /// Show the camera permission explainer (FR-009/FR-010) — never a silent failure. Offers
  /// "grant" (retry, only when the permission is still askable), "open settings" (for a
  /// permanently-denied permission), and "not now". Dismissing leaves text chat fully usable
  /// (FR-011).
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
          style: theme.textTheme.bodyMedium?.copyWith(
            color: colors.textSecondary,
          ),
        ),
        actions: [
          TextButton(
            key: Composer.permissionDismissKey,
            onPressed: () {
              Navigator.of(dialogContext).pop();
              controller.dismissPrompt();
            },
            child: Text(
              'not now',
              style: TextStyle(color: colors.textSecondary),
            ),
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
            child: Text(
              'open settings',
              style: TextStyle(color: colors.textPrimary),
            ),
          ),
        ],
      ),
    );
  }

  /// Show the mic permission explainer (003 US4, FR-011/FR-012) — the camera explainer's mic
  /// edition, same decision tree (contracts/media_permission.md #3): "grant" re-requests only
  /// while askable; "open settings" appears for a permanently-denied permission; a restricted
  /// (managed-device) permission explains with no grant path. Dismissing always returns to a
  /// fully usable composer.
  Future<void> _showMicPermissionExplainer(MicPermissionPrompt prompt) async {
    final controller = ref.read(recordingControllerProvider.notifier);
    final theme = Theme.of(context);
    final colors = theme.extension<AppColors>()!;
    final canAskAgain = prompt == MicPermissionPrompt.denied;
    final restricted = prompt == MicPermissionPrompt.restricted;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: Composer.micPermissionExplainerKey,
        backgroundColor: colors.surface,
        title: Text(
          'microphone access needed',
          style: theme.textTheme.titleMedium,
        ),
        content: Text(
          restricted
              ? 'microphone access is restricted on this device, so voice clips are unavailable. '
                    'you can still type.'
              : 'to record a voice clip, allow microphone access. you can still type.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: colors.textSecondary,
          ),
        ),
        actions: [
          TextButton(
            key: Composer.micPermissionDismissKey,
            onPressed: () {
              Navigator.of(dialogContext).pop();
              controller.dismissPrompt();
            },
            child: Text(
              'not now',
              style: TextStyle(color: colors.textSecondary),
            ),
          ),
          if (canAskAgain)
            TextButton(
              key: Composer.micPermissionGrantKey,
              onPressed: () {
                Navigator.of(dialogContext).pop();
                controller.dismissPrompt();
                controller.onMicTap();
              },
              child: Text('grant', style: TextStyle(color: colors.textPrimary)),
            ),
          if (prompt == MicPermissionPrompt.permanentlyDenied)
            TextButton(
              key: Composer.micPermissionSettingsKey,
              onPressed: () {
                Navigator.of(dialogContext).pop();
                controller.dismissPrompt();
                controller.openSettings();
              },
              child: Text(
                'open settings',
                style: TextStyle(color: colors.textPrimary),
              ),
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
    final isGenerating = ref.watch(
      chatControllerProvider.select((s) => s.isGenerating),
    );
    final capabilities = ref.watch(modelCapabilitiesProvider);
    final pending = ref.watch(
      attachmentControllerProvider.select((s) => s.pending),
    );
    final recording = ref.watch(recordingControllerProvider);
    // A brief note (cleared-on-model-switch, FR-008) or a "pick another" error (FR-021).
    final attachmentMessage = ref.watch(
      attachmentControllerProvider.select((s) => s.error ?? s.note),
    );
    // The recording flow's note ("too short", "limit reached", …) or inline error (003 US1/US6).
    final recordingMessage = recording.error ?? recording.note;
    final canSend = _hasText || pending != null || recording.hasClip;

    // Route a missing camera permission to the explainer — never a silent no-op (FR-009/FR-010).
    ref.listen(attachmentControllerProvider.select((s) => s.permissionPrompt), (
      previous,
      next,
    ) {
      if (next != AttachmentPrompt.none) {
        _showPermissionExplainer(next);
      }
    });
    // Same rule for the mic (003 US4).
    ref.listen(recordingControllerProvider.select((s) => s.permissionPrompt), (
      previous,
      next,
    ) {
      if (next != MicPermissionPrompt.none) {
        _showMicPermissionExplainer(next);
      }
    });
    // Recording start/stop is announced to screen readers (003 FR-028, Principle VI).
    ref.listen(recordingControllerProvider.select((s) => s.phase), (
      previous,
      next,
    ) {
      final view = View.of(context);
      if (next == RecordingPhase.recording) {
        SemanticsService.sendAnnouncement(
          view,
          'recording started',
          TextDirection.ltr,
        );
      } else if (previous == RecordingPhase.recording) {
        SemanticsService.sendAnnouncement(
          view,
          'recording stopped',
          TextDirection.ltr,
        );
      }
    });

    return Container(
      decoration: BoxDecoration(
        color: colors.surfaceContainer,
        borderRadius: BorderRadius.circular(AppSpacing.radiusCard),
        border: Border.all(color: colors.outline),
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s8,
        vertical: AppSpacing.s4,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (attachmentMessage != null)
            Padding(
              padding: const EdgeInsets.only(
                top: AppSpacing.s8,
                left: AppSpacing.s8,
              ),
              child: Text(
                attachmentMessage,
                key: Composer.attachmentMessageKey,
                // Essential lowercase guidance reads as body, not the uppercase Space Mono spec face
                // (design-system §3); matches the chat error banner's bodyMedium.
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colors.textSecondary,
                ),
              ),
            ),
          if (recordingMessage != null)
            Padding(
              padding: const EdgeInsets.only(
                top: AppSpacing.s8,
                left: AppSpacing.s8,
              ),
              child: Text(
                recordingMessage,
                key: Composer.recordingMessageKey,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colors.textSecondary,
                ),
              ),
            ),
          if (pending != null)
            Padding(
              padding: const EdgeInsets.only(
                top: AppSpacing.s8,
                left: AppSpacing.s4,
              ),
              child: AttachmentPreview(
                path: pending.path,
                onRemove: () =>
                    ref.read(attachmentControllerProvider.notifier).remove(),
                onReplace: _openSourceChooser,
              ),
            ),
          if (recording.hasClip)
            Padding(
              padding: const EdgeInsets.only(
                top: AppSpacing.s8,
                left: AppSpacing.s4,
              ),
              child: AudioChip.composer(
                durationMs: recording.clip!.durationMs,
                isPlaying: recording.isPreviewPlaying,
                onTogglePlay: () {
                  final controller = ref.read(
                    recordingControllerProvider.notifier,
                  );
                  recording.isPreviewPlaying
                      ? controller.stopPreview()
                      : controller.playPreview();
                },
                onRemove: () =>
                    ref.read(recordingControllerProvider.notifier).removeClip(),
              ),
            ),
          if (recording.isRecording)
            // The live recording state (003 US1): red pulsing level + mono elapsed readout, and
            // the one red stop control (≥48dp) — the design system's reserved use of the accent.
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.s8,
                vertical: AppSpacing.s4,
              ),
              child: Row(
                children: [
                  RecordingIndicator(
                    elapsed: recording.elapsed,
                    amplitude: ref.read(audioRecorderServiceProvider).amplitude,
                  ),
                  const Spacer(),
                  _RecordStopButton(
                    onPressed: () => ref
                        .read(recordingControllerProvider.notifier)
                        .stopRecording(),
                  ),
                ],
              ),
            )
          else
            Row(
              children: [
                // Capability-gated attach affordance (data-driven, never hardcoded — Principle III).
                if (capabilities.image)
                  IconButton(
                    key: Composer.attachKey,
                    tooltip: 'attach image',
                    onPressed: _openSourceChooser,
                    icon: Icon(
                      Icons.add_photo_alternate_outlined,
                      color: colors.textSecondary,
                    ),
                  ),
                // Capability-gated mic (003 US1/US2) — rendered from `capabilities.audio` as DATA.
                if (capabilities.audio)
                  IconButton(
                    key: Composer.micKey,
                    tooltip: 'record voice clip',
                    onPressed: () => ref
                        .read(recordingControllerProvider.notifier)
                        .onMicTap(),
                    icon: Icon(
                      Icons.mic_none_outlined,
                      color: colors.textSecondary,
                    ),
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
                      hintStyle: theme.textTheme.bodyLarge?.copyWith(
                        color: colors.textMuted,
                      ),
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
            leading: Icon(
              Icons.photo_camera_outlined,
              color: colors.textPrimary,
            ),
            title: Text('camera', style: theme.textTheme.bodyLarge),
            onTap: () => Navigator.of(context).pop(_PickSource.camera),
          ),
          Divider(height: AppSpacing.hairline, color: colors.outline),
          ListTile(
            key: Composer.libraryOptionKey,
            leading: Icon(
              Icons.photo_library_outlined,
              color: colors.textPrimary,
            ),
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

/// Stop-recording — red is sanctioned here (live recording + stop states, Principle X); ≥48dp
/// touch target (Principle VI / FR-029) with an explicit screen-reader label.
class _RecordStopButton extends StatelessWidget {
  const _RecordStopButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<AppColors>()!;
    return IconButton(
      key: Composer.recordStopKey,
      tooltip: 'stop recording',
      onPressed: onPressed,
      style: IconButton.styleFrom(
        backgroundColor: colors.accent,
        foregroundColor: colors.onAccent,
        minimumSize: const Size(
          AppSpacing.minTouchTarget,
          AppSpacing.minTouchTarget,
        ),
      ),
      icon: const Icon(Icons.stop_rounded),
    );
  }
}
