import 'package:ai_assistant/app/theme/app_colors.dart';
import 'package:ai_assistant/app/theme/app_spacing.dart';
import 'package:ai_assistant/app/theme/app_text.dart';
import 'package:flutter/material.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

/// Builds the Material 3 themes from the centralized tokens (design-system §9; Principles VI/X).
///
/// Flat by construction: elevation 0 everywhere, surface tint + shadows killed, separation by
/// hairline `outline` borders and surface steps. Touch targets stay at the 48dp padded default
/// (accessibility floor, Principle VI). The [AppColors] token set is attached as a
/// [ThemeExtension] so widgets can read raw tokens where a Material role doesn't fit.
abstract final class AppTheme {
  static ThemeData get dark => _build(AppColors.dark, Brightness.dark);
  static ThemeData get light => _build(AppColors.light, Brightness.light);

  static ThemeData _build(AppColors c, Brightness brightness) {
    final base =
        brightness == Brightness.dark ? const ColorScheme.dark() : const ColorScheme.light();
    final scheme = base.copyWith(
      brightness: brightness,
      primary: c.accent,
      onPrimary: c.onAccent,
      error: c.accent,
      onError: c.onAccent,
      surface: c.bg,
      onSurface: c.textPrimary,
      surfaceContainerLowest: c.bg,
      surfaceContainerLow: c.surface,
      surfaceContainer: c.surfaceContainer,
      surfaceContainerHigh: c.surfaceContainerHigh,
      surfaceContainerHighest: c.surfaceContainerHigh,
      onSurfaceVariant: c.textSecondary,
      outline: c.outline,
      outlineVariant: c.outlineVariant,
      // gpt_markdown's code block fills with onInverseSurface; map it to the raised-card token
      // so fenced code reads as a surface step, not Material's default inverse pairing.
      onInverseSurface: c.surfaceContainer,
    );

    final cardShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(AppSpacing.radiusCard),
      side: BorderSide(color: c.outline),
    );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: c.bg,
      canvasColor: c.bg,
      fontFamily: AppText.uiFamily,
      textTheme: _textTheme(c.textPrimary),
      extensions: <ThemeExtension<dynamic>>[c, _markdownTheme(c, brightness)],
      // Flat: hairline separation, no shadow-based elevation.
      dividerTheme: DividerThemeData(
        color: c.outline,
        thickness: AppSpacing.hairline,
        space: AppSpacing.hairline,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: c.bg,
        foregroundColor: c.textPrimary,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
      ),
      cardTheme: CardThemeData(
        color: c.surface,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.transparent,
        shape: cardShape,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: c.surface,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        shape: cardShape,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: c.surface,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.transparent,
      ),
      // Accessibility floor (Principle VI): keep the 48dp padded tap target; never go compact.
      materialTapTargetSize: MaterialTapTargetSize.padded,
      visualDensity: VisualDensity.standard,
      splashFactory: InkSparkle.splashFactory,
    );
  }

  /// Markdown rendering tokens for assistant replies (design-system §2/§3). Headings cap at the
  /// chat title scale — a reply is a bubble, not a document — and links/highlights stay
  /// monochrome: the red accent is reserved for active/stop/destructive states (Principle X),
  /// so gpt_markdown's blue/red link defaults are overridden here.
  static GptMarkdownThemeData _markdownTheme(AppColors c, Brightness brightness) {
    TextStyle tinted(TextStyle s) => s.copyWith(color: c.textPrimary);
    return GptMarkdownThemeData(
      brightness: brightness,
      h1: tinted(AppText.titleL),
      h2: tinted(AppText.titleM),
      h3: tinted(AppText.bodyL.copyWith(fontWeight: FontWeight.w600)),
      h4: tinted(AppText.bodyM.copyWith(fontWeight: FontWeight.w600)),
      h5: tinted(AppText.bodyM.copyWith(fontWeight: FontWeight.w600)),
      h6: tinted(AppText.bodyM.copyWith(fontWeight: FontWeight.w600)),
      hrLineThickness: AppSpacing.hairline,
      hrLineColor: c.outline,
      linkColor: c.textPrimary,
      linkHoverColor: c.textSecondary,
      highlightColor: c.surfaceContainerHigh,
      autoAddDividerLineAfterH1: false,
    );
  }

  static TextTheme _textTheme(Color onSurface) {
    TextStyle tinted(TextStyle s) => s.copyWith(color: onSurface);
    return TextTheme(
      displayLarge: tinted(AppText.displayL),
      displaySmall: tinted(AppText.displayS),
      titleLarge: tinted(AppText.titleL),
      titleMedium: tinted(AppText.titleM),
      bodyLarge: tinted(AppText.bodyL),
      bodyMedium: tinted(AppText.bodyM),
      labelSmall: tinted(AppText.label),
      labelMedium: tinted(AppText.label),
    );
  }
}
