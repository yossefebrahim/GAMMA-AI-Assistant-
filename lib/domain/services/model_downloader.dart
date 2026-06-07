import 'package:meta/meta.dart';

/// Lifecycle phase of the model download.
enum DownloadPhase { idle, running, paused, completed, canceled, failed }

/// A single progress emission from [ModelDownloader.download] (FR-007 — percent + bytes).
@immutable
class DownloadProgress {
  const DownloadProgress({
    required this.phase,
    required this.fraction,
    required this.downloadedBytes,
    this.totalBytes,
    this.stalled = false,
    this.errorMessage,
  });

  final DownloadPhase phase;

  /// 0.0–1.0 (FR-007 percent).
  final double fraction;

  /// Bytes written so far (FR-007 size).
  final int downloadedBytes;

  /// Expected total when known.
  final int? totalBytes;

  /// True when no bytes have arrived for >1s — shown instead of a frozen bar (SC-002).
  final bool stalled;

  final String? errorMessage;

  @override
  bool operator ==(Object other) =>
      other is DownloadProgress &&
      other.phase == phase &&
      other.fraction == fraction &&
      other.downloadedBytes == downloadedBytes &&
      other.totalBytes == totalBytes &&
      other.stalled == stalled &&
      other.errorMessage == errorMessage;

  @override
  int get hashCode =>
      Object.hash(phase, fraction, downloadedBytes, totalBytes, stalled, errorMessage);
}

/// Abstraction over `background_downloader` (R2) — the only seam for fetching the model file.
///
/// The concrete `BackgroundModelDownloader` (in `lib/data/model/`) is the only file importing
/// `background_downloader`; controllers depend on this interface and test with `FakeModelDownloader`.
/// See `specs/001-model-download-chat/contracts/model_download.md`.
abstract interface class ModelDownloader {
  /// Begin (or resume) downloading the model from [url] into app-private storage. Emits progress
  /// at least once per second while active (SC-002). Non-blocking: continues while the app is
  /// used, under an Android foreground service (Principle IV).
  Stream<DownloadProgress> download(String url);

  /// Cancel the in-flight download within 2s (FR-008/SC-003); discards the partial file.
  Future<void> cancel();

  /// Absolute path of the VERIFIED model file, or `null` if not installed. Returns a path only
  /// after the atomic rename of `*.part` → `*.litertlm` (FR-011 integrity).
  Future<String?> installedModelPath();

  /// Delete the downloaded model file (FR-030).
  Future<void> deleteModel();

  /// On-disk size of the installed model in bytes (FR-030), or `null`.
  Future<int?> installedSizeBytes();
}
