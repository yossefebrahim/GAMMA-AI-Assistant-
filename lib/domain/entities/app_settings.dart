import 'package:meta/meta.dart';

/// User theme preference (FR-023/FR-024). Named to avoid colliding with Flutter's `ThemeMode`;
/// the presentation layer maps this to `material.ThemeMode`.
enum AppThemeMode { dark, light, system }

/// Single-row app preferences.
@immutable
class AppSettings {
  const AppSettings({
    required this.themeMode,
    this.licenseAcknowledgedAt,
  });

  /// Defaults to [AppThemeMode.dark] (FR-023); persisted across sessions (FR-024).
  final AppThemeMode themeMode;

  /// Set when the user accepts the one-time model license (clarification Q1); gates the download.
  final DateTime? licenseAcknowledgedAt;

  /// Whether the one-time model license has been acknowledged.
  bool get hasAcknowledgedLicense => licenseAcknowledgedAt != null;

  /// The default settings for a fresh install: dark theme, license not yet acknowledged.
  static const AppSettings defaults = AppSettings(themeMode: AppThemeMode.dark);

  AppSettings copyWith({
    AppThemeMode? themeMode,
    DateTime? licenseAcknowledgedAt,
  }) {
    return AppSettings(
      themeMode: themeMode ?? this.themeMode,
      licenseAcknowledgedAt: licenseAcknowledgedAt ?? this.licenseAcknowledgedAt,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AppSettings &&
      other.themeMode == themeMode &&
      other.licenseAcknowledgedAt == licenseAcknowledgedAt;

  @override
  int get hashCode => Object.hash(themeMode, licenseAcknowledgedAt);
}
