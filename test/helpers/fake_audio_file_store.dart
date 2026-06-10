import 'dart:typed_data';

import 'package:ai_assistant/data/audio/audio_file_store.dart';

/// In-memory [AudioFileStore] for WIDGET tests: flutter_test's fake-async zone never completes
/// real file-I/O futures, so the store's persist/read/delete are replaced with map operations.
/// Unit/repository tests use the real store against a temp dir instead.
class FakeAudioFileStore extends AudioFileStore {
  final Map<String, Uint8List> stored = <String, Uint8List>{};
  int _seq = 0;

  /// Paths handed to [deleteAll], for cleanup assertions.
  final List<String> deleted = <String>[];

  @override
  Future<String> persist(String tempPath, {String? mimeType}) async {
    final path = '/fake/audio/${_seq++}.wav';
    stored[path] = Uint8List.fromList(List<int>.filled(64044, 7));
    return path;
  }

  @override
  Future<Uint8List> readBytes(String storedPath) async => stored[storedPath]!;

  @override
  Future<void> deleteAll(Iterable<String> storedPaths) async {
    for (final path in storedPaths) {
      deleted.add(path);
      stored.remove(path);
    }
  }
}
