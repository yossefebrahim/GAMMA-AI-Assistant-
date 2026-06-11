import 'dart:async';

import 'package:ai_assistant/domain/entities/audio_attachment.dart';
import 'package:ai_assistant/domain/entities/conversation.dart';
import 'package:ai_assistant/domain/entities/image_attachment.dart';
import 'package:ai_assistant/domain/entities/message.dart';
import 'package:ai_assistant/domain/entities/tool_outcome.dart';
import 'package:ai_assistant/domain/entities/tool_spec.dart';
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
  static const String audioOnlyTitle = 'voice clip';

  /// Stored paths handed to [deleteConversation] — lets tests assert image cleanup (FR-019).
  final List<String> deletedImagePaths = <String>[];

  /// Stored audio paths handed to [deleteConversation] — lets tests assert clip cleanup (003).
  final List<String> deletedAudioPaths = <String>[];

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
    AudioAttachment? audio,
  }) async {
    // One attachment per message — audio XOR image (003 spec Q3), mirroring the drift repo.
    if (image != null && audio != null) {
      throw ArgumentError.value(
        audio,
        'audio',
        'A user message carries at most one attachment (audio XOR image)',
      );
    }
    final trimmed = text.trim();
    // Valid with text OR an attachment (FR-004); only all-empty is rejected.
    if (trimmed.isEmpty && image == null && audio == null) {
      throw ArgumentError.value(
        text,
        'text',
        'User message must have non-empty text or an attachment',
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
      audio: audio,
    );
    list.add(message);

    final conversation = _conversations[conversationId]!;
    final derivedTitle = trimmed.isNotEmpty
        ? _deriveTitle(trimmed)
        : (audio != null ? audioOnlyTitle : imageOnlyTitle);
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
  Future<void> deleteMessage(int messageId) async {
    for (final entry in _messages.entries) {
      final index = entry.value.indexWhere((m) => m.id == messageId);
      if (index != -1) {
        entry.value.removeAt(index);
        _emitMessages(entry.key);
        return;
      }
    }
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
  Future<int> appendToolInvocation({
    required int conversationId,
    required String toolName,
    required Map<String, Object?> args,
  }) async {
    if (toolName.trim().isEmpty) {
      throw ArgumentError.value(toolName, 'toolName', 'A tool row must carry a tool name');
    }
    final now = _now();
    final list = _messages[conversationId] ??= <Message>[];
    final id = ++_messageSeq;
    list.add(
      Message(
        id: id,
        conversationId: conversationId,
        role: MessageRole.tool,
        content: '',
        sequence: list.length,
        createdAt: now,
        status: MessageStatus.complete,
        toolName: toolName,
        toolArgs: Map<String, Object?>.of(args),
        toolStatus: ToolCallStatus.running,
      ),
    );
    final conversation = _conversations[conversationId]!;
    _conversations[conversationId] = conversation.copyWith(updatedAt: now);
    _emitMessages(conversationId);
    _emitConversations();
    return id;
  }

  @override
  Future<void> finalizeToolInvocation(
    int messageId, {
    required ToolCallStatus status,
    Map<String, Object?>? result,
    required String summary,
  }) async {
    if (status == ToolCallStatus.running) {
      throw ArgumentError.value(
          status, 'status', 'finalizeToolInvocation accepts terminal states only');
    }
    // Mirror the drift repo's ceiling check on the encoded length (contract guarantee 4).
    if (result != null &&
        result.toString().length > ToolSpec.clipboardResultCharBound * 2) {
      throw ArgumentError.value(result, 'result', 'tool result exceeds the ceiling');
    }
    final conversationId = _mutateMessage(
      messageId,
      (m) => m.copyWith(content: summary, toolStatus: status, toolResult: result),
    );
    if (conversationId != null) {
      final conversation = _conversations[conversationId]!;
      _conversations[conversationId] = conversation.copyWith(updatedAt: _now());
      _emitConversations();
    }
  }

  @override
  Future<int> sweepStaleToolInvocations() async {
    var swept = 0;
    for (final entry in _messages.entries) {
      for (var i = 0; i < entry.value.length; i++) {
        final m = entry.value[i];
        if (m.role == MessageRole.tool && m.toolStatus == ToolCallStatus.running) {
          entry.value[i] = m.copyWith(
            content: 'interrupted',
            toolStatus: ToolCallStatus.error,
            toolResult: const {'error': 'interrupted'},
          );
          swept++;
        }
      }
      _emitMessages(entry.key);
    }
    return swept;
  }

  @override
  Future<void> deleteConversation(int conversationId) async {
    // Record media paths so tests can assert file cleanup (FR-019 / 003), then drop the
    // conversation.
    final removed = _messages[conversationId] ?? const <Message>[];
    for (final message in removed) {
      final imagePath = message.image?.path;
      if (imagePath != null) deletedImagePaths.add(imagePath);
      final audioPath = message.audio?.path;
      if (audioPath != null) deletedAudioPaths.add(audioPath);
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
