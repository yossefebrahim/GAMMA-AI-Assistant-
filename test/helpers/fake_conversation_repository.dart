import 'dart:async';

import 'package:ai_assistant/domain/entities/conversation.dart';
import 'package:ai_assistant/domain/entities/image_attachment.dart';
import 'package:ai_assistant/domain/entities/message.dart';
import 'package:ai_assistant/domain/repositories/conversation_repository.dart';

/// Lightweight in-memory [ConversationRepository] for controller tests (contract:
/// conversation_repository.md "Controller tests"). Mirrors the drift repository's observable
/// behavior — reactive streams, title derivation, sequencing, cascade delete — without SQLite.
class FakeConversationRepository implements ConversationRepository {
  final Map<int, Conversation> _conversations = <int, Conversation>{};
  final Map<int, List<Message>> _messages = <int, List<Message>>{};
  int _conversationSeq = 0;
  int _messageSeq = 0;

  final StreamController<List<Conversation>> _conversationsController =
      StreamController<List<Conversation>>.broadcast();
  final Map<int, StreamController<List<Message>>> _messageControllers =
      <int, StreamController<List<Message>>>{};

  static const int maxTitleLength = 40;
  static const String fallbackTitle = 'untitled';
  static const String imageOnlyTitle = 'image';

  /// Stored paths handed to [deleteConversation] — lets tests assert image cleanup (FR-019).
  final List<String> deletedImagePaths = <String>[];

  DateTime _now() => DateTime.now().toUtc();

  List<Conversation> _sortedConversations() {
    return _conversations.values.toList()
      ..sort((a, b) {
        final byUpdated = b.updatedAt.compareTo(a.updatedAt);
        return byUpdated != 0 ? byUpdated : b.id.compareTo(a.id);
      });
  }

  void _emitConversations() => _conversationsController.add(_sortedConversations());

  void _emitMessages(int conversationId) {
    final controller = _messageControllers[conversationId];
    controller?.add(List<Message>.unmodifiable(_messages[conversationId] ?? const <Message>[]));
  }

  String _deriveTitle(String firstMessage) {
    final trimmed = firstMessage.trim();
    if (trimmed.isEmpty) return fallbackTitle;
    return trimmed.length <= maxTitleLength
        ? trimmed
        : trimmed.substring(0, maxTitleLength).trimRight();
  }

  @override
  Stream<List<Conversation>> watchConversations() {
    scheduleMicrotask(_emitConversations);
    return _conversationsController.stream;
  }

  @override
  Stream<List<Message>> watchMessages(int conversationId) {
    final controller = _messageControllers.putIfAbsent(
      conversationId,
      () => StreamController<List<Message>>.broadcast(),
    );
    scheduleMicrotask(() => _emitMessages(conversationId));
    return controller.stream;
  }

  @override
  Future<Conversation> createConversation() async {
    final now = _now();
    final id = ++_conversationSeq;
    final conversation = Conversation(id: id, title: null, createdAt: now, updatedAt: now);
    _conversations[id] = conversation;
    _messages[id] = <Message>[];
    _emitConversations();
    return conversation;
  }

  @override
  Future<Message> appendUserMessage(
    int conversationId,
    String text, {
    ImageAttachment? image,
  }) async {
    final trimmed = text.trim();
    // Valid with text OR an image (FR-004); only both-empty is rejected.
    if (trimmed.isEmpty && image == null) {
      throw ArgumentError.value(
        text,
        'text',
        'User message must have non-empty text or an image',
      );
    }
    final now = _now();
    final list = _messages[conversationId] ??= <Message>[];
    final message = Message(
      id: ++_messageSeq,
      conversationId: conversationId,
      role: MessageRole.user,
      content: trimmed,
      sequence: list.length,
      createdAt: now,
      status: MessageStatus.complete,
      image: image,
    );
    list.add(message);

    final conversation = _conversations[conversationId]!;
    final derivedTitle = trimmed.isNotEmpty ? _deriveTitle(trimmed) : imageOnlyTitle;
    _conversations[conversationId] = conversation.copyWith(
      title: conversation.title ?? derivedTitle,
      updatedAt: now,
    );
    _emitMessages(conversationId);
    _emitConversations();
    return message;
  }

  @override
  Future<int> beginAssistantMessage(int conversationId) async {
    final now = _now();
    final list = _messages[conversationId] ??= <Message>[];
    final id = ++_messageSeq;
    list.add(
      Message(
        id: id,
        conversationId: conversationId,
        role: MessageRole.assistant,
        content: '',
        sequence: list.length,
        createdAt: now,
        status: MessageStatus.streaming,
      ),
    );
    final conversation = _conversations[conversationId]!;
    _conversations[conversationId] = conversation.copyWith(updatedAt: now);
    _emitMessages(conversationId);
    _emitConversations();
    return id;
  }

  @override
  Future<void> updateAssistantContent(int messageId, String content) async {
    _mutateMessage(messageId, (m) => m.copyWith(content: content));
  }

  @override
  Future<void> finalizeAssistantMessage(int messageId, MessageStatus status) async {
    final conversationId = _mutateMessage(messageId, (m) => m.copyWith(status: status));
    if (conversationId != null) {
      final conversation = _conversations[conversationId]!;
      _conversations[conversationId] = conversation.copyWith(updatedAt: _now());
      _emitConversations();
    }
  }

  /// Apply [transform] to the message with [messageId]; returns its conversation id (or null).
  int? _mutateMessage(int messageId, Message Function(Message) transform) {
    for (final entry in _messages.entries) {
      final index = entry.value.indexWhere((m) => m.id == messageId);
      if (index != -1) {
        entry.value[index] = transform(entry.value[index]);
        _emitMessages(entry.key);
        return entry.key;
      }
    }
    return null;
  }

  @override
  Future<List<Message>> loadTurns(int conversationId) async {
    return List<Message>.unmodifiable(_messages[conversationId] ?? const <Message>[]);
  }

  @override
  Future<void> deleteConversation(int conversationId) async {
    // Record image paths so tests can assert file cleanup (FR-019), then drop the conversation.
    final removed = _messages[conversationId] ?? const <Message>[];
    for (final message in removed) {
      final path = message.image?.path;
      if (path != null) deletedImagePaths.add(path);
    }
    _conversations.remove(conversationId);
    _messages.remove(conversationId);
    _emitMessages(conversationId);
    _emitConversations();
  }

  /// Close all stream controllers. Call from a test `tearDown`.
  Future<void> dispose() async {
    await _conversationsController.close();
    for (final controller in _messageControllers.values) {
      await controller.close();
    }
  }
}
