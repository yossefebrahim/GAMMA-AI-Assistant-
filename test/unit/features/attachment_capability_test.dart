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
/// active model flips to image-unsupported. Capabilities are injected as DATA. The note fires only
/// when the model is genuinely LOADED (`modelSessionReadyProvider`), not on a load/reload that
/// merely reports textOnly (002 audit).
final _capProvider =
    StateProvider<ModelCapabilities>((ref) => const ModelCapabilities(image: true));
final _readyProvider = StateProvider<bool>((ref) => true);

void main() {
  late FakeMediaPickerService picker;
  late ProviderContainer container;

  setUp(() {
    picker = FakeMediaPickerService();
    container = ProviderContainer(
      overrides: [
        mediaPickerServiceProvider.overrideWithValue(picker),
        modelCapabilitiesProvider.overrideWith((ref) => ref.watch(_capProvider)),
        modelSessionReadyProvider.overrideWith((ref) => ref.watch(_readyProvider)),
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

  test('a load failure / reload (session not ready) keeps the image and shows no misleading note',
      () async {
    picker.libraryResult = const PickedImage(path: '/tmp/a.jpg');
    await controller().pickFromLibrary();
    expect(read().pending, isNotNull);

    // The model is NOT a loaded text-only model — it failed to load / is reloading. Capabilities
    // report textOnly, but this must NOT drop the image with "this model does not accept images"
    // (002 audit): the chat screen surfaces the load/error state separately.
    container.read(_readyProvider.notifier).state = false;
    container.read(_capProvider.notifier).state = const ModelCapabilities(image: false);
    await pumpEventQueue();

    expect(read().pending, isNotNull, reason: 'pending image retained across a transient load state');
    expect(read().note, isNull, reason: 'no misleading capability note while the model is not loaded');
  });
}
