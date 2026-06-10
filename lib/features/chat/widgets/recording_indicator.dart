import 'package:ai_assistant/app/theme/app_colors.dart';
import 'package:ai_assistant/app/theme/app_spacing.dart';
import 'package:ai_assistant/app/theme/app_text.dart';
import 'package:ai_assistant/core/audio_constants.dart';
import 'package:flutter/material.dart';

/// The live recording state (003 US1, FR-028/FR-029; design-system §2/§7): a red-accent
/// dot-matrix pulse driven by the mic [amplitude] stream — the design system's sanctioned use of
/// red for the live recording state — plus a mono `m:ss` elapsed readout updating ≥1/s (SC-004).
/// The ≥48dp stop control lives next to it in the composer.
class RecordingIndicator extends StatelessWidget {
  const RecordingIndicator({super.key, required this.elapsed, required this.amplitude});

  static const Key elapsedKey = Key('recording-elapsed');

  /// Live recording time from the recording controller, ticking once a second.
  final Duration elapsed;

  /// Normalized mic level 0..1 (~10 Hz) from the recorder seam.
  final Stream<double> amplitude;

  static const int _dotCount = 6;
  static const double _dotSize = 6;
  static const double _dotSpacing = 5;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.extension<AppColors>()!;
    return Semantics(
      label: 'recording',
      liveRegion: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          StreamBuilder<double>(
            stream: amplitude,
            initialData: 0,
            builder: (context, snapshot) {
              final level = (snapshot.data ?? 0).clamp(0.0, 1.0);
              return Row(
                mainAxisSize: MainAxisSize.min,
                children: List<Widget>.generate(_dotCount, (index) {
                  // Dots light up left-to-right with the live level (Glyph-style meter, §7) —
                  // never below a faint floor so the row reads as a unit while quiet.
                  final threshold = (index + 1) / _dotCount;
                  final lit = level >= threshold - (1 / _dotCount) / 2;
                  return Padding(
                    padding: EdgeInsets.only(
                        right: index == _dotCount - 1 ? 0 : _dotSpacing),
                    child: Container(
                      width: _dotSize,
                      height: _dotSize,
                      decoration: BoxDecoration(
                        color: colors.accent.withValues(alpha: lit ? 1.0 : 0.25),
                        shape: BoxShape.circle,
                      ),
                    ),
                  );
                }),
              );
            },
          ),
          const SizedBox(width: AppSpacing.s12),
          Text(
            AppText.spec(AudioConstants.formatDuration(elapsed)),
            key: elapsedKey,
            style: theme.textTheme.labelSmall?.copyWith(color: colors.textPrimary),
          ),
        ],
      ),
    );
  }
}
