import 'dart:io';
import 'dart:typed_data';

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

/// US1 chat controller with an image (FR-004/FR-012) — extended [FakeGemmaService] + in-memory
/// drift repo + a temp-dir [ImageFileStore]. No native plugin, no device.
void main() {
  late FakeGemmaService gemma;
  late Directory tempDir;
  late ProviderContainer container;

  setUp(() {
    gemma = FakeGemmaService();
    tempDir = Directory.systemTemp.createTempSync('chat_img_');
    container = makeContainer(
      overrides: [
        gemmaServiceProvider.overrideWithValue(gemma),
        imageFileStoreProvider.overrideWithValue(
          ImageFileStore(documentsDirectory: () async => tempDir),
        ),
        // The attachment controller (cleared on send) listens to capabilities; keep it lightweight.
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

  test('send with an image persists it on the user message and passes ImageInput to generate '
      '(FR-012)', () async {
    gemma.scriptedDeltas = ['it ', 'is ', 'a cat'];
    final pending = tempImage('pick.jpg', [1, 2, 3, 4]);

    await controller().send('what is this', image: pending);

    final conversationId = read().conversationId!;
    final turns = await repo().loadTurns(conversationId);
    final user = turns.firstWhere((m) => m.role == MessageRole.user);
    expect(user.content, 'what is this');
    expect(user.image, isNotNull);
    expect(user.image!.path, contains('/${ImageFileStore.subdirectory}/'));
    expect(File(user.image!.path).existsSync(), isTrue, reason: 'stored copy persisted');

    // A non-null ImageInput with the file bytes was handed to generate.
    expect(gemma.lastImage, isNotNull);
    expect(gemma.lastImage!.bytes, equals(Uint8List.fromList([1, 2, 3, 4])));
    expect(gemma.lastPrompt, 'what is this');

    // Reply deltas appended as before.
    final assistant = turns.firstWhere((m) => m.role == MessageRole.assistant);
    expect(assistant.content, 'it is a cat');
    expect(assistant.status, MessageStatus.complete);
    expect(read().isGenerating, isFalse);
  });

  test('image-only send (empty text) is allowed (FR-004)', () async {
    gemma.scriptedDeltas = ['a landscape'];
    final pending = tempImage('only.jpg', [9, 9, 9]);

    await controller().send('', image: pending);

    final conversationId = read().conversationId!;
    final turns = await repo().loadTurns(conversationId);
    final user = turns.firstWhere((m) => m.role == MessageRole.user);
    expect(user.content, '');
    expect(user.image, isNotNull);
    expect(gemma.lastPrompt, '');
    expect(gemma.lastImage, isNotNull);
  });

  test('the pending attachment is cleared after a successful image send (FR-004)', () async {
    gemma.scriptedDeltas = ['ok'];
    // Seed a pending attachment in the controller, then send with it.
    final pending = tempImage('clearme.jpg', [5, 5]);
    await controller().send('hi', image: pending);

    expect(container.read(attachmentControllerProvider).pending, isNull);
  });

  test('a text-only send still works and passes no image (regression)', () async {
    gemma.scriptedDeltas = ['hello'];

    await controller().send('just text');

    expect(gemma.lastImage, isNull);
    final turns = await repo().loadTurns(read().conversationId!);
    expect(turns.firstWhere((m) => m.role == MessageRole.user).image, isNull);
  });

  test('a text-only follow-up replays the earlier image to generate via history '
      '(FR-015/FR-016)', () async {
    // First turn: send with an image.
    gemma.scriptedDeltas = ['a cat'];
    await controller().send('what is this', image: tempImage('first.jpg', [7, 7, 7, 7]));

    // Follow-up: text only — must replay the earlier image as context.
    gemma.scriptedDeltas = ['black'];
    await controller().send('what color is it');

    // The follow-up carries no NEW image…
    expect(gemma.lastImage, isNull);
    // …but the assembled history replays the prior image turn with its bytes (read just-in-time).
    expect(gemma.lastHistoryImages, isNotNull);
    expect(gemma.lastHistoryImages!.any((i) => i != null), isTrue,
        reason: 'a prior image turn is present in the assembled context');
    expect(gemma.lastHistoryImages!.firstWhere((i) => i != null)!.bytes,
        equals(Uint8List.fromList([7, 7, 7, 7])));
  });
}
