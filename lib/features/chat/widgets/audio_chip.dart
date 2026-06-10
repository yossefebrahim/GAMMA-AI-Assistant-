import 'dart:io';

import 'package:ai_assistant/app/theme/app_colors.dart';
import 'package:ai_assistant/app/theme/app_spacing.dart';
import 'package:ai_assistant/app/theme/app_text.dart';
import 'package:ai_assistant/core/audio_constants.dart';
import 'package:flutter/material.dart';

/// The voice-clip chip (003 US1/US5; design-system: monochrome, `surfaceContainerHigh` fill,
/// hairline `outline` border, control radius 8 — red is RESERVED for live recording/stop, so
/// everything here is monochrome, including remove).
///
/// Two modes per spec Q2:
///  * [AudioChip.composer] — the pending preview: play/stop toggle + duration + ≥48dp remove ×.
///  * [AudioChip.history] — the static in-bubble chip: duration derived from the stored file
///    (`(bytes − 44) / 32000` s), no playback; a missing/corrupt file shows a quiet placeholder
///    (FR-023) rather than a crash.
class AudioChip extends StatelessWidget {
  const AudioChip.composer({
    super.key,
    required int this.durationMs,
    required this.isPlaying,
    required this.onTogglePlay,
    required this.onRemove,
  }) : path = null;

  const AudioChip.history({super.key, required String this.path})
      : durationMs = null,
        isPlaying = false,
        onTogglePlay = null,
        onRemove = null;

  static const Key playKey = Key('audio-chip-play');
  static const Key removeKey = Key('audio-chip-remove');
  static const Key durationKey = Key('audio-chip-duration');
  static const Key brokenKey = Key('audio-chip-broken');

  /// Composer mode: the pending clip's duration as reported by the recorder.
  final int? durationMs;

  /// History mode: the stored file the duration derives from.
  final String? path;

  final bool isPlaying;
  final VoidCallback? onTogglePlay;
  final VoidCallback? onRemove;

  bool get _isComposer => durationMs != null;

  @override
  Widget build(BuildContext context) {
    if (_isComposer) {
      return _chipRow(context, Duration(milliseconds: durationMs!));
    }
    // History mode: derive duration from the stored WAV's byte length, just-in-time. A missing
    // file degrades to the placeholder — history may outlive a file in degraded states.
    return FutureBuilder<int>(
      future: File(path!).length(),
      builder: (context, snapshot) {
        if (snapshot.hasError) return _brokenChip(context);
        if (!snapshot.hasData) return _chipRow(context, null);
        return _chipRow(context, AudioConstants.durationFromBytes(snapshot.data!));
      },
    );
  }

  Widget _chipRow(BuildContext context, Duration? duration) {
    final theme = Theme.of(context);
    final colors = theme.extension<AppColors>()!;
    final label = duration == null ? '–:––' : AudioConstants.formatDuration(duration);
    final chip = Container(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.s12, vertical: AppSpacing.s4),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(AppSpacing.radiusControl),
        border: Border.all(color: colors.outline, width: AppSpacing.hairline),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_isComposer)
            IconButton(
              key: AudioChip.playKey,
              tooltip: isPlaying ? 'stop playback' : 'play voice clip',
              onPressed: onTogglePlay,
              icon: Icon(
                isPlaying ? Icons.stop_rounded : Icons.play_arrow_rounded,
                color: colors.textPrimary,
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.s8),
              child: Icon(Icons.graphic_eq, color: colors.textSecondary, size: AppSpacing.s24),
            ),
          const SizedBox(width: AppSpacing.s4),
          Text(
            AppText.spec(label),
            key: AudioChip.durationKey,
            style: theme.textTheme.labelSmall?.copyWith(color: colors.textPrimary),
          ),
          const SizedBox(width: AppSpacing.s4),
        ],
      ),
    );

    final seconds = duration?.inSeconds;
    return Semantics(
      label: seconds == null ? 'voice clip' : 'voice clip, $seconds seconds',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          chip,
          if (_isComposer)
            IconButton(
              key: AudioChip.removeKey,
              tooltip: 'remove voice clip',
              onPressed: onRemove,
              icon: Icon(Icons.close, color: colors.textSecondary),
            ),
        ],
      ),
    );
  }

  /// Quiet monochrome placeholder for an unreadable stored clip (FR-023) — never a crash.
  Widget _brokenChip(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.extension<AppColors>()!;
    return Container(
      key: AudioChip.brokenKey,
      padding:
          const EdgeInsets.symmetric(horizontal: AppSpacing.s12, vertical: AppSpacing.s8),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(AppSpacing.radiusControl),
        border: Border.all(color: colors.outline, width: AppSpacing.hairline),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.volume_off_outlined, color: colors.textSecondary, size: AppSpacing.s24),
          const SizedBox(width: AppSpacing.s8),
          Text(
            'audio unavailable',
            style: theme.textTheme.bodyMedium?.copyWith(color: colors.textSecondary),
          ),
        ],
      ),
    );
  }
}
