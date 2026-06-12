import 'dart:io';

import 'package:ai_assistant/app/theme/app_theme.dart';
import 'package:ai_assistant/data/images/image_file_store.dart';
import 'package:ai_assistant/domain/entities/model_capabilities.dart';
import 'package:ai_assistant/domain/services/media_picker_service.dart';
import 'package:ai_assistant/features/chat/attachment_controller.dart';
import 'package:ai_assistant/features/chat/chat_providers.dart';
import 'package:ai_assistant/features/chat/widgets/attachment_preview.dart';
import 'package:ai_assistant/features/chat/widgets/composer.dart';
import 'package:ai_assistant/infrastructure/media/image_picker_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/container_harness.dart';
import '../helpers/fake_media_picker_service.dart';

/// US1 composer widget tests (FR-001/FR-004/FR-005) — the attach affordance, the camera/library
/// chooser, the pending preview, and image-or-text send enablement. Seam-backed, no device:
/// capability is injected as DATA via [modelCapabilitiesProvider].
void main() {
  late FakeMediaPickerService picker;
  late ProviderContainer container;

  setUp(() {
    picker = FakeMediaPickerService();
    container = makeContainer(
      overrides: [
        mediaPickerServiceProvider.overrideWithValue(picker),
        modelCapabilitiesProvider.overrideWith(
          (ref) => const ModelCapabilities(image: true),
        ),
        imageFileStoreProvider.overrideWithValue(
          ImageFileStore(documentsDirectory: () async => Directory.systemTemp),
        ),
      ],
    );
  });

  tearDown(() => container.dispose());

  Widget app() => UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: ThemeMode.dark,
      home: const Scaffold(body: Composer()),
    ),
  );

  testWidgets('attach control shows when the model supports images (FR-005)', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    await tester.pump();

    expect(find.byKey(Composer.attachKey), findsOneWidget);
  });

  testWidgets('tapping attach offers camera and photo library (FR-001)', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    await tester.pump();

    await tester.tap(find.byKey(Composer.attachKey));
    await tester.pumpAndSettle();

    expect(find.byKey(Composer.cameraOptionKey), findsOneWidget);
    expect(find.byKey(Composer.libraryOptionKey), findsOneWidget);
  });

  testWidgets(
    'a pending image previews with a remove control and enables send with no text '
    '(FR-002/FR-004)',
    (tester) async {
      picker.libraryResult = const PickedImage(path: '/tmp/fake-preview.jpg');
      await tester.pumpWidget(app());
      await tester.pump();

      // Send is disabled with neither text nor image.
      expect(
        tester.widget<IconButton>(find.byKey(Composer.sendKey)).onPressed,
        isNull,
      );

      await container
          .read(attachmentControllerProvider.notifier)
          .pickFromLibrary();
      await tester.pump();

      expect(find.byType(AttachmentPreview), findsOneWidget);
      expect(find.byKey(AttachmentPreview.removeKey), findsOneWidget);
      // Send is now enabled by the image alone (no text).
      expect(
        tester.widget<IconButton>(find.byKey(Composer.sendKey)).onPressed,
        isNotNull,
      );
    },
  );

  testWidgets('the remove control clears the preview (FR-003)', (tester) async {
    picker.libraryResult = const PickedImage(path: '/tmp/fake-preview.jpg');
    await tester.pumpWidget(app());
    await tester.pump();
    await container
        .read(attachmentControllerProvider.notifier)
        .pickFromLibrary();
    await tester.pump();

    await tester.tap(find.byKey(AttachmentPreview.removeKey));
    await tester.pump();

    expect(find.byType(AttachmentPreview), findsNothing);
    expect(container.read(attachmentControllerProvider).pending, isNull);
  });
}
