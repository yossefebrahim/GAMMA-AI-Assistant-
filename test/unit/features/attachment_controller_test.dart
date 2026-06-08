import 'package:ai_assistant/domain/entities/model_capabilities.dart';
import 'package:ai_assistant/domain/services/media_picker_service.dart';
import 'package:ai_assistant/features/chat/attachment_controller.dart';
import 'package:ai_assistant/features/chat/chat_providers.dart';
import 'package:ai_assistant/infrastructure/media/image_picker_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/fake_media_picker_service.dart';

/// US1 attachment controller (FR-001/FR-002/FR-003) — driven by [FakeMediaPickerService], no device.
void main() {
  late FakeMediaPickerService picker;
  late ProviderContainer container;

  setUp(() {
    picker = FakeMediaPickerService();
    container = ProviderContainer(
      overrides: [
        mediaPickerServiceProvider.overrideWithValue(picker),
        // Keep an image-capable model so the capability listener never clears the pending image.
        modelCapabilitiesProvider.overrideWith((ref) => const ModelCapabilities(image: true)),
      ],
    );
  });

  tearDown(() => container.dispose());

  AttachmentController controller() => container.read(attachmentControllerProvider.notifier);
  AttachmentState read() => container.read(attachmentControllerProvider);

  test('pickFromLibrary sets a pending attachment (FR-001)', () async {
    picker.libraryResult = const PickedImage(path: '/tmp/a.jpg', mimeType: 'image/jpeg');

    await controller().pickFromLibrary();

    expect(read().pending?.path, '/tmp/a.jpg');
    expect(read().pending?.mimeType, 'image/jpeg');
    expect(picker.libraryCalls, 1);
  });

  test('pickFromCamera sets a pending attachment (FR-001)', () async {
    picker.cameraResult = const PickedImage(path: '/tmp/cam.jpg');

    await controller().pickFromCamera();

    expect(read().pending?.path, '/tmp/cam.jpg');
    expect(picker.cameraCalls, 1);
  });

  test('remove clears the pending attachment (FR-003)', () async {
    picker.libraryResult = const PickedImage(path: '/tmp/a.jpg');
    await controller().pickFromLibrary();

    controller().remove();

    expect(read().pending, isNull);
  });

  test('picking another replaces it — single image only (FR-002/FR-003)', () async {
    picker.libraryResult = const PickedImage(path: '/tmp/a.jpg');
    await controller().pickFromLibrary();
    picker.libraryResult = const PickedImage(path: '/tmp/b.jpg');
    await controller().pickFromLibrary();

    expect(read().pending?.path, '/tmp/b.jpg');
  });

  test('cancel (null) leaves the prior state untouched (edge: cancel picker)', () async {
    // No prior attachment → cancel leaves none.
    picker.libraryResult = null;
    await controller().pickFromLibrary();
    expect(read().pending, isNull);

    // With a prior attachment → cancel keeps it.
    picker.libraryResult = const PickedImage(path: '/tmp/a.jpg');
    await controller().pickFromLibrary();
    picker.cameraResult = null; // user cancels the camera
    await controller().pickFromCamera();
    expect(read().pending?.path, '/tmp/a.jpg');
  });
}
