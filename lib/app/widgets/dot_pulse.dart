import 'package:ai_assistant/app/theme/app_colors.dart';
import 'package:flutter/material.dart';

/// The signature dot-matrix loader (design-system §7) — a row of dots pulsing in sequence, a
/// Glyph-style rhythm that replaces conventional spinners. Used for the chat "generating" state
/// and any indeterminate wait. Pass [color] = accent for live/generating, a neutral token
/// otherwise.
class DotPulse extends StatefulWidget {
  const DotPulse({
    super.key,
    this.dotCount = 4,
    this.dotSize = 6,
    this.spacing = 5,
    this.color,
  });

  final int dotCount;
  final double dotSize;
  final double spacing;
  final Color? color;

  @override
  State<DotPulse> createState() => _DotPulseState();
}

class _DotPulseState extends State<DotPulse> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? Theme.of(context).extension<AppColors>()!.textSecondary;
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: List<Widget>.generate(widget.dotCount, (index) {
            // Phase-shift each dot so the pulse travels across the row.
            final phase = (_controller.value - index / widget.dotCount) % 1.0;
            final opacity = 0.25 + 0.75 * (1 - (phase * 2 - 1).abs()).clamp(0.0, 1.0);
            return Padding(
              padding: EdgeInsets.only(right: index == widget.dotCount - 1 ? 0 : widget.spacing),
              child: Container(
                width: widget.dotSize,
                height: widget.dotSize,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: opacity),
                  shape: BoxShape.circle,
                ),
              ),
            );
          }),
        );
      },
    );
  }
}
