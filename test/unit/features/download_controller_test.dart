import 'package:ai_assistant/data/model/background_model_downloader.dart';
import 'package:ai_assistant/data/repositories/model_install_repository.dart';
import 'package:ai_assistant/domain/entities/model_install.dart';
import 'package:ai_assistant/domain/services/media_permission_service.dart';
import 'package:ai_assistant/domain/services/model_downloader.dart';
import 'package:ai_assistant/features/download/download_controller.dart';
import 'package:ai_assistant/infrastructure/media/permission_handler_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/container_harness.dart';
import '../../helpers/fake_media_permission_service.dart';
import '../../helpers/fake_model_downloader.dart';

/// US1 download controller (FR-007/FR-008/FR-011, SC-003) — driven by [FakeModelDownloader] over
/// an in-memory drift DB. No network, no native plugin.
void main() {
  late FakeModelDownloader downloader;
  late FakeMediaPermissionService permission;
  late ProviderContainer container;

  setUp(() {
    downloader = FakeModelDownloader();
    // Default: all-files access already granted, so the download path runs unimpeded.
    permission = FakeMediaPermissionService();
    container = makeContainer(
      overrides: [
        modelDownloaderProvider.overrideWithValue(downloader),
        mediaPermissionServiceProvider.overrideWithValue(permission),
      ],
    );
  });

  tearDown(() => container.dispose());

  DownloadController controller() =>
      container.read(downloadControllerProvider.notifier);
  DownloadUiState read() => container.read(downloadControllerProvider);

  test(
    'declined "all files access" blocks the download — no network call',
    () async {
      permission
        ..storageStatusValue = MediaPermissionStatus.denied
        ..storageRequestResults = [MediaPermissionStatus.denied];

      await controller().start();

      expect(read().isFailed, isTrue);
      expect(read().permissionBlocked, isTrue);
      // The model downloader was never touched — nothing left the device.
      expect(downloader.downloadCount, 0);
      expect(
        await container.read(modelInstallRepositoryProvider).read(),
        isNull,
      );
    },
  );

  test(
    'reinstall fast-path: an existing model is adopted without re-downloading',
    () async {
      downloader.presetInstalled(
        '/storage/emulated/0/AiAssistant/models/gemma-4-e2b.litertlm',
        size: 2400000000,
      );

      await controller().start();

      expect(read().isComplete, isTrue);
      // No download stream was opened — the surviving file was reused.
      expect(downloader.downloadCount, 0);
      final install = await container
          .read(modelInstallRepositoryProvider)
          .read();
      expect(install?.state, ModelInstallState.installed);
      expect(install?.sizeBytes, 2400000000);
    },
  );

  test('maps progress to percent + bytes (FR-007)', () async {
    downloader.scriptedProgress = const [
      DownloadProgress(
        phase: DownloadPhase.running,
        fraction: 0.5,
        downloadedBytes: 1200000000,
        totalBytes: 2400000000,
      ),
    ];

    await controller().start();
    await pumpEventQueue();

    expect(read().percent, 50);
    expect(read().downloadedBytes, 1200000000);
    expect(read().totalBytes, 2400000000);
  });

  test(
    'cancel stops quickly (SC-003) and never exposes a partial as installed (FR-008/FR-011)',
    () async {
      downloader.scriptedProgress = const [
        DownloadProgress(
          phase: DownloadPhase.running,
          fraction: 0.3,
          downloadedBytes: 700000000,
        ),
      ];

      await controller().start();
      await pumpEventQueue();

      final stopwatch = Stopwatch()..start();
      await controller().cancel();
      stopwatch.stop();

      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 2)));
      expect(read().isCanceled, isTrue);
      expect(downloader.cancelCount, 1);
      // No verified file, no install record — a partial is never usable.
      expect(await downloader.installedModelPath(), isNull);
      expect(
        await container.read(modelInstallRepositoryProvider).read(),
        isNull,
      );
    },
  );

  test(
    'a partial (running-only) download is never recorded as installed (FR-011)',
    () async {
      downloader.scriptedProgress = const [
        DownloadProgress(
          phase: DownloadPhase.running,
          fraction: 0.2,
          downloadedBytes: 480000000,
        ),
        DownloadProgress(
          phase: DownloadPhase.running,
          fraction: 0.6,
          downloadedBytes: 1440000000,
        ),
      ];

      await controller().start();
      await pumpEventQueue();

      expect(read().isComplete, isFalse);
      expect(
        await container.read(modelInstallRepositoryProvider).read(),
        isNull,
      );
    },
  );

  test(
    'failure surfaces, then retry completes and records the install (FR-011)',
    () async {
      downloader.scriptedProgress = const [
        DownloadProgress(
          phase: DownloadPhase.failed,
          fraction: 0,
          downloadedBytes: 0,
          errorMessage: 'network dropped',
        ),
      ];

      await controller().start();
      await pumpEventQueue();
      expect(read().isFailed, isTrue);
      expect(read().error, 'network dropped');

      // Retry with a successful script.
      downloader.scriptedProgress = const [
        DownloadProgress(
          phase: DownloadPhase.running,
          fraction: 0.9,
          downloadedBytes: 2160000000,
        ),
        DownloadProgress(
          phase: DownloadPhase.completed,
          fraction: 1,
          downloadedBytes: 2400000000,
          totalBytes: 2400000000,
        ),
      ];
      downloader.sizeBytes = 2400000000;

      controller().retry();
      await pumpEventQueue();

      expect(read().isComplete, isTrue);
      final install = await container
          .read(modelInstallRepositoryProvider)
          .read();
      expect(install?.state, ModelInstallState.installed);
      expect(install?.sizeBytes, 2400000000);
    },
  );
}
