import 'package:ai_assistant/data/model/background_model_downloader.dart';
import 'package:ai_assistant/data/repositories/model_install_repository.dart';
import 'package:ai_assistant/data/repositories/settings_repository.dart';
import 'package:ai_assistant/domain/entities/app_settings.dart';
import 'package:ai_assistant/domain/entities/model_install.dart';
import 'package:ai_assistant/features/settings/settings_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/container_harness.dart';
import '../../helpers/fake_model_downloader.dart';

/// Polish T048 — settings actions (FR-024 theme, FR-030 model delete).
void main() {
  late FakeModelDownloader downloader;
  late ProviderContainer container;

  setUp(() {
    downloader = FakeModelDownloader()..sizeBytes = 2400000000;
    container = makeContainer(
      overrides: [modelDownloaderProvider.overrideWithValue(downloader)],
    );
  });

  tearDown(() => container.dispose());

  test('setTheme persists the theme mode (FR-024)', () async {
    await container.read(settingsControllerProvider.notifier).setTheme(AppThemeMode.light);

    expect(container.read(themeModeProvider), AppThemeMode.light);
    final settings = await container.read(settingsRepositoryProvider).read();
    expect(settings.themeMode, AppThemeMode.light);
  });

  test('deleteModel frees the file and clears the install record (FR-030)', () async {
    await container
        .read(modelInstallRepositoryProvider)
        .markInstalled(filePath: '/fake/model', sizeBytes: 2400000000);

    await container.read(settingsControllerProvider.notifier).deleteModel();

    final install = await container.read(modelInstallRepositoryProvider).read();
    expect(install?.state, ModelInstallState.notInstalled);
    expect(await downloader.installedSizeBytes(), isNull); // file removed
  });
}
