import 'dart:async';

import 'package:ai_assistant/core/model_catalog.dart';
import 'package:ai_assistant/data/model/background_model_downloader.dart';
import 'package:ai_assistant/data/repositories/model_install_repository.dart';
import 'package:ai_assistant/domain/services/media_permission_service.dart';
import 'package:ai_assistant/domain/services/model_downloader.dart';
import 'package:ai_assistant/features/chat/chat_providers.dart'
    show installedModelPathProvider;
import 'package:ai_assistant/infrastructure/media/permission_handler_service.dart';
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
    this.permissionBlocked = false,
  });

  final DownloadPhase phase;
  final double fraction;
  final int downloadedBytes;
  final int? totalBytes;
  final bool stalled;
  final String? error;

  /// True when the download can't proceed because "all files access" was declined — the UI offers
  /// an "open settings" action instead of a plain retry (the model must live in the public,
  /// uninstall-surviving storage folder, which needs the grant).
  final bool permissionBlocked;

  int get percent => (fraction * 100).round();
  bool get isActive =>
      phase == DownloadPhase.running || phase == DownloadPhase.paused;
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
    bool? permissionBlocked,
  }) {
    return DownloadUiState(
      phase: phase ?? this.phase,
      fraction: fraction ?? this.fraction,
      downloadedBytes: downloadedBytes ?? this.downloadedBytes,
      totalBytes: totalBytes ?? this.totalBytes,
      stalled: stalled ?? this.stalled,
      // Intentional: `error` resets to null on every copyWith unless re-supplied — a copy that
      // doesn't pass `error` clears any prior message (so progress updates don't carry a stale error).
      error: error,
      permissionBlocked: permissionBlocked ?? this.permissionBlocked,
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
  ///
  /// First ensures "all files access" so the model lands in public, uninstall-surviving storage;
  /// if that's declined the download is blocked (the UI offers "open settings") rather than
  /// silently re-downloading into doomed app-private storage. If the model is already on disk from
  /// a previous install (the file survived an uninstall), it's recorded and the download is skipped
  /// — the reinstall fast-path, no 2.4 GB re-download.
  Future<void> start() async {
    await _subscription?.cancel();
    state = const DownloadUiState(phase: DownloadPhase.running);

    final permission = ref.read(mediaPermissionServiceProvider);
    var status = await permission.storageStatus();
    if (status != MediaPermissionStatus.granted) {
      status = await permission.requestStorage();
    }
    if (status != MediaPermissionStatus.granted) {
      state = const DownloadUiState(
        phase: DownloadPhase.failed,
        permissionBlocked: true,
        error:
            'storage access is needed to keep the model on your device across app reinstalls. '
            'grant "all files access" and retry.',
      );
      return;
    }

    final downloader = ref.read(modelDownloaderProvider);

    // Reinstall fast-path: the model file survived a prior uninstall — adopt it, skip the download.
    final existing = await downloader.installedModelPath();
    if (existing != null) {
      await _recordInstalled(existing);
      state = const DownloadUiState(
        phase: DownloadPhase.completed,
        fraction: 1,
      );
      return;
    }

    _subscription = downloader
        .download(ModelCatalog.downloadUrl)
        .listen(
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
              if (path != null) await _recordInstalled(path);
            }
          },
          onError: (Object error) {
            state = state.copyWith(
              phase: DownloadPhase.failed,
              error: '$error',
            );
          },
        );
  }

  /// Record a verified, on-disk model as installed and refresh the cached install-path provider.
  ///
  /// [installedModelPathProvider] is read once at app start (→ `null` on a fresh install) and is
  /// non-autoDispose, so without this invalidation the chat layer's `modelSessionProvider` would
  /// re-read the stale `null` and throw `ModelUnavailableException` after a just-finished download
  /// or reinstall-adopt. Invalidating it (and, transitively, `appStartProvider`) makes routing and
  /// the model load see the freshly-available path.
  Future<void> _recordInstalled(String path) async {
    final size = await ref.read(modelDownloaderProvider).installedSizeBytes();
    await ref
        .read(modelInstallRepositoryProvider)
        .markInstalled(filePath: path, sizeBytes: size ?? 0);
    ref.invalidate(installedModelPathProvider);
  }

  /// Cancel the in-flight download (FR-008/SC-003); the partial file is discarded by the downloader.
  Future<void> cancel() async {
    await ref.read(modelDownloaderProvider).cancel();
    await _subscription?.cancel();
    state = state.copyWith(phase: DownloadPhase.canceled);
  }

  /// Retry after a failure (FR-011) or after the user grants access in settings.
  void retry() => unawaited(start());

  /// Open the OS settings page so the user can grant "all files access" after declining it.
  Future<void> openStorageSettings() async {
    await ref.read(mediaPermissionServiceProvider).openSettings();
  }
}

final downloadControllerProvider =
    NotifierProvider<DownloadController, DownloadUiState>(
      DownloadController.new,
    );
