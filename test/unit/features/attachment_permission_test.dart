import 'package:ai_assistant/domain/entities/model_capabilities.dart';
import 'package:ai_assistant/domain/services/media_permission_service.dart';
import 'package:ai_assistant/domain/services/media_picker_service.dart';
import 'package:ai_assistant/features/chat/attachment_controller.dart';
import 'package:ai_assistant/features/chat/chat_providers.dart';
import 'package:ai_assistant/infrastructure/media/image_picker_service.dart';
import 'package:ai_assistant/infrastructure/media/permission_handler_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/fake_media_permission_service.dart';
import '../../helpers/fake_media_picker_service.dart';

/// US4 permission lifecycle (FR-009/FR-010/FR-011) — driven by [FakeMediaPermissionService] +
/// [FakeMediaPickerService], no device.
void main() {
  late FakeMediaPickerService picker;
  late FakeMediaPermissionService permission;
  late ProviderContainer container;

  ProviderContainer build() => ProviderContainer(
        overrides: [
          mediaPickerServiceProvider.overrideWithValue(picker),
          mediaPermissionServiceProvider.overrideWithValue(permission),
          modelCapabilitiesProvider.overrideWith((ref) => const ModelCapabilities(image: true)),
        ],
      );

  setUp(() {
    picker = FakeMediaPickerService()..cameraResult = const PickedImage(path: '/tmp/cam.jpg');
  });

  tearDown(() => container.dispose());

  AttachmentController controller() => container.read(attachmentControllerProvider.notifier);
  AttachmentState read() => container.read(attachmentControllerProvider);

  test('denied → request → granted proceeds to capture (FR-009)', () async {
    permission = FakeMediaPermissionService(
      status: MediaPermissionStatus.denied,
      requestResults: [MediaPermissionStatus.granted],
    );
    container = build();

    await controller().pickFromCamera();

    expect(permission.requestCalls, 1);
    expect(read().pending?.path, '/tmp/cam.jpg');
    expect(read().permissionPrompt, AttachmentPrompt.none);
  });

  test('denied → request → still denied shows the explainer, no capture (FR-009)', () async {
    permission = FakeMediaPermissionService(
      status: MediaPermissionStatus.denied,
      requestResults: [MediaPermissionStatus.denied],
    );
    container = build();

    await controller().pickFromCamera();

    expect(read().pending, isNull);
    expect(read().permissionPrompt, AttachmentPrompt.permissionDenied);
  });

  test('permanentlyDenied routes to the settings explainer; openSettings() is invoked (FR-010)',
      () async {
    permission = FakeMediaPermissionService(status: MediaPermissionStatus.permanentlyDenied);
    container = build();

    await controller().pickFromCamera();
    expect(read().permissionPrompt, AttachmentPrompt.permissionPermanentlyDenied);
    expect(picker.cameraCalls, 0, reason: 'no capture attempted without access');

    await controller().openSettings();
    expect(permission.openSettingsCalls, 1);
  });

  test('restricted routes to the settings explainer (FR-010)', () async {
    permission = FakeMediaPermissionService(status: MediaPermissionStatus.restricted);
    container = build();

    await controller().pickFromCamera();

    expect(read().permissionPrompt, AttachmentPrompt.permissionPermanentlyDenied);
  });

  test('declining never dead-ends: the prompt is dismissible and leaves no pending (FR-011)',
      () async {
    permission = FakeMediaPermissionService(
      status: MediaPermissionStatus.denied,
      requestResults: [MediaPermissionStatus.denied],
    );
    container = build();

    await controller().pickFromCamera();
    expect(read().permissionPrompt, AttachmentPrompt.permissionDenied);

    controller().dismissPrompt();
    expect(read().permissionPrompt, AttachmentPrompt.none);
    expect(read().pending, isNull);
  });

  test('a legacy library denial falls back to the explainer (FR-009)', () async {
    permission = FakeMediaPermissionService();
    picker.throwLibraryAccess = true;
    container = build();

    await controller().pickFromLibrary();

    expect(read().permissionPrompt, AttachmentPrompt.permissionDenied);
    expect(read().pending, isNull);
  });
}
