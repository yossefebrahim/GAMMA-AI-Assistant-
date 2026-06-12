import 'package:ai_assistant/app/router.dart';
import 'package:ai_assistant/app/theme/app_theme.dart';
import 'package:ai_assistant/core/platform/device_info_preflight_service.dart';
import 'package:ai_assistant/data/model/background_model_downloader.dart';
import 'package:ai_assistant/data/repositories/settings_repository.dart';
import 'package:ai_assistant/domain/services/model_downloader.dart';
import 'package:ai_assistant/features/download/download_screen.dart';
import 'package:ai_assistant/features/onboarding/license_screen.dart';
import 'package:ai_assistant/features/onboarding/welcome_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/container_harness.dart';
import '../helpers/fake_device_preflight_service.dart';
import '../helpers/fake_model_downloader.dart';

/// US1 onboarding widget tests (FR-001/FR-023/SC-010, Q1, FR-007/FR-008). All seam-backed: in-memory
/// drift, fake preflight, fake downloader — no device, no network.
void main() {
  Widget app(ProviderContainer container, {required Widget home}) {
    return UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: AppTheme.light,
        darkTheme: AppTheme.dark,
        themeMode: ThemeMode.dark,
        home: home,
        onGenerateRoute: AppRouter.onGenerateRoute,
      ),
    );
  }

  testWidgets(
    'welcome is dark and explains on-device privacy first (FR-001/FR-023, SC-010)',
    (tester) async {
      final container = makeContainer();
      addTearDown(container.dispose);

      await tester.pumpWidget(app(container, home: const WelcomeScreen()));

      expect(find.byKey(WelcomeScreen.explainerKey), findsOneWidget);
      expect(find.text('get started'), findsOneWidget);
      final context = tester.element(find.byType(Scaffold));
      expect(Theme.of(context).brightness, Brightness.dark);
    },
  );

  testWidgets('license acknowledgment gates the download (Q1)', (tester) async {
    final container = makeContainer(
      overrides: [
        devicePreflightServiceProvider.overrideWithValue(
          FakeDevicePreflightService.eligible(),
        ),
        modelDownloaderProvider.overrideWithValue(FakeModelDownloader()),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(app(container, home: const LicenseScreen()));

    // Continue is disabled until the box is checked.
    FilledButton continueButton() => tester.widget<FilledButton>(
      find.descendant(
        of: find.byKey(LicenseScreen.continueKey),
        matching: find.byType(FilledButton),
      ),
    );
    expect(
      continueButton().onPressed,
      isNull,
      reason: 'gated before acknowledgment',
    );

    await tester.tap(find.byKey(LicenseScreen.checkboxKey));
    await tester.pump();
    expect(
      continueButton().onPressed,
      isNotNull,
      reason: 'enabled after acknowledgment',
    );

    await tester.tap(find.byKey(LicenseScreen.continueKey));
    await tester.pump(); // kick off acknowledge + preflight
    await tester.pump(const Duration(milliseconds: 50)); // resolve async
    await tester.pump(); // build the next route

    // The acknowledgment was persisted (Q1) and we advanced to the download screen.
    final settings = await container.read(settingsRepositoryProvider).read();
    expect(settings.hasAcknowledgedLicense, isTrue);
    expect(find.byType(DownloadScreen), findsOneWidget);
  });

  testWidgets(
    'download screen shows live progress and a cancel (FR-007/FR-008)',
    (tester) async {
      final downloader = FakeModelDownloader()
        ..scriptedProgress = const [
          DownloadProgress(
            phase: DownloadPhase.running,
            fraction: 0.42,
            downloadedBytes: 1000000000,
            totalBytes: 2400000000,
          ),
        ];
      final container = makeContainer(
        overrides: [modelDownloaderProvider.overrideWithValue(downloader)],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(app(container, home: const DownloadScreen()));
      await tester.pump(); // run the post-frame start()
      await tester.pump(); // receive the scripted progress emission

      expect(find.text('42'), findsOneWidget); // dot-matrix percent
      expect(find.text('cancel'), findsOneWidget);

      await tester.tap(find.text('cancel'));
      await tester.pump();
      expect(downloader.cancelCount, 1);
    },
  );
}
