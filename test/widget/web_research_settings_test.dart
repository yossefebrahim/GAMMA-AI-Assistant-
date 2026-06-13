import 'dart:async';

import 'package:ai_assistant/app/theme/app_colors.dart';
import 'package:ai_assistant/app/theme/app_theme.dart';
import 'package:ai_assistant/data/repositories/settings_repository.dart';
import 'package:ai_assistant/domain/entities/app_settings.dart';
import 'package:ai_assistant/domain/entities/model_capabilities.dart';
import 'package:ai_assistant/features/settings/web_research_screen.dart';
import 'package:ai_assistant/infrastructure/gemma/flutter_gemma_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/container_harness.dart';
import '../helpers/fake_gemma_service.dart';
import '../helpers/fake_secure_key_store.dart';

/// T043 (006 US2) — WebResearchSettingsScreen widget + a11y tests.
///
/// Covers FR-002 (the three mandatory disclosures), FR-003 (masking after save), FR-004 (clear key
/// resets the field + toggle), FR-005 (enabling the toggle without a key is blocked), and SC-013
/// (48dp touch targets). The raw key never re-enters the field — `hasValidKey()` drives the masked
/// state. The toggle state comes from the controlled [settingsStreamProvider]; the screen's clear/
/// save side-effects are exercised through the real [WebResearchController] over the in-memory DB.
void main() {
  late FakeSecureKeyStore keyStore;
  late StreamController<AppSettings> settingsStream;
  late ProviderContainer container;

  void buildContainer() {
    keyStore = FakeSecureKeyStore();
    settingsStream = StreamController<AppSettings>.broadcast();
    container = makeContainer(
      secureKeyStore: keyStore,
      overrides: [
        settingsStreamProvider.overrideWith((ref) => settingsStream.stream),
        gemmaServiceProvider.overrideWithValue(
          FakeGemmaService(capabilitiesData: const ModelCapabilities()),
        ),
      ],
    );
  }

  setUp(buildContainer);

  tearDown(() async {
    container.dispose();
    await settingsStream.close();
  });

  Widget app() => UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      theme: AppTheme.dark,
      home: const Scaffold(body: WebResearchSettingsScreen()),
    ),
  );

  void emitSettings({bool webAccessEnabled = false}) {
    settingsStream.add(
      AppSettings(
        themeMode: AppThemeMode.dark,
        webAccessEnabled: webAccessEnabled,
      ),
    );
  }

  /// Pump the screen and resolve the async hasValidKey() + the settings stream.
  Future<void> pumpScreen(
    WidgetTester tester, {
    bool webAccessEnabled = false,
  }) async {
    await tester.pumpWidget(app());
    emitSettings(webAccessEnabled: webAccessEnabled);
    await tester.pump(); // resolve settings stream + initState hasValidKey()
    await tester.pump(); // rebuild after _refreshHasKey setState
  }

  group('fresh install', () {
    testWidgets('toggle is off and the key entry field is shown (no key)', (
      tester,
    ) async {
      await pumpScreen(tester);

      final toggle = tester.widget<SwitchListTile>(
        find.byKey(WebResearchSettingsScreen.toggleKey),
      );
      expect(toggle.value, isFalse);
      // No key yet → the entry field is shown, the masked row is not.
      expect(find.byKey(WebResearchSettingsScreen.keyFieldKey), findsOneWidget);
      expect(find.byKey(WebResearchSettingsScreen.savedMaskKey), findsNothing);
    });
  });

  group('key entry + save (FR-003 masking)', () {
    testWidgets('saving a key masks it and shows "saved — tap to replace"', (
      tester,
    ) async {
      await pumpScreen(tester);

      await tester.enterText(
        find.byKey(WebResearchSettingsScreen.keyFieldKey),
        'tvly-secret-key',
      );
      await tester.tap(find.byKey(WebResearchSettingsScreen.saveKeyButtonKey));
      await tester.pump(); // run saveKey + _refreshHasKey
      await tester.pump();

      // The masked row replaces the entry field; the plaintext key is NOT shown.
      expect(
        find.byKey(WebResearchSettingsScreen.savedMaskKey),
        findsOneWidget,
      );
      expect(find.text('saved — tap to replace'), findsOneWidget);
      expect(find.byKey(WebResearchSettingsScreen.keyFieldKey), findsNothing);
      expect(find.text('tvly-secret-key'), findsNothing);
      // The clear-key action is now available.
      expect(
        find.byKey(WebResearchSettingsScreen.clearKeyButtonKey),
        findsOneWidget,
      );
    });
  });

  group('toggle gating (FR-005)', () {
    testWidgets(
      'enabling the toggle with no key is blocked; toggle stays off',
      (tester) async {
        await pumpScreen(tester);

        await tester.tap(find.byKey(WebResearchSettingsScreen.toggleKey));
        await tester.pump(); // run setGlobalToggle (rejected) + setState
        await tester.pump();

        // The reject prompt is shown and the global flag stays false.
        expect(
          find.byKey(WebResearchSettingsScreen.noKeyPromptKey),
          findsOneWidget,
        );
        expect(container.read(webAccessEnabledProvider), isFalse);
        final toggle = tester.widget<SwitchListTile>(
          find.byKey(WebResearchSettingsScreen.toggleKey),
        );
        expect(toggle.value, isFalse);
      },
    );

    testWidgets('with a key stored, enabling the toggle is allowed', (
      tester,
    ) async {
      keyStore.seed('tvly-existing');
      await pumpScreen(tester);

      await tester.tap(find.byKey(WebResearchSettingsScreen.toggleKey));
      await tester.pump();
      await tester.pump();

      expect(container.read(webAccessEnabledProvider), isTrue);
      expect(
        find.byKey(WebResearchSettingsScreen.noKeyPromptKey),
        findsNothing,
      );
    });
  });

  group('clear key (FR-004)', () {
    testWidgets('clearing the key resets the field and turns the toggle off', (
      tester,
    ) async {
      keyStore.seed('tvly-existing');
      await pumpScreen(tester, webAccessEnabled: true);
      // Sanity: the masked row is shown for a pre-seeded key.
      expect(
        find.byKey(WebResearchSettingsScreen.savedMaskKey),
        findsOneWidget,
      );

      await tester.tap(find.byKey(WebResearchSettingsScreen.clearKeyButtonKey));
      await tester.pump(); // run clearKey + _refreshHasKey
      await tester.pump();

      // The entry field returns (no key) and the global flag is off (FR-004).
      expect(find.byKey(WebResearchSettingsScreen.keyFieldKey), findsOneWidget);
      expect(find.byKey(WebResearchSettingsScreen.savedMaskKey), findsNothing);
      expect(container.read(webAccessEnabledProvider), isFalse);
      expect(keyStore.clearWasCalled, isTrue);
    });
  });

  group('FR-002 disclosures', () {
    testWidgets('all three mandatory disclosure strings are present', (
      tester,
    ) async {
      await pumpScreen(tester);

      expect(
        find.text("search queries are sent to tavily's servers"),
        findsOneWidget,
      );
      expect(
        find.text(
          'when you fetch a page, your device contacts that website '
          'directly — not tavily',
        ),
        findsOneWidget,
      );
      expect(find.text('your key never leaves your device'), findsOneWidget);
    });
  });

  group('a11y (SC-013)', () {
    testWidgets('the web toggle meets the 48dp touch-target floor', (
      tester,
    ) async {
      await pumpScreen(tester);
      final size = tester.getSize(
        find.byKey(WebResearchSettingsScreen.toggleKey),
      );
      expect(size.height, greaterThanOrEqualTo(48));
    });

    testWidgets('the save-key button meets the 48dp touch-target floor', (
      tester,
    ) async {
      await pumpScreen(tester);
      final size = tester.getSize(
        find.byKey(WebResearchSettingsScreen.saveKeyButtonKey),
      );
      expect(size.height, greaterThanOrEqualTo(48));
    });

    testWidgets('the clear-key button meets the 48dp touch-target floor', (
      tester,
    ) async {
      keyStore.seed('tvly-existing');
      await pumpScreen(tester);
      final size = tester.getSize(
        find.byKey(WebResearchSettingsScreen.clearKeyButtonKey),
      );
      expect(size.height, greaterThanOrEqualTo(48));
    });

    testWidgets('the clear-key action uses the accent (red) foreground', (
      tester,
    ) async {
      // Only the destructive clear action gets red; the save action is monochrome (design-system §2).
      keyStore.seed('tvly-existing');
      await pumpScreen(tester);
      final colors = AppTheme.dark.extension<AppColors>()!;
      final clear = tester.widget<TextButton>(
        find.byKey(WebResearchSettingsScreen.clearKeyButtonKey),
      );
      final fg = clear.style?.foregroundColor?.resolve(<WidgetState>{});
      expect(fg, colors.accent);
    });
  });
}
