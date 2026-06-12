import 'package:flutter/material.dart';

/// Centralized color tokens (Constitution Principle X — Design Identity).
///
/// The binding source of truth is `.specify/memory/design-system.md` §2. No widget may hardcode
/// a hex value; everything reads these tokens, either directly (`AppColors.dark.accent`) or via
/// the [ThemeExtension] (`Theme.of(context).extension<AppColors>()!`).
///
/// Accessibility floor (Principle VI, research R6) prevails over the palette: `textMuted`
/// (#5C5C5C, 3.14:1) and `accent` (#D71921, 4.05:1) FAIL WCAG AA for normal-size text. Use
/// `textMuted` only for genuinely disabled/inactive elements, and `accent` only as large/bold
/// text, an icon, or a white-on-red fill — never small body text or essential labels. In
/// particular, conversation-list timestamps MUST use `textSecondary` (#A0A0A0, 8.03:1).
@immutable
class AppColors extends ThemeExtension<AppColors> {
  const AppColors({
    required this.bg,
    required this.surface,
    required this.surfaceContainer,
    required this.surfaceContainerHigh,
    required this.outline,
    required this.outlineVariant,
    required this.textPrimary,
    required this.textSecondary,
    required this.textMuted,
    required this.accent,
    required this.onAccent,
  });

  /// App canvas (true black on OLED for dark).
  final Color bg;

  /// Sheets, dialogs, primary cards.
  final Color surface;

  /// Raised cards, chat input bar.
  final Color surfaceContainer;

  /// User message bubble, chips, fields.
  final Color surfaceContainerHigh;

  /// Hairline borders, the main separator (1dp).
  final Color outline;

  /// Faint dividers.
  final Color outlineVariant;

  /// Body and headings.
  final Color textPrimary;

  /// Captions, secondary labels, conversation timestamps (AA-safe).
  final Color textSecondary;

  /// Disabled / inactive only (fails AA for normal text — never essential text).
  final Color textMuted;

  /// The single accent — active / recording / stop / destructive / error ONLY.
  final Color accent;

  /// Text/icon on an accent fill.
  final Color onAccent;

  /// Dark theme (default) — design-system §2.1.
  static const AppColors dark = AppColors(
    bg: Color(0xFF000000),
    surface: Color(0xFF0D0D0D),
    surfaceContainer: Color(0xFF161616),
    surfaceContainerHigh: Color(0xFF222222),
    outline: Color(0xFF2E2E2E),
    outlineVariant: Color(0xFF1C1C1C),
    textPrimary: Color(0xFFFFFFFF),
    textSecondary: Color(0xFFA0A0A0),
    textMuted: Color(0xFF5C5C5C),
    accent: Color(0xFFD71921),
    onAccent: Color(0xFFFFFFFF),
  );

  /// Light theme (optional inverse) — design-system §2.2.
  static const AppColors light = AppColors(
    bg: Color(0xFFFFFFFF),
    surface: Color(0xFFFAFAFA),
    surfaceContainer: Color(0xFFF0F0F0),
    surfaceContainerHigh: Color(0xFFE6E6E6),
    outline: Color(0xFFD6D6D6),
    outlineVariant: Color(0xFFECECEC),
    textPrimary: Color(0xFF000000),
    textSecondary: Color(0xFF5C5C5C),
    textMuted: Color(0xFF9A9A9A),
    accent: Color(0xFFD71921),
    onAccent: Color(0xFFFFFFFF),
  );

  @override
  AppColors copyWith({
    Color? bg,
    Color? surface,
    Color? surfaceContainer,
    Color? surfaceContainerHigh,
    Color? outline,
    Color? outlineVariant,
    Color? textPrimary,
    Color? textSecondary,
    Color? textMuted,
    Color? accent,
    Color? onAccent,
  }) {
    return AppColors(
      bg: bg ?? this.bg,
      surface: surface ?? this.surface,
      surfaceContainer: surfaceContainer ?? this.surfaceContainer,
      surfaceContainerHigh: surfaceContainerHigh ?? this.surfaceContainerHigh,
      outline: outline ?? this.outline,
      outlineVariant: outlineVariant ?? this.outlineVariant,
      textPrimary: textPrimary ?? this.textPrimary,
      textSecondary: textSecondary ?? this.textSecondary,
      textMuted: textMuted ?? this.textMuted,
      accent: accent ?? this.accent,
      onAccent: onAccent ?? this.onAccent,
    );
  }

  @override
  AppColors lerp(ThemeExtension<AppColors>? other, double t) {
    if (other is! AppColors) return this;
    return AppColors(
      bg: Color.lerp(bg, other.bg, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      surfaceContainer: Color.lerp(
        surfaceContainer,
        other.surfaceContainer,
        t,
      )!,
      surfaceContainerHigh: Color.lerp(
        surfaceContainerHigh,
        other.surfaceContainerHigh,
        t,
      )!,
      outline: Color.lerp(outline, other.outline, t)!,
      outlineVariant: Color.lerp(outlineVariant, other.outlineVariant, t)!,
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t)!,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
      textMuted: Color.lerp(textMuted, other.textMuted, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      onAccent: Color.lerp(onAccent, other.onAccent, t)!,
    );
  }
}
