# Contract: ModelDownloader

**Feature**: `001-model-download-chat` | FR-002, FR-007–FR-011, Principle IV/VIII

Abstraction over `background_downloader` (R2). The only seam for fetching the model file. A
concrete `BackgroundModelDownloader` (in `lib/data/model/`) is the only file importing
`background_downloader`; controllers depend on this interface and test with a fake.

## Interface

```dart
enum DownloadPhase { idle, running, paused, completed, canceled, failed }

class DownloadProgress {
  final DownloadPhase phase;
  final double fraction;        // 0.0–1.0 (FR-007 percent)
  final int downloadedBytes;    // (FR-007 size)
  final int? totalBytes;        // expectedFileSize when known
  final bool stalled;           // true when no bytes for >1s (SC-002 stall indication)
  final String? errorMessage;
}

abstract interface class ModelDownloader {
  /// Begin (or resume) downloading the model from [url] into app-private storage.
  /// Emits progress at least once per second while active (SC-002). Non-blocking:
  /// continues while the app is used, under an Android foreground service (Principle IV).
  Stream<DownloadProgress> download(String url);

  /// Cancel the in-flight download within 2s (FR-008/SC-003); discards the partial file.
  Future<void> cancel();

  /// Absolute path of the VERIFIED model file, or null if not installed.
  /// Returns a path only after atomic rename of *.part → *.litertlm (FR-011 integrity).
  Future<String?> installedModelPath();

  /// Delete the downloaded model file and report freed bytes (FR-030).
  Future<void> deleteModel();

  /// On-disk size of the installed model in bytes (FR-030), or null.
  Future<int?> installedSizeBytes();
}
```

## Semantics & guarantees

| # | Behavior | Source |
|---|----------|--------|
| 1 | Progress stream yields percent + bytes ≥ 1×/sec; indicates `stalled` instead of freezing. | FR-007, SC-002 |
| 2 | Download runs in a foreground service; survives navigating the app; never freezes UI. | FR-009, Principle IV |
| 3 | `cancel()` stops within 2s and removes the `*.part` file — no usable model remains. | FR-008, SC-003 |
| 4 | A partial/interrupted file is never exposed via `installedModelPath()`; only a fully downloaded (and optionally checksum-verified) file is atomic-renamed and returned. | FR-011 |
| 5 | Failure/interruption surfaces via `phase == failed` with a message; a subsequent `download()` resumes (best-effort) or restarts cleanly. | FR-011 |
| 6 | File lives in app-private storage (`applicationDocuments/models`) — OS-encrypted, no storage permission. | FR-032, R2 |
| 7 | Free-space checked before starting; insufficient space → `failed`, no partial corruption. | Edge: storage full |

## Concrete mapping (background_downloader 9.5.5)

- `download` → `DownloadTask(url, filename:'gemma-4-e2b.litertlm.part', baseDirectory: applicationDocuments, directory:'models', updates: statusAndProgress, allowPause:true, retries:5)`; `enqueue`; map `FileDownloader().updates` → `DownloadProgress`.
- Foreground: `configure(globalConfig:[(Config.runInForegroundIfFileLargerThan,256)])`; runtime `POST_NOTIFICATIONS`.
- `cancel` → `cancelTaskWithId(taskId)`.
- Integrity: on `TaskStatus.complete`, optional SHA-256, then atomic rename `.part` → `.litertlm`.
- `deleteModel` → delete file; report reclaimed bytes.

## Test double — `FakeModelDownloader`

Emits a scripted progress sequence (controllable rate, stall, cancel, fail, complete); `cancel`
flips to `canceled` and clears the fake path; `installedModelPath` returns non-null only after a
scripted "complete". Enables controller tests for progress UI, cancel-within-2s, and
partial-never-usable — with no network and no native plugin.
