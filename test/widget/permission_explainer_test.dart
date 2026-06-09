import 'package:ai_assistant/app/theme/app_theme.dart';
import 'package:ai_assistant/domain/entities/model_capabilities.dart';
import 'package:ai_assistant/domain/services/media_permission_service.dart';
import 'package:ai_assistant/features/chat/chat_providers.dart';
import 'package:ai_assistant/features/chat/widgets/composer.dart';
import 'package:ai_assistant/infrastructure/media/image_picker_service.dart';
import 'package:ai_assistant/infrastructure/media/permission_handler_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/container_harness.dart';
import '../helpers/fake_media_permission_service.dart';
import '../helpers/fake_media_picker_service.dart';

/// US4 permission explainer widget test (FR-009/FR-010/FR-011) — the camera path with no grant
/// shows an explainer with grant + open-settings actions and a dismiss that returns to a working
/// composer.
void main() {
  late FakeMediaPickerService picker;
  late FakeMediaPermissionService permission;
  late ProviderContainer container;

  setUp(() {
    picker = FakeMediaPickerService();
    // Camera access denied and stays denied after a request → the explainer must appear.
    permission = FakeMediaPermissionService(
      status: MediaPermissionStatus.denied,
      requestResults: [MediaPermissionStatus.denied],
    );
    container = makeContainer(
      overrides: [
        mediaPickerServiceProvider.overrideWithValue(picker),
        mediaPermissionServiceProvider.overrideWithValue(permission),
        modelCapabilitiesProvider.overrideWith((ref) => const ModelCapabilities(image: true)),
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

  testWidgets('camera with no grant shows an explainer with grant + open settings + dismiss; '
      'dismiss returns to a working composer (FR-009/FR-010/FR-011)', (tester) async {
    await tester.pumpWidget(app());
    await tester.pump();

    await tester.tap(find.byKey(Composer.attachKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Composer.cameraOptionKey));
    await tester.pumpAndSettle();

    // The explainer is shown with all three actions.
    expect(find.byKey(Composer.permissionExplainerKey), findsOneWidget);
    expect(find.byKey(Composer.permissionGrantKey), findsOneWidget);
    expect(find.byKey(Composer.permissionSettingsKey), findsOneWidget);
    expect(find.byKey(Composer.permissionDismissKey), findsOneWidget);

    // Dismiss → the explainer closes and text chat still works.
    await tester.tap(find.byKey(Composer.permissionDismissKey));
    await tester.pumpAndSettle();
    expect(find.byKey(Composer.permissionExplainerKey), findsNothing);

    await tester.enterText(find.byKey(Composer.fieldKey), 'still works');
    await tester.pump();
    expect(tester.widget<IconButton>(find.byKey(Composer.sendKey)).onPressed, isNotNull);
  });

  testWidgets('open settings invokes openAppSettings via the service (FR-010)', (tester) async {
    permission.status = MediaPermissionStatus.permanentlyDenied;
    await tester.pumpWidget(app());
    await tester.pump();

    await tester.tap(find.byKey(Composer.attachKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Composer.cameraOptionKey));
    await tester.pumpAndSettle();

    expect(find.byKey(Composer.permissionSettingsKey), findsOneWidget);
    // permanentlyDenied → no "grant" (can't ask again), only settings + dismiss.
    expect(find.byKey(Composer.permissionGrantKey), findsNothing);

    await tester.tap(find.byKey(Composer.permissionSettingsKey));
    await tester.pumpAndSettle();
    expect(permission.openSettingsCalls, 1);
  });
}
