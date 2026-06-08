import 'package:ai_assistant/domain/entities/model_capabilities.dart';
import 'package:ai_assistant/domain/services/media_picker_service.dart';
import 'package:ai_assistant/features/chat/attachment_controller.dart';
import 'package:ai_assistant/features/chat/chat_providers.dart';
import 'package:ai_assistant/infrastructure/media/image_picker_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// StateProvider lives in the legacy entrypoint in Riverpod 3 — fine for a test toggle.
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/fake_media_picker_service.dart';

/// US2 capability-driven clearing (FR-008) — a pending image is dropped, with a note, when the
/// active model flips to image-unsupported. Capabilities are injected as DATA.
final _capProvider =
    StateProvider<ModelCapabilities>((ref) => const ModelCapabilities(image: true));

void main() {
  late FakeMediaPickerService picker;
  late ProviderContainer container;

  setUp(() {
    picker = FakeMediaPickerService();
    container = ProviderContainer(
      overrides: [
        mediaPickerServiceProvider.overrideWithValue(picker),
        modelCapabilitiesProvider.overrideWith((ref) => ref.watch(_capProvider)),
      ],
    );
  });

  tearDown(() => container.dispose());

  AttachmentController controller() => container.read(attachmentControllerProvider.notifier);
  AttachmentState read() => container.read(attachmentControllerProvider);

  test('flipping to an image-unsupported model clears the pending image with a note (FR-008)',
      () async {
    picker.libraryResult = const PickedImage(path: '/tmp/a.jpg');
    await controller().pickFromLibrary();
    expect(read().pending, isNotNull);

    // Switch to a text-only model.
    container.read(_capProvider.notifier).state = const ModelCapabilities(image: false);
    await pumpEventQueue();

    expect(read().pending, isNull);
    expect(read().note, AttachmentController.clearedOnModelSwitchNote);
  });

  test('flipping while there is no pending image is a no-op (no spurious note)', () async {
    expect(read().pending, isNull);

    container.read(_capProvider.notifier).state = const ModelCapabilities(image: false);
    await pumpEventQueue();

    expect(read().pending, isNull);
    expect(read().note, isNull);
  });
}
