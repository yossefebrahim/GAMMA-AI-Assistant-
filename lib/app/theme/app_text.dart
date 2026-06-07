import 'package:flutter/widgets.dart';

/// Centralized typography tokens (design-system §3; Principle X).
///
/// Three faces, three roles — all bundled offline (see pubspec `fonts:`):
///   * [uiFamily] Space Grotesk — screen titles, model names, message text, buttons.
///   * [specFamily] Space Mono — status readouts / metadata, used UPPERCASE + letter-spaced.
///   * [dotMatrixFamily] Pixelify Sans — the dot-matrix display face for the wordmark and big
///     numerals (download %, timers), reached ONLY through [dotMatrix]. Never used for body text.
///
/// Styles here are color-agnostic; the [AppTheme] applies `onSurface` via the text theme so a
/// single switch flips light/dark. Sizes/line-heights come straight from the design-system scale.
abstract final class AppText {
  static const String uiFamily = 'Space Grotesk';
  static const String specFamily = 'Space Mono';
  static const String dotMatrixFamily = 'Pixelify Sans';

  // Display — dot-matrix face (design-system scale: Display L 40/44, Display S 28/32).
  static const TextStyle displayL = TextStyle(
    fontFamily: dotMatrixFamily,
    fontSize: 40,
    height: 44 / 40,
  );
  static const TextStyle displayS = TextStyle(
    fontFamily: dotMatrixFamily,
    fontSize: 28,
    height: 32 / 28,
  );

  // Titles — Space Grotesk 600, tight tracking.
  static const TextStyle titleL = TextStyle(
    fontFamily: uiFamily,
    fontSize: 22,
    height: 28 / 22,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.2,
  );
  static const TextStyle titleM = TextStyle(
    fontFamily: uiFamily,
    fontSize: 17,
    height: 24 / 17,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.2,
  );

  // Body — Space Grotesk 400.
  static const TextStyle bodyL = TextStyle(
    fontFamily: uiFamily,
    fontSize: 16,
    height: 24 / 16,
    fontWeight: FontWeight.w400,
  );
  static const TextStyle bodyM = TextStyle(
    fontFamily: uiFamily,
    fontSize: 14,
    height: 20 / 14,
    fontWeight: FontWeight.w400,
  );

  /// Label / Spec — Space Mono 500, +1.5 tracking. Render the TEXT uppercase at the call site
  /// (e.g. via [spec]); the style only carries the tracking/weight.
  static const TextStyle label = TextStyle(
    fontFamily: specFamily,
    fontSize: 11,
    height: 16 / 11,
    fontWeight: FontWeight.w500,
    letterSpacing: 1.5,
  );

  /// Spec-sheet metadata convention: uppercase the string for the mono [label] style
  /// (e.g. `GEMMA 4 E2B · GPU · ON-DEVICE`).
  static String spec(String value) => value.toUpperCase();

  /// Dot-matrix display helper — the ONLY sanctioned way to use the dot-matrix face
  /// (branding + numerals). Defaults match [displayL]; pass [color]/[fontSize] as needed.
  static TextStyle dotMatrix({
    double fontSize = 40,
    Color? color,
    FontWeight? fontWeight,
    double? height,
    double letterSpacing = 0,
  }) {
    return TextStyle(
      fontFamily: dotMatrixFamily,
      fontSize: fontSize,
      color: color,
      fontWeight: fontWeight,
      height: height,
      letterSpacing: letterSpacing,
    );
  }
}
