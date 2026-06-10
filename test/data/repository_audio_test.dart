import 'dart:io';

import 'package:ai_assistant/core/audio_constants.dart';
import 'package:ai_assistant/data/audio/audio_file_store.dart';
import 'package:ai_assistant/data/db/app_database.dart';
import 'package:ai_assistant/data/images/image_file_store.dart';
import 'package:ai_assistant/data/repositories/drift_conversation_repository.dart';
import 'package:ai_assistant/domain/entities/audio_attachment.dart';
import 'package:ai_assistant/domain/entities/image_attachment.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_db.dart';

/// US5 repository audio persistence + cleanup (003 FR-018/FR-019) — REAL in-memory drift plus a
/// temp-dir [AudioFileStore]: round-trip through append/watch/loadTurns, the audio-XOR-image
/// validation, the audio-only fallback title, delete-cleans-audio-files, and the store's own
/// guards.
void main() {
  late AppDatabase db;
  late Directory docsDir;
  late AudioFileStore audioStore;
  late ImageFileStore imageStore;
  late DriftConversationRepository repo;
  late File recorderTemp;

  setUp(() {
    db = newTestDatabase();
    docsDir = Directory.systemTemp.createTempSync('repo_audio_docs_');
    audioStore = AudioFileStore(documentsDirectory: () async => docsDir);
    imageStore = ImageFileStore(documentsDirectory: () async => docsDir);
    repo = DriftConversationRepository(db, imageStore, audioStore);
    recorderTemp = File('${docsDir.path}/rec_temp.wav')
      ..writeAsBytesSync(List.filled(32044, 7));
  });

  tearDown(() async {
    await db.close();
    if (docsDir.existsSync()) docsDir.deleteSync(recursive: true);
  });

  group('repository', () {
    test('audio round-trips through appendUserMessage / watchMessages / loadTurns (FR-018)',
        () async {
      final conversation = await repo.createConversation();
      final storedPath = await audioStore.persist(recorderTemp.path, mimeType: 'audio/wav');

      await repo.appendUserMessage(conversation.id, 'what did i say',
          audio: AudioAttachment(path: storedPath, mimeType: 'audio/wav'));

      final watched = await repo.watchMessages(conversation.id).first;
      expect(watched.single.audio, isNotNull);
      expect(watched.single.audio!.path, storedPath);
      expect(watched.single.audio!.mimeType, 'audio/wav');

      final turns = await repo.loadTurns(conversation.id);
      expect(turns.single.audio!.path, storedPath);
      expect(turns.single.image, isNull);
    });

    test('image AND audio together are rejected (audio XOR image, spec Q3)', () async {
      final conversation = await repo.createConversation();

      expect(
        () => repo.appendUserMessage(
          conversation.id,
          'both',
          image: const ImageAttachment(path: '/images/x.jpg'),
          audio: const AudioAttachment(path: '/audio/x.wav'),
        ),
        throwsArgumentError,
      );
    });

    test('an audio-only first message gets the voice-clip fallback title (FR-021)', () async {
      final conversation = await repo.createConversation();
      final storedPath = await audioStore.persist(recorderTemp.path, mimeType: 'audio/wav');

      await repo.appendUserMessage(conversation.id, '',
          audio: AudioAttachment(path: storedPath, mimeType: 'audio/wav'));

      final conversations = await repo.watchConversations().first;
      expect(conversations.single.title, DriftConversationRepository.audioOnlyTitle);
    });

    test('an empty message with no attachment is still rejected (FR-004)', () async {
      final conversation = await repo.createConversation();

      expect(
        () => repo.appendUserMessage(conversation.id, '   '),
        throwsArgumentError,
      );
    });

    test('deleteConversation deletes audio files BEFORE the cascade — no orphans (FR-019)',
        () async {
      final conversation = await repo.createConversation();
      final storedPath = await audioStore.persist(recorderTemp.path, mimeType: 'audio/wav');
      await repo.appendUserMessage(conversation.id, 'hear this',
          audio: AudioAttachment(path: storedPath, mimeType: 'audio/wav'));
      expect(File(storedPath).existsSync(), isTrue);

      await repo.deleteConversation(conversation.id);

      expect(File(storedPath).existsSync(), isFalse, reason: 'audio file removed');
      final conversations = await repo.watchConversations().first;
      expect(conversations, isEmpty);
    });
  });

  group('AudioFileStore', () {
    test('persist copies into audio/ with a wav name; readBytes returns the bytes', () async {
      final storedPath = await audioStore.persist(recorderTemp.path, mimeType: 'audio/wav');

      expect(storedPath, contains('/${AudioFileStore.subdirectory}/'));
      expect(storedPath, endsWith('.wav'),
          reason: 'extension from mimeType via the shared helper (002 L5)');
      expect(File(storedPath).existsSync(), isTrue);
      expect(recorderTemp.existsSync(), isTrue, reason: 'persist copies, never moves');

      final bytes = await audioStore.readBytes(storedPath);
      expect(bytes.length, 32044);
    });

    test('persist rejects an empty file (ArgumentError)', () async {
      final empty = File('${docsDir.path}/empty.wav')..writeAsBytesSync(const []);

      expect(() => audioStore.persist(empty.path), throwsArgumentError);
    });

    test('persist rejects a file over the 2 MiB guard (ArgumentError, R3)', () async {
      final oversized = File('${docsDir.path}/big.wav')
        ..writeAsBytesSync(List.filled(AudioConstants.maxPersistedBytes + 1, 0));

      expect(() => audioStore.persist(oversized.path), throwsArgumentError);
    });

    test('deleteAll is idempotent — missing files are ignored', () async {
      final storedPath = await audioStore.persist(recorderTemp.path, mimeType: 'audio/wav');

      await audioStore.deleteAll([storedPath, '/nonexistent/gone.wav']);
      // A second pass over already-deleted paths is fine.
      await audioStore.deleteAll([storedPath]);

      expect(File(storedPath).existsSync(), isFalse);
    });

    test('duration derives from WAV byte length: (bytes − 44) / 32000 s (data-model §1)', () {
      // 32044 bytes = 44-byte header + 32000 payload = exactly 1 s.
      expect(AudioConstants.durationFromBytes(32044), const Duration(seconds: 1));
      expect(AudioConstants.durationFromBytes(44), Duration.zero);
      expect(AudioConstants.durationFromBytes(0), Duration.zero, reason: 'degenerate clamps');
      expect(AudioConstants.durationFromBytes(16044), const Duration(milliseconds: 500));
    });
  });
}
