import 'dart:io';

import 'package:ai_assistant/app/theme/app_theme.dart';
import 'package:ai_assistant/data/images/image_file_store.dart';
import 'package:ai_assistant/domain/entities/model_capabilities.dart';
import 'package:ai_assistant/features/chat/chat_providers.dart';
import 'package:ai_assistant/features/chat/widgets/composer.dart';
import 'package:ai_assistant/infrastructure/media/image_picker_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// StateProvider lives in the legacy entrypoint in Riverpod 3 — fine for a test toggle.
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/container_harness.dart';
import '../helpers/fake_media_picker_service.dart';

/// US2 capability gating (FR-005/FR-006/FR-007, SC-002) — the attach control tracks
/// `capabilities.image` as DATA and flips live on a model switch, with NO restart; text chat keeps
/// working when images are unsupported.
final _capProvider =
    StateProvider<ModelCapabilities>((ref) => const ModelCapabilities(image: true));

void main() {
  late ProviderContainer container;

  setUp(() {
    container = makeContainer(
      overrides: [
        mediaPickerServiceProvider.overrideWithValue(FakeMediaPickerService()),
        modelCapabilitiesProvider.overrideWith((ref) => ref.watch(_capProvider)),
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

  testWidgets('attach control tracks capability data live — no restart '
      '(FR-005/FR-006/FR-007, SC-002)', (tester) async {
    await tester.pumpWidget(app());
    await tester.pump();
    expect(find.byKey(Composer.attachKey), findsOneWidget);

    // Switch to a text-only model → the attach control disappears without a restart…
    container.read(_capProvider.notifier).state = const ModelCapabilities(image: false);
    await tester.pump();
    expect(find.byKey(Composer.attachKey), findsNothing);

    // …and text chat still works.
    expect(find.byKey(Composer.fieldKey), findsOneWidget);
    await tester.enterText(find.byKey(Composer.fieldKey), 'hello');
    await tester.pump();
    expect(tester.widget<IconButton>(find.byKey(Composer.sendKey)).onPressed, isNotNull);

    // Switch back → the control reappears live.
    container.read(_capProvider.notifier).state = const ModelCapabilities(image: true);
    await tester.pump();
    expect(find.byKey(Composer.attachKey), findsOneWidget);
  });
}
