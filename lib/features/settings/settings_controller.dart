import 'package:ai_assistant/data/model/background_model_downloader.dart';
import 'package:ai_assistant/data/repositories/model_install_repository.dart';
import 'package:ai_assistant/data/repositories/settings_repository.dart';
import 'package:ai_assistant/domain/entities/app_settings.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// On-disk size of the installed model in bytes, or null if none (FR-030). Refreshed after delete.
final modelStorageBytesProvider = FutureProvider.autoDispose<int?>((ref) {
  return ref.read(modelDownloaderProvider).installedSizeBytes();
});

/// Settings actions (FR-024 theme, FR-030 model delete). Holds no state — theme is read from
/// [themeModeProvider]; storage from [modelStorageBytesProvider].
class SettingsController extends Notifier<void> {
  @override
  void build() {}

  /// Persisted theme change (FR-024).
  Future<void> setTheme(AppThemeMode mode) {
    return ref.read(themeModeProvider.notifier).set(mode);
  }

  /// Delete the downloaded model and reclaim its space (FR-030). Clears the install record so
  /// routing returns the user to onboarding.
  Future<void> deleteModel() async {
    await ref.read(modelDownloaderProvider).deleteModel();
    await ref.read(modelInstallRepositoryProvider).markNotInstalled();
    ref.invalidate(modelStorageBytesProvider);
  }
}

final settingsControllerProvider = NotifierProvider<SettingsController, void>(
  SettingsController.new,
);
