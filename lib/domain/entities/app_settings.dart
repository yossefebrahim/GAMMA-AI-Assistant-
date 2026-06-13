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
    this.memoryEnabled = true,
    this.webAccessEnabled = false,
  });

  /// Defaults to [AppThemeMode.dark] (FR-023); persisted across sessions (FR-024).
  final AppThemeMode themeMode;

  /// Set when the user accepts the one-time model license (clarification Q1); gates the download.
  final DateTime? licenseAcknowledgedAt;

  /// Whether durable memory is on (005, Clarifications Q3 — default **true**). When false, facts
  /// are neither captured nor injected, though management still works (FR-016).
  final bool memoryEnabled;

  /// Whether web research tools are globally enabled (006, schema v6 — default **false**, off by
  /// default per SC-001 / Decision 1). Individual conversations may override via
  /// [Conversation.webAccessOverride]. Read/written like [memoryEnabled].
  final bool webAccessEnabled;

  /// Whether the one-time model license has been acknowledged.
  bool get hasAcknowledgedLicense => licenseAcknowledgedAt != null;

  /// The default settings for a fresh install: dark theme, license not yet acknowledged, memory on,
  /// web access off.
  static const AppSettings defaults = AppSettings(themeMode: AppThemeMode.dark);

  AppSettings copyWith({
    AppThemeMode? themeMode,
    DateTime? licenseAcknowledgedAt,
    bool? memoryEnabled,
    bool? webAccessEnabled,
  }) {
    return AppSettings(
      themeMode: themeMode ?? this.themeMode,
      licenseAcknowledgedAt:
          licenseAcknowledgedAt ?? this.licenseAcknowledgedAt,
      memoryEnabled: memoryEnabled ?? this.memoryEnabled,
      webAccessEnabled: webAccessEnabled ?? this.webAccessEnabled,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AppSettings &&
      other.themeMode == themeMode &&
      other.licenseAcknowledgedAt == licenseAcknowledgedAt &&
      other.memoryEnabled == memoryEnabled &&
      other.webAccessEnabled == webAccessEnabled;

  @override
  int get hashCode => Object.hash(
    themeMode,
    licenseAcknowledgedAt,
    memoryEnabled,
    webAccessEnabled,
  );
}
