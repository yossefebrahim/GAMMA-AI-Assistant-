import 'package:ai_assistant/data/audio/audio_file_store.dart';
import 'package:ai_assistant/data/db/app_database.dart';
import 'package:ai_assistant/data/images/image_file_store.dart';
import 'package:ai_assistant/domain/entities/audio_attachment.dart';
import 'package:ai_assistant/domain/entities/conversation.dart';
import 'package:ai_assistant/domain/entities/image_attachment.dart';
import 'package:ai_assistant/domain/entities/message.dart';
import 'package:ai_assistant/domain/repositories/conversation_repository.dart';
import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// drift-backed [ConversationRepository] (R3). All time is stored in UTC; ordering ties break on
/// id so the reactive history list is deterministic. Image and audio bytes live as app-private
/// files via [ImageFileStore]/[AudioFileStore]; only the paths are persisted in the `messages`
/// table (002 R5 / 003 R6).
class DriftConversationRepository implements ConversationRepository {
  DriftConversationRepository(this._db, this._imageStore, this._audioStore);

  final AppDatabase _db;
  final ImageFileStore _imageStore;
  final AudioFileStore _audioStore;
  ConversationDao get _dao => _db.conversationDao;

  /// Max derived title length (FR-021).
  static const int maxTitleLength = 40;

  /// Fallback when a first message is empty after trimming (FR-021). User messages are rejected
  /// when empty (and attachment-less), so this is a defensive default rather than a common path.
  static const String fallbackTitle = 'untitled';

  /// Title for an image-only first message (no text to derive from) — FR-021 fallback.
  static const String imageOnlyTitle = 'image';

  /// Title for an audio-only first message (003 — the voice-clip counterpart of [imageOnlyTitle]).
  static const String audioOnlyTitle = 'voice clip';

  static DateTime _now() => DateTime.now().toUtc();

  Conversation _toConversation(ConversationRow r) => Conversation(
        id: r.id,
        title: r.title,
        createdAt: r.createdAt,
        updatedAt: r.updatedAt,
      );

  Message _toMessage(MessageRow r) => Message(
        id: r.id,
        conversationId: r.conversationId,
        role: MessageRole.values.byName(r.role),
        content: r.content,
        sequence: r.sequence,
        createdAt: r.createdAt,
        status: MessageStatus.values.byName(r.status),
        image: r.imagePath == null
            ? null
            : ImageAttachment(path: r.imagePath!, mimeType: r.imageMimeType),
        audio: r.audioPath == null
            ? null
            : AudioAttachment(path: r.audioPath!, mimeType: r.audioMimeType),
      );

  String _deriveTitle(String firstMessage) {
    final trimmed = firstMessage.trim();
    if (trimmed.isEmpty) return fallbackTitle;
    if (trimmed.length <= maxTitleLength) return trimmed;
    return trimmed.substring(0, maxTitleLength).trimRight();
  }

  @override
  Stream<List<Conversation>> watchConversations() =>
      _dao.watchConversations().map((rows) => rows.map(_toConversation).toList());

  @override
  Stream<List<Message>> watchMessages(int conversationId) =>
      _dao.watchMessages(conversationId).map((rows) => rows.map(_toMessage).toList());

  @override
  Future<Conversation> createConversation() async {
    final now = _now();
    final id = await _dao.insertConversation(
      ConversationsCompanion.insert(createdAt: now, updatedAt: now),
    );
    return Conversation(id: id, title: null, createdAt: now, updatedAt: now);
  }

  @override
  Future<Message> appendUserMessage(
    int conversationId,
    String text, {
    ImageAttachment? image,
    AudioAttachment? audio,
  }) async {
    // One attachment per message — audio XOR image (003 spec Q3, contract #1).
    if (image != null && audio != null) {
      throw ArgumentError.value(
        audio,
        'audio',
        'A user message carries at most one attachment (audio XOR image)',
      );
    }
    final trimmed = text.trim();
    // A user turn is valid with text OR an attachment (FR-004); only all-empty is rejected.
    if (trimmed.isEmpty && image == null && audio == null) {
      throw ArgumentError.value(
        text,
        'text',
        'User message must have non-empty text or an attachment',
      );
    }
    final now = _now();
    final sequence = await _dao.nextSequence(conversationId);
    final messageId = await _dao.insertMessage(
      MessagesCompanion.insert(
        conversationId: conversationId,
        role: MessageRole.user.name,
        content: trimmed,
        sequence: sequence,
        createdAt: now,
        status: MessageStatus.complete.name,
        imagePath: Value(image?.path),
        imageMimeType: Value(image?.mimeType),
        audioPath: Value(audio?.path),
        audioMimeType: Value(audio?.mimeType),
      ),
    );

    // Set the title from the first user message if not already set (FR-021): from the text, or a
    // fallback label for an attachment-only first message.
    final conversation = await _dao.conversationById(conversationId);
    final newTitle = conversation.title != null
        ? null
        : (trimmed.isNotEmpty
            ? _deriveTitle(trimmed)
            : (audio != null ? audioOnlyTitle : imageOnlyTitle));
    await _dao.touchConversation(conversationId, now, title: newTitle);

    return _toMessage(await _dao.messageById(messageId));
  }

  @override
  Future<int> beginAssistantMessage(int conversationId) async {
    final now = _now();
    final sequence = await _dao.nextSequence(conversationId);
    final messageId = await _dao.insertMessage(
      MessagesCompanion.insert(
        conversationId: conversationId,
        role: MessageRole.assistant.name,
        content: '',
        sequence: sequence,
        createdAt: now,
        status: MessageStatus.streaming.name,
      ),
    );
    await _dao.touchConversation(conversationId, now);
    return messageId;
  }

  @override
  Future<void> updateAssistantContent(int messageId, String content) {
    return _dao.writeMessage(messageId, MessagesCompanion(content: Value(content)));
  }

  @override
  Future<void> finalizeAssistantMessage(int messageId, MessageStatus status) async {
    await _dao.writeMessage(messageId, MessagesCompanion(status: Value(status.name)));
    // Bump the parent conversation so the history list reflects the completed turn.
    final message = await _dao.messageById(messageId);
    await _dao.touchConversation(message.conversationId, _now());
  }

  @override
  Future<List<Message>> loadTurns(int conversationId) async {
    final rows = await _dao.messagesFor(conversationId);
    return rows.map(_toMessage).toList();
  }

  @override
  Future<void> deleteConversation(int conversationId) async {
    // Delete the conversation's media files BEFORE the row delete (FR-019; 003 contract #3) —
    // once the rows cascade away their paths are gone. Reads paths first, then removes files,
    // then drops the row.
    final rows = await _dao.messagesFor(conversationId);
    final imagePaths = rows
        .map((r) => r.imagePath)
        .whereType<String>()
        .toList(growable: false);
    if (imagePaths.isNotEmpty) {
      await _imageStore.deleteAll(imagePaths);
    }
    final audioPaths = rows
        .map((r) => r.audioPath)
        .whereType<String>()
        .toList(growable: false);
    if (audioPaths.isNotEmpty) {
      await _audioStore.deleteAll(audioPaths);
    }
    await _dao.deleteConversationById(conversationId);
  }
}

/// App-wide [ConversationRepository] backed by the drift database + the app-private media stores.
final conversationRepositoryProvider = Provider<ConversationRepository>((ref) {
  return DriftConversationRepository(
    ref.watch(appDatabaseProvider),
    ref.watch(imageFileStoreProvider),
    ref.watch(audioFileStoreProvider),
  );
});
