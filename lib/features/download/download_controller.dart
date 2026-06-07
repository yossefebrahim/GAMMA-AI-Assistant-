import 'dart:async';

import 'package:ai_assistant/core/model_catalog.dart';
import 'package:ai_assistant/data/model/background_model_downloader.dart';
import 'package:ai_assistant/data/repositories/model_install_repository.dart';
import 'package:ai_assistant/domain/services/model_downloader.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Presentation state for the download screen — a flat projection of [DownloadProgress] plus
/// derived helpers for the UI.
class DownloadUiState {
  const DownloadUiState({
    this.phase = DownloadPhase.idle,
    this.fraction = 0,
    this.downloadedBytes = 0,
    this.totalBytes,
    this.stalled = false,
    this.error,
  });

  final DownloadPhase phase;
  final double fraction;
  final int downloadedBytes;
  final int? totalBytes;
  final bool stalled;
  final String? error;

  int get percent => (fraction * 100).round();
  bool get isActive => phase == DownloadPhase.running || phase == DownloadPhase.paused;
  bool get isComplete => phase == DownloadPhase.completed;
  bool get isFailed => phase == DownloadPhase.failed;
  bool get isCanceled => phase == DownloadPhase.canceled;

  DownloadUiState copyWith({
    DownloadPhase? phase,
    double? fraction,
    int? downloadedBytes,
    int? totalBytes,
    bool? stalled,
    String? error,
  }) {
    return DownloadUiState(
      phase: phase ?? this.phase,
      fraction: fraction ?? this.fraction,
      downloadedBytes: downloadedBytes ?? this.downloadedBytes,
      totalBytes: totalBytes ?? this.totalBytes,
      stalled: stalled ?? this.stalled,
      error: error,
    );
  }
}

/// Consumes the [ModelDownloader] stream and drives the download UI (FR-007–FR-011). On a verified
/// completion it records the [ModelInstall] (so routing/settings know a model exists); a partial
/// download is never recorded (the downloader only reports `completed` after the atomic rename).
class DownloadController extends Notifier<DownloadUiState> {
  StreamSubscription<DownloadProgress>? _subscription;

  @override
  DownloadUiState build() {
    ref.onDispose(() => _subscription?.cancel());
    return const DownloadUiState();
  }

  /// Begin (or restart) the one-time model download.
  void start() {
    _subscription?.cancel();
    state = const DownloadUiState(phase: DownloadPhase.running);
    final downloader = ref.read(modelDownloaderProvider);
    _subscription = downloader.download(ModelCatalog.downloadUrl).listen(
      (progress) async {
        state = DownloadUiState(
          phase: progress.phase,
          fraction: progress.fraction,
          downloadedBytes: progress.downloadedBytes,
          totalBytes: progress.totalBytes,
          stalled: progress.stalled,
          error: progress.errorMessage,
        );
        if (progress.phase == DownloadPhase.completed) {
          final path = await downloader.installedModelPath();
          if (path != null) {
            final size = await downloader.installedSizeBytes();
            await ref
                .read(modelInstallRepositoryProvider)
                .markInstalled(filePath: path, sizeBytes: size ?? 0);
          }
        }
      },
      onError: (Object error) {
        state = state.copyWith(phase: DownloadPhase.failed, error: '$error');
      },
    );
  }

  /// Cancel the in-flight download (FR-008/SC-003); the partial file is discarded by the downloader.
  Future<void> cancel() async {
    await ref.read(modelDownloaderProvider).cancel();
    await _subscription?.cancel();
    state = state.copyWith(phase: DownloadPhase.canceled);
  }

  /// Retry after a failure (FR-011).
  void retry() => start();
}

final downloadControllerProvider =
    NotifierProvider<DownloadController, DownloadUiState>(DownloadController.new);
