import 'dart:io';
import 'dart:typed_data';

import 'package:ai_assistant/data/images/image_file_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// US6 store guard (FR-021) — `ImageFileStore.persist` rejects empty and oversized images and leaves
/// no partial copy, accepts at the limit, and round-trips bytes. Temp-dir backed; no device.
void main() {
  late Directory tempDir;
  late ImageFileStore store;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('image_store_');
    store = ImageFileStore(documentsDirectory: () async => tempDir);
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Directory imagesDir() => Directory('${tempDir.path}/${ImageFileStore.subdirectory}');

  test('rejects an image larger than maxBytes and leaves no partial copy (FR-021)', () async {
    final big = File('${tempDir.path}/big.jpg')
      ..writeAsBytesSync(Uint8List(ImageFileStore.maxBytes + 1));

    await expectLater(() => store.persist(big.path), throwsA(isA<ArgumentError>()));

    // Nothing was copied into the app-private images/ directory.
    final dir = imagesDir();
    expect(dir.existsSync() ? dir.listSync() : const <FileSystemEntity>[], isEmpty);
  });

  test('accepts an image exactly at maxBytes (boundary)', () async {
    final atLimit = File('${tempDir.path}/limit.jpg')
      ..writeAsBytesSync(Uint8List(ImageFileStore.maxBytes));

    final stored = await store.persist(atLimit.path);

    expect(File(stored).existsSync(), isTrue);
    expect(File(stored).lengthSync(), ImageFileStore.maxBytes);
    expect(stored, contains('/${ImageFileStore.subdirectory}/'));
  });

  test('rejects an empty file and leaves no partial copy (FR-021)', () async {
    final empty = File('${tempDir.path}/empty.jpg')..writeAsBytesSync(<int>[]);

    await expectLater(() => store.persist(empty.path), throwsA(isA<ArgumentError>()));

    final dir = imagesDir();
    expect(dir.existsSync() ? dir.listSync() : const <FileSystemEntity>[], isEmpty);
  });

  test('persists a valid image, reads its bytes back, and deletes it (FR-018/FR-019)', () async {
    final bytes = Uint8List.fromList([10, 20, 30, 40, 50]);
    final src = File('${tempDir.path}/ok.jpg')..writeAsBytesSync(bytes);

    final stored = await store.persist(src.path, extension: '.jpg');
    expect(await store.readBytes(stored), equals(bytes));

    await store.deleteAll([stored]);
    expect(File(stored).existsSync(), isFalse);
    // deleteAll is idempotent — a second delete of a missing file is a no-op.
    await store.deleteAll([stored]);
  });
}
