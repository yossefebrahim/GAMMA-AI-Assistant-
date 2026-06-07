/// Spacing, shape, and touch-target tokens (design-system §4 / §8; Principle X).
///
/// Everything aligns to a 4dp base grid. No widget hardcodes raw spacing numbers — they compose
/// these tokens so the rhythm stays consistent and adjustable in one place.
abstract final class AppSpacing {
  // 4dp grid: 4 · 8 · 12 · 16 · 24 · 32 · 48.
  static const double s4 = 4;
  static const double s8 = 8;
  static const double s12 = 12;
  static const double s16 = 16;
  static const double s24 = 24;
  static const double s32 = 32;
  static const double s48 = 48;

  /// Default horizontal screen padding.
  static const double screenPadding = 16;

  /// Padding for hero / empty states.
  static const double heroPadding = 24;

  // Corner radii (design-system §4): cards/sheets 12, inputs/chips/buttons 8.
  static const double radiusCard = 12;
  static const double radiusControl = 8;

  /// Hairline border width — the primary means of separation (no shadows).
  static const double hairline = 1;

  /// Accessibility floor (Principle VI / FR-031): minimum interactive target.
  static const double minTouchTarget = 48;
}
