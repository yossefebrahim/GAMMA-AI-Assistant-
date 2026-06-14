import 'dart:async';
import 'dart:io';

import 'package:ai_assistant/core/model_catalog.dart';
import 'package:ai_assistant/domain/services/model_downloader.dart';
import 'package:path_provider/path_provider.dart';

/// macOS / desktop [ModelDownloader] (007 macOS support, FR-006).
///
/// `background_downloader` has NO macOS implementation, so there is no in-app network download on
/// desktop (calling it would throw `MissingPluginException`). The sanctioned acquisition route on
/// macOS is **user file-import** (constitution v2.1.0 Principle VIII): the user supplies a
/// `.litertlm` model file. Until the in-app file picker lands (a `file_selector` follow-up), this
/// downloader:
///
/// * adopts an already-present model from the app-support models directory (the reinstall
///   fast-path in `DownloadController.start` calls [installedModelPath] before [download]); and
/// * returns an honest, NON-crashing guidance message from [download] instead of calling the
///   absent plugin.
///
/// Storage is `getApplicationSupportDirectory()/models/` (NOT Documents): a `.litertlm` in a
/// cloud-synced Documents folder can break LiteRT-LM's FFI `mmap` (flutter_gemma CHANGELOG 0.15.1
/// moved desktop model storage to Application Support for exactly this reason).
class DesktopModelDownloader implements ModelDownloader {
  Future<Directory> _modelsDir() async {
    final base = await getApplicationSupportDirectory();
    return Directory('${base.path}/${ModelCatalog.directory}');
  }

  Future<File> _finalFile() async =>
      File('${(await _modelsDir()).path}/${ModelCatalog.fileName}');

  @override
  Stream<DownloadProgress> download(String url) async* {
    final dir = await _modelsDir();
    await dir.create(recursive: true);
    yield DownloadProgress(
      phase: DownloadPhase.failed,
      fraction: 0,
      downloadedBytes: 0,
      errorMessage:
          'on macOS, place a gemma 4 e2b ".litertlm" model file at '
          '"${dir.path}/${ModelCatalog.fileName}" and retry. in-app import is coming.',
    );
  }

  @override
  Future<void> cancel() async {
    // Nothing to cancel — there is no in-flight transfer on desktop.
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
  }
}
