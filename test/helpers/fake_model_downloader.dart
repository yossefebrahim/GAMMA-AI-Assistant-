import 'dart:async';

import 'package:ai_assistant/domain/services/model_downloader.dart';

/// In-memory [ModelDownloader] for unit tests (contract: model_download.md "Test double").
///
/// Emits a scripted progress sequence (controllable rate, stall, cancel, fail, complete);
/// [cancel] flips to `canceled` and clears the fake path; [installedModelPath] returns non-null
/// only after a scripted `completed` emission — so "partial-never-usable" (FR-011) is testable.
class FakeModelDownloader implements ModelDownloader {
  /// Progress emissions [download] will yield, in order.
  List<DownloadProgress> scriptedProgress = <DownloadProgress>[];

  /// Delay between emissions (default: emit synchronously).
  Duration emitInterval = Duration.zero;

  /// Path reported once a `completed` emission is reached. Defaults to a fake app-private path.
  String? completedPath = '/fake/app/models/gemma-4-e2b.litertlm';

  int? sizeBytes;

  // --- observed state ---
  String? lastUrl;
  int downloadCount = 0;
  int cancelCount = 0;

  String? _installedPath;
  bool _canceled = false;
  StreamController<DownloadProgress>? _controller;

  @override
  Stream<DownloadProgress> download(String url) {
    lastUrl = url;
    downloadCount++;
    _canceled = false;
    final controller = StreamController<DownloadProgress>();
    _controller = controller;

    Future<void> pump() async {
      for (final progress in scriptedProgress) {
        if (_canceled || controller.isClosed) break;
        if (emitInterval > Duration.zero) {
          await Future<void>.delayed(emitInterval);
        }
        if (_canceled || controller.isClosed) break;
        controller.add(progress);
        if (progress.phase == DownloadPhase.completed) {
          _installedPath = completedPath;
        }
      }
      if (!controller.isClosed) await controller.close();
    }

    unawaited(pump());
    return controller.stream;
  }

  @override
  Future<void> cancel() async {
    cancelCount++;
    _canceled = true;
    _installedPath = null; // partial discarded (FR-008)
    final controller = _controller;
    if (controller != null && !controller.isClosed) {
      controller.add(
        const DownloadProgress(
          phase: DownloadPhase.canceled,
          fraction: 0,
          downloadedBytes: 0,
        ),
      );
      await controller.close();
    }
  }

  @override
  Future<String?> installedModelPath() async => _installedPath;

  @override
  Future<void> deleteModel() async {
    _installedPath = null;
    sizeBytes = null;
  }

  @override
  Future<int?> installedSizeBytes() async => sizeBytes;
}
