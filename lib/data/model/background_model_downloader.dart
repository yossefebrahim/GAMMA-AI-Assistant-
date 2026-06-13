import 'dart:async';
import 'dart:io';

import 'package:ai_assistant/core/model_catalog.dart';
import 'package:ai_assistant/domain/services/model_downloader.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

/// `background_downloader`-backed [ModelDownloader] (R2) — the ONLY file importing
/// `background_downloader`. Downloads the ~2.4 GB model under an Android foreground service,
/// reports percent + bytes ≥ 1×/sec, and guarantees a partial file is never exposed as installed:
/// it writes to `*.part` and only atomic-renames to the final name on `TaskStatus.complete`
/// (FR-007–FR-011). The only network call in the app (Principle I).
///
/// **Persistence across uninstall:** on Android the model is stored in PUBLIC shared storage
/// (`<root>/AiAssistant/models/`, see [ModelCatalog.publicAppDirectory]) — outside
/// `/Android/data/<pkg>/`, so it is NOT deleted when the APK is uninstalled. Writing/reading it
/// needs the "all files access" grant (gated by the caller via the permission seam before
/// [download]). Off-Android (or if the public root can't be resolved) it falls back to app-private
/// documents storage so tests and other platforms still work.
class BackgroundModelDownloader implements ModelDownloader {
  /// Run under a foreground service for anything larger than this many MB (R2).
  static const int _foregroundThresholdMb = 256;

  /// Require this much free space (MB) before starting — comfortably fits the 2.4 GB model.
  static const int _minFreeSpaceMb = 3000;

  /// If no progress arrives for this long while running, surface `stalled` instead of freezing
  /// (SC-002).
  static const Duration _stallAfter = Duration(milliseconds: 1500);

  bool _configured = false;
  String? _taskId;

  Future<void> _ensureConfigured() async {
    if (_configured) return;
    await FileDownloader().configure(
      globalConfig: <(String, Object)>[
        (Config.runInForegroundIfFileLargerThan, _foregroundThresholdMb),
        (Config.checkAvailableSpace, _minFreeSpaceMb),
      ],
    );
    FileDownloader().configureNotification(
      running: const TaskNotification(
        'downloading model',
        'gemma 4 e2b · {progress}',
      ),
      complete: const TaskNotification('model ready', 'gemma 4 e2b installed'),
      error: const TaskNotification('download failed', 'tap to retry'),
      progressBar: true,
    );
    // Best-effort; the download still runs if the user declines the notification.
    await FileDownloader().permissions.request(PermissionType.notifications);
    _configured = true;
  }

  /// Directory the model file lives in: the public, uninstall-surviving folder on Android, or the
  /// app-private documents dir as a fallback (off-Android / unresolvable public root).
  Future<Directory> _modelsDir() async {
    final publicRoot = await _publicAppDir();
    final base = publicRoot ?? await getApplicationDocumentsDirectory();
    return Directory('${base.path}/${ModelCatalog.directory}');
  }

  /// The app's PUBLIC top-level folder on shared storage (e.g. `/storage/emulated/0/AiAssistant`),
  /// derived from the app-specific external dir by trimming `/Android/data/<pkg>/...`. This is the
  /// part of external storage that survives an uninstall. Returns `null` off-Android or when the
  /// path can't be derived, so the caller falls back to app-private storage.
  Future<Directory?> _publicAppDir() async {
    if (!Platform.isAndroid) return null;
    final ext = await getExternalStorageDirectory();
    if (ext == null) return null;
    final marker = ext.path.indexOf('/Android/');
    if (marker <= 0) return null;
    final root = ext.path.substring(0, marker); // e.g. /storage/emulated/0
    return Directory('$root/${ModelCatalog.publicAppDirectory}');
  }

  Future<File> _finalFile() async =>
      File('${(await _modelsDir()).path}/${ModelCatalog.fileName}');
  Future<File> _partFile() async =>
      File('${(await _modelsDir()).path}/${ModelCatalog.partFileName}');

  @override
  Stream<DownloadProgress> download(String url) {
    final controller = StreamController<DownloadProgress>();
    StreamSubscription<TaskUpdate>? updatesSub;
    Timer? stallTimer;
    var lastFraction = 0.0;
    var lastBytes = 0;
    var lastTotal = -1;

    void emit(DownloadProgress progress) {
      if (!controller.isClosed) controller.add(progress);
    }

    void armStallTimer() {
      stallTimer?.cancel();
      stallTimer = Timer(_stallAfter, () {
        emit(
          DownloadProgress(
            phase: DownloadPhase.running,
            fraction: lastFraction,
            downloadedBytes: lastBytes,
            totalBytes: lastTotal >= 0 ? lastTotal : null,
            stalled: true,
          ),
        );
      });
    }

    Future<void> finish(DownloadProgress terminal) async {
      stallTimer?.cancel();
      await updatesSub?.cancel();
      emit(terminal);
      if (!controller.isClosed) await controller.close();
    }

    Future<void> start() async {
      try {
        await _ensureConfigured();
        // Resolve the (public, uninstall-surviving) models dir and ensure it exists — with
        // BaseDirectory.root the downloader writes to an absolute path and won't create the tree.
        final modelsDir = await _modelsDir();
        await modelsDir.create(recursive: true);
        final task = DownloadTask(
          url: url,
          filename: ModelCatalog.partFileName,
          // BaseDirectory.root + an absolute directory (leading slash stripped) lets the file land
          // in public shared storage outside /Android/data/<pkg>/. Resolves to exactly
          // `${modelsDir.path}/${partFileName}`, matching _partFile()/_finalFile().
          baseDirectory: BaseDirectory.root,
          directory: modelsDir.path.startsWith('/')
              ? modelsDir.path.substring(1)
              : modelsDir.path,
          updates: Updates.statusAndProgress,
          allowPause: true,
          retries: 5,
        );
        _taskId = task.taskId;

        // Maps a progress tick onto the captured running state, arms the stall timer, and emits the
        // running snapshot. Keeps the exact `clamp`/`expectedFileSize` arithmetic of the inline form.
        void handleProgress(TaskProgressUpdate update) {
          lastFraction = update.progress.clamp(0.0, 1.0);
          lastTotal = update.expectedFileSize;
          lastBytes = update.hasExpectedFileSize
              ? (update.progress * update.expectedFileSize).round()
              : 0;
          armStallTimer();
          emit(
            DownloadProgress(
              phase: DownloadPhase.running,
              fraction: lastFraction,
              downloadedBytes: lastBytes,
              totalBytes: update.hasExpectedFileSize
                  ? update.expectedFileSize
                  : null,
            ),
          );
        }

        // Maps a terminal/intermediate status onto a single emission, preserving the .part
        // finalize/cancel semantics and the exact emit-vs-finish choice per status.
        Future<void> handleStatus(TaskStatusUpdate update) async {
          switch (update.status) {
            case TaskStatus.complete:
              final ok = await _finalizeInstall();
              await finish(
                DownloadProgress(
                  phase: ok ? DownloadPhase.completed : DownloadPhase.failed,
                  fraction: 1,
                  downloadedBytes: lastBytes,
                  totalBytes: lastTotal >= 0 ? lastTotal : null,
                  errorMessage: ok
                      ? null
                      : 'could not finalize the downloaded file',
                ),
              );
            case TaskStatus.failed:
            case TaskStatus.notFound:
              await finish(
                DownloadProgress(
                  phase: DownloadPhase.failed,
                  fraction: lastFraction,
                  downloadedBytes: lastBytes,
                  totalBytes: lastTotal >= 0 ? lastTotal : null,
                  errorMessage:
                      update.exception?.description ?? 'download failed',
                ),
              );
            case TaskStatus.canceled:
              await _deletePartial();
              await finish(
                const DownloadProgress(
                  phase: DownloadPhase.canceled,
                  fraction: 0,
                  downloadedBytes: 0,
                ),
              );
            case TaskStatus.paused:
              emit(
                DownloadProgress(
                  phase: DownloadPhase.paused,
                  fraction: lastFraction,
                  downloadedBytes: lastBytes,
                  totalBytes: lastTotal >= 0 ? lastTotal : null,
                ),
              );
            case TaskStatus.enqueued:
            case TaskStatus.running:
            case TaskStatus.waitingToRetry:
              // Progress updates carry the detail; nothing to surface on these transitions.
              break;
          }
        }

        updatesSub = FileDownloader().updates
            .where((update) => update.task.taskId == _taskId)
            .listen((update) async {
              switch (update) {
                case TaskProgressUpdate():
                  handleProgress(update);
                case TaskStatusUpdate():
                  await handleStatus(update);
              }
            });

        final enqueued = await FileDownloader().enqueue(task);
        if (!enqueued) {
          await finish(
            const DownloadProgress(
              phase: DownloadPhase.failed,
              fraction: 0,
              downloadedBytes: 0,
              errorMessage:
                  'could not start the download (insufficient space?)',
            ),
          );
        }
      } catch (error) {
        await finish(
          DownloadProgress(
            phase: DownloadPhase.failed,
            fraction: 0,
            downloadedBytes: 0,
            errorMessage: '$error',
          ),
        );
      }
    }

    controller
      ..onListen = start
      ..onCancel = () async {
        stallTimer?.cancel();
        await updatesSub?.cancel();
      };
    return controller.stream;
  }

  /// Atomic-rename `*.part` → final, only on a verified complete download (FR-011).
  Future<bool> _finalizeInstall() async {
    try {
      final part = await _partFile();
      if (!await part.exists()) return false;
      final finalFile = await _finalFile();
      if (await finalFile.exists()) await finalFile.delete();
      await part.rename(finalFile.path);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _deletePartial() async {
    try {
      final part = await _partFile();
      if (await part.exists()) await part.delete();
    } catch (_) {
      // best-effort cleanup
    }
  }

  @override
  Future<void> cancel() async {
    final id = _taskId;
    if (id != null) {
      await FileDownloader().cancelTaskWithId(id);
    }
    await _deletePartial();
  }

  @override
  Future<String?> installedModelPath() async {
    final file = await _finalFile();
    return await file.exists() ? file.path : null;
  }

  @override
  Future<int?> installedSizeBytes() async {
    final file = await _finalFile();
    return await file.exists() ? await file.length() : null;
  }

  @override
  Future<void> deleteModel() async {
    final file = await _finalFile();
    if (await file.exists()) await file.delete();
    await _deletePartial();
  }
}

/// App-wide [ModelDownloader].
final modelDownloaderProvider = Provider<ModelDownloader>((ref) {
  return BackgroundModelDownloader();
});
