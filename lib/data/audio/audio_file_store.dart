import 'dart:io';
import 'dart:typed_data';

import 'package:ai_assistant/core/audio_constants.dart';
import 'package:ai_assistant/core/media_file_extension.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

/// Stores sent-clip **bytes as files** under app-private `…/audio/` (never as DB BLOBs — 003 R6).
/// Mirrors `ImageFileStore`: the database holds only the path (`AudioAttachment.path`); these
/// files inherit the same OS file-based encryption as the database. All I/O is local — no network
/// (Principle I). Copy-in happens at **send only** (the recorder temp file stays composer-owned
/// until then); reads are just-in-time for generate/replay (Principle VIII).
///
/// The documents directory is injectable so repository/store tests run against a temp dir with no
/// device (`AudioFileStore(documentsDirectory: () async => Directory(tmp))`).
class AudioFileStore {
  AudioFileStore({Future<Directory> Function()? documentsDirectory})
      : _documentsDirectory = documentsDirectory ?? getApplicationDocumentsDirectory;

  final Future<Directory> Function() _documentsDirectory;

  /// Subdirectory under the documents dir that holds audio files (data-model.md §3).
  static const String subdirectory = 'audio';

  /// Maximum accepted clip size — double margin over a max-length 30 s clip (research R3). An
  /// oversized clip is rejected here, before any model call, with a "record again" path.
  static const int maxBytes = AudioConstants.maxPersistedBytes;

  /// Disambiguates two files persisted within the same microsecond (write-once naming:
  /// `<microsecondsSinceEpoch>_<seq>.wav`).
  int _counter = 0;

  Future<Directory> _audioDir() async {
    final docs = await _documentsDirectory();
    final dir = Directory('${docs.path}/$subdirectory');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// Copy the recorder temp file at [tempPath] into app-private `audio/` and return the absolute
  /// stored path. The extension derives from [mimeType] via the shared helper (002 audit L5),
  /// defaulting to `.wav`. Rejects an empty file or one larger than [maxBytes] with an
  /// [ArgumentError] so the caller can surface "record again" — no partial copy is left behind.
  Future<String> persist(String tempPath, {String? mimeType}) async {
    final source = File(tempPath);
    final length = await source.length();
    if (length == 0) {
      throw ArgumentError.value(tempPath, 'tempPath', 'audio file is empty');
    }
    if (length > maxBytes) {
      throw ArgumentError.value(
        tempPath,
        'tempPath',
        'clip is $length bytes, exceeds the $maxBytes-byte limit',
      );
    }
    final dir = await _audioDir();
    final ext = mediaFileExtension(mimeType: mimeType, path: tempPath, fallback: '.wav');
    final name = '${DateTime.now().microsecondsSinceEpoch}_${_counter++}$ext';
    final dest = '${dir.path}/$name';
    await source.copy(dest);
    return dest;
  }

  /// Read the bytes of a stored clip just-in-time for `generate`/replay (Principle VIII — bytes
  /// are not retained between turns).
  Future<Uint8List> readBytes(String storedPath) => File(storedPath).readAsBytes();

  /// Delete the given stored audio files (delete-cleans-files). Missing files are ignored so
  /// cleanup is idempotent.
  Future<void> deleteAll(Iterable<String> storedPaths) async {
    for (final path in storedPaths) {
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
      }
    }
  }
}

/// App-wide [AudioFileStore]. Overridable in tests with a temp-dir-backed store.
final audioFileStoreProvider = Provider<AudioFileStore>((ref) => AudioFileStore());
