import 'dart:io';
import 'dart:typed_data';

import 'package:ai_assistant/core/media_file_extension.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

/// Stores sent-image **bytes as files** under app-private `…/images/` (never as DB BLOBs — R5).
/// The database holds only the path ([ImageAttachment.path]); these files inherit the same OS
/// file-based encryption as the database (FR-024). All I/O is local — no network (Principle I).
///
/// The documents directory is injectable so repository/store tests run against a temp dir with no
/// device (`ImageFileStore(documentsDirectory: () async => Directory(tmp))`).
class ImageFileStore {
  ImageFileStore({Future<Directory> Function()? documentsDirectory})
      : _documentsDirectory = documentsDirectory ?? getApplicationDocumentsDirectory;

  final Future<Directory> Function() _documentsDirectory;

  /// Subdirectory under the documents dir that holds image files.
  static const String subdirectory = 'images';

  /// Maximum accepted image size — mirrors flutter_gemma's `ImageProcessor` 10 MB cap (R4). An
  /// oversized pick is rejected here, before any model call, with a "pick another" path (FR-021).
  static const int maxBytes = 10 * 1024 * 1024;

  /// Disambiguates two files persisted within the same microsecond.
  int _counter = 0;

  Future<Directory> _imagesDir() async {
    final docs = await _documentsDirectory();
    final dir = Directory('${docs.path}/$subdirectory');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// Copy the picker temp file at [tempPath] into app-private `images/` and return the absolute
  /// stored path. Optionally force a file [extension] (e.g. `.jpg`); otherwise it is inferred from
  /// [tempPath]. Rejects an empty file or one larger than [maxBytes] with an [ArgumentError] so the
  /// caller can surface "pick another" (FR-021) — no partial copy is left behind.
  Future<String> persist(String tempPath, {String? extension}) async {
    final source = File(tempPath);
    final length = await source.length();
    if (length == 0) {
      throw ArgumentError.value(tempPath, 'tempPath', 'image file is empty');
    }
    if (length > maxBytes) {
      throw ArgumentError.value(
        tempPath,
        'tempPath',
        'image is $length bytes, exceeds the $maxBytes-byte limit',
      );
    }
    final dir = await _imagesDir();
    // Extension policy lives in the ONE shared helper (002 audit L5, adopted by 003).
    final ext = extension ?? mediaFileExtension(path: tempPath, fallback: '.jpg');
    final name = '${DateTime.now().microsecondsSinceEpoch}_${_counter++}$ext';
    final dest = '${dir.path}/$name';
    await source.copy(dest);
    return dest;
  }

  /// Read the bytes of a stored image just-in-time for `generate`/replay (Principle VIII — bytes
  /// are not retained between turns).
  Future<Uint8List> readBytes(String storedPath) => File(storedPath).readAsBytes();

  /// Delete the given stored image files (FR-019). Missing files are ignored so cleanup is
  /// idempotent.
  Future<void> deleteAll(Iterable<String> storedPaths) async {
    for (final path in storedPaths) {
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
      }
    }
  }

}

/// App-wide [ImageFileStore]. Overridable in tests with a temp-dir-backed store.
final imageFileStoreProvider = Provider<ImageFileStore>((ref) => ImageFileStore());
