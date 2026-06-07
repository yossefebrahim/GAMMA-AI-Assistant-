import 'package:ai_assistant/app/router.dart';
import 'package:ai_assistant/app/theme/app_theme.dart';
import 'package:ai_assistant/core/platform/device_info_preflight_service.dart';
import 'package:ai_assistant/data/model/background_model_downloader.dart';
import 'package:ai_assistant/domain/services/device_preflight_service.dart';
import 'package:ai_assistant/features/download/download_screen.dart';
import 'package:ai_assistant/features/onboarding/license_screen.dart';
import 'package:ai_assistant/features/onboarding/preflight_blocked_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/container_harness.dart';
import '../helpers/fake_device_preflight_service.dart';
import '../helpers/fake_model_downloader.dart';

/// US5 preflight gate (FR-003/FR-004/FR-006, SC-008). Exercises the device matrix through the
/// license → preflight → route flow; ineligible devices are blocked with the specific reason and
/// no download is started.
void main() {
  late FakeModelDownloader downloader;

  ProviderContainer containerWith(DevicePreflightService preflight) {
    downloader = FakeModelDownloader();
    return makeContainer(
      overrides: [
        devicePreflightServiceProvider.overrideWithValue(preflight),
        modelDownloaderProvider.overrideWithValue(downloader),
      ],
    );
  }

  Widget app(ProviderContainer container) => UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light,
          darkTheme: AppTheme.dark,
          themeMode: ThemeMode.dark,
          home: const LicenseScreen(),
          onGenerateRoute: AppRouter.onGenerateRoute,
        ),
      );

  Future<void> acknowledgeAndContinue(WidgetTester tester) async {
    await tester.tap(find.byKey(LicenseScreen.checkboxKey));
    await tester.pump();
    await tester.tap(find.byKey(LicenseScreen.continueKey));
    await tester.pump(); // begin async preflight
    await tester.pump(const Duration(milliseconds: 50)); // resolve
    await tester.pump(); // build next route
    await tester.pump(const Duration(milliseconds: 350)); // route transition
  }

  testWidgets('insufficient memory (6 GB) is blocked, no download starts (FR-004/SC-008)',
      (tester) async {
    final container = containerWith(FakeDevicePreflightService.insufficientMemory());
    addTearDown(container.dispose);

    await tester.pumpWidget(app(container));
    await acknowledgeAndContinue(tester);

    expect(find.byType(PreflightBlockedScreen), findsOneWidget);
    expect(find.text('not enough memory'), findsOneWidget);
    expect(find.byType(DownloadScreen), findsNothing);
    expect(downloader.downloadCount, 0);
  });

  testWidgets('unsupported ABI is blocked with the architecture reason (FR-006)', (tester) async {
    final container = containerWith(FakeDevicePreflightService.unsupportedAbi());
    addTearDown(container.dispose);

    await tester.pumpWidget(app(container));
    await acknowledgeAndContinue(tester);

    expect(find.byType(PreflightBlockedScreen), findsOneWidget);
    expect(find.text('unsupported processor'), findsOneWidget);
    expect(downloader.downloadCount, 0);
  });

  testWidgets('exactly 7000 MB + arm64 is eligible and proceeds to download (FR-003 boundary)',
      (tester) async {
    final container = containerWith(
      FakeDevicePreflightService.fromProbe(ramMb: 7000, abis: const ['arm64-v8a']),
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(app(container));
    await acknowledgeAndContinue(tester);

    expect(find.byType(DownloadScreen), findsOneWidget);
    expect(find.byType(PreflightBlockedScreen), findsNothing);
  });
}
