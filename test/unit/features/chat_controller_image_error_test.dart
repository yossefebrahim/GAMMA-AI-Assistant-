import 'dart:io';

import 'package:ai_assistant/data/images/image_file_store.dart';
import 'package:ai_assistant/data/repositories/drift_conversation_repository.dart';
import 'package:ai_assistant/domain/entities/message.dart';
import 'package:ai_assistant/domain/entities/model_capabilities.dart';
import 'package:ai_assistant/domain/repositories/conversation_repository.dart';
import 'package:ai_assistant/features/chat/attachment_controller.dart';
import 'package:ai_assistant/features/chat/chat_controller.dart';
import 'package:ai_assistant/features/chat/chat_providers.dart';
import 'package:ai_assistant/infrastructure/gemma/flutter_gemma_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/container_harness.dart';
import '../../helpers/fake_gemma_service.dart';

/// US6 honest failure (FR-014/FR-020, SC-008) — an unprocessable image is finalized cleanly with a
/// clear message (no hang); stop during an image-grounded reply retains the partial text.
void main() {
  late FakeGemmaService gemma;
  late Directory tempDir;
  late ProviderContainer container;

  setUp(() {
    gemma = FakeGemmaService();
    tempDir = Directory.systemTemp.createTempSync('chat_img_err_');
    container = makeContainer(
      overrides: [
        gemmaServiceProvider.overrideWithValue(gemma),
        imageFileStoreProvider.overrideWithValue(
          ImageFileStore(documentsDirectory: () async => tempDir),
        ),
        modelCapabilitiesProvider.overrideWith((ref) => const ModelCapabilities(image: true)),
      ],
    );
  });

  tearDown(() {
    container.dispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  ChatController controller() => container.read(chatControllerProvider.notifier);
  ChatState read() => container.read(chatControllerProvider);
  ConversationRepository repo() => container.read(conversationRepositoryProvider);

  PendingAttachment tempImage(String name, List<int> bytes) {
    final file = File('${tempDir.path}/$name')..writeAsBytesSync(bytes);
    return PendingAttachment(path: file.path, mimeType: 'image/jpeg');
  }

  test('ImageProcessingException finalizes the turn cleanly, resets isGenerating, and surfaces a '
      'clear message — no hang (FR-020, SC-008)', () async {
    gemma.throwImageProcessing = true;

    await controller().send('what is this', image: tempImage('bad.jpg', [1, 2, 3, 4]));

    expect(read().isGenerating, isFalse, reason: 'no hang — generation flag reset');
    expect(read().errorMessage, ChatController.imageErrorMessage);

    final turns = await repo().loadTurns(read().conversationId!);
    final assistant = turns.firstWhere((m) => m.role == MessageRole.assistant);
    expect(assistant.status, MessageStatus.stoppedPartial, reason: 'turn finalized cleanly');
  });

  test('dismissError clears the message and the conversation stays usable (FR-020)', () async {
    gemma.throwImageProcessing = true;
    await controller().send('bad', image: tempImage('b.jpg', [9, 9, 9]));
    expect(read().errorMessage, isNotNull);

    controller().dismissError();
    expect(read().errorMessage, isNull);

    // A subsequent text send works and the error stays cleared.
    gemma.throwImageProcessing = false;
    gemma.scriptedDeltas = ['hi again'];
    await controller().send('hello again');
    expect(read().errorMessage, isNull);
    final assistant = (await repo().loadTurns(read().conversationId!))
        .lastWhere((m) => m.role == MessageRole.assistant);
    expect(assistant.content, 'hi again');
  });

  test('stop during an image-grounded reply retains the partial text (FR-014)', () async {
    gemma
      ..scriptedDeltas = ['aa', 'bb', 'cc', 'dd', 'ee']
      ..deltaInterval = const Duration(milliseconds: 25);

    final sending = controller().send('describe', image: tempImage('img.jpg', [1, 2]));
    await Future<void>.delayed(const Duration(milliseconds: 40));
    await controller().stop();
    await sending;

    final assistant = (await repo().loadTurns(read().conversationId!))
        .firstWhere((m) => m.role == MessageRole.assistant);
    expect(assistant.status, MessageStatus.stoppedPartial);
    expect(assistant.content, isNotEmpty);
    expect(assistant.content.length, lessThan('aabbccddee'.length));
    expect(read().isGenerating, isFalse);
    expect(gemma.stopCount, 1);
  });
}
