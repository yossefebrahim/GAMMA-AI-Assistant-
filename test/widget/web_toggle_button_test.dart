import 'dart:async';

import 'package:ai_assistant/app/theme/app_theme.dart';
import 'package:ai_assistant/data/repositories/drift_conversation_repository.dart';
import 'package:ai_assistant/data/repositories/settings_repository.dart';
import 'package:ai_assistant/domain/entities/model_capabilities.dart';
import 'package:ai_assistant/domain/entities/web_access_override.dart';
import 'package:ai_assistant/features/chat/chat_controller.dart';
import 'package:ai_assistant/features/chat/chat_providers.dart';
import 'package:ai_assistant/features/chat/chat_screen.dart';
import 'package:ai_assistant/features/chat/widgets/web_toggle_button.dart';
import 'package:ai_assistant/infrastructure/gemma/flutter_gemma_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/container_harness.dart';
import '../helpers/fake_gemma_service.dart';
import '../helpers/fake_secure_key_store.dart';
import '../helpers/test_db.dart';

/// T046 (006 US3; FR-007, FR-008, FR-009, FR-032) — the per-conversation web toggle drives the
/// genuine tool-list recomposition, persists across a fake restart, and recreates the session once.
///
/// Crucially the REAL [modelSessionProvider] runs here (only [installedModelPathProvider] is
/// overridden) so toggling re-evaluates the triple-gated `declaredTools` and reloads the model with
/// the new list — a bare startSession would keep the stale tools baked at the first loadModel. Tool
/// presence is observed through [FakeGemmaService.loadedTools]; recreation through [loadCount].
void main() {
  late FakeGemmaService gemma;
  late FakeSecureKeyStore keyStore;

  setUp(() {
    gemma = FakeGemmaService(
      capabilitiesData: const ModelCapabilities(functionCalling: true),
    );
    keyStore = FakeSecureKeyStore()
      ..seed('k'); // a key is required by the triple gate
  });

  /// Build a container whose REAL session provider loads `/fake/model` with the recomputed tools.
  /// [globalWebEnabled] seeds the persisted global flag before the first session load.
  Future<ProviderContainer> buildContainer({
    required bool globalWebEnabled,
  }) async {
    final container = makeContainer(
      secureKeyStore: keyStore,
      overrides: [
        gemmaServiceProvider.overrideWithValue(gemma),
        installedModelPathProvider.overrideWith((ref) async => '/fake/model'),
      ],
    );
    addTearDown(container.dispose);
    if (globalWebEnabled) {
      await container
          .read(settingsRepositoryProvider)
          .setWebAccessEnabled(true);
      // Sync the reactive notifier with the persisted value.
      await container.read(webAccessEnabledProvider.notifier).set(true);
    }
    return container;
  }

  Widget app(ProviderContainer container) => UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: ThemeMode.dark,
      home: const ChatScreen(),
    ),
  );

  /// Open [conversationId] and let the real session load + the reactive list settle.
  Future<void> open(
    WidgetTester tester,
    ProviderContainer container,
    int conversationId,
  ) async {
    await tester.pumpWidget(app(container));
    await tester.pump(); // kick the model session future
    await tester.pump(); // resolve the load
    unawaited(
      container
          .read(chatControllerProvider.notifier)
          .openConversation(conversationId),
    );
    await tester.pump();
    await tester.pump();
  }

  bool webToolsDeclared() =>
      (gemma.loadedTools ?? const []).any((t) => t.name == 'web_search');

  testWidgets(
    'global-off + per-convo ON → web tools active for this conversation',
    (tester) async {
      final container = await buildContainer(globalWebEnabled: false);
      final repo = container.read(conversationRepositoryProvider);
      final conv = await repo.createConversation();
      await open(tester, container, conv.id);

      // Baseline: global off, inherit → no web tools declared.
      expect(webToolsDeclared(), isFalse);

      // Tap to cycle inherit → on.
      await tester.tap(find.byKey(WebToggleButton.buttonKey));
      await tester
          .pump(); // run the toggle future (persist + invalidate + reload)
      await tester.pump();

      // Override persisted as `on`, and the recreated session declares the web tools.
      expect(await repo.readWebAccessOverride(conv.id), WebAccessOverride.on);
      expect(webToolsDeclared(), isTrue);
    },
  );

  testWidgets(
    'global-on + per-convo OFF → web tools absent for this conversation',
    (tester) async {
      final container = await buildContainer(globalWebEnabled: true);
      final repo = container.read(conversationRepositoryProvider);
      final conv = await repo.createConversation();
      await open(tester, container, conv.id);

      // Baseline: global on, inherit → web tools declared.
      expect(webToolsDeclared(), isTrue);

      // inherit → on → off takes two taps.
      await tester.tap(find.byKey(WebToggleButton.buttonKey));
      await tester.pump();
      await tester.pump();
      await tester.tap(find.byKey(WebToggleButton.buttonKey));
      await tester.pump();
      await tester.pump();

      expect(await repo.readWebAccessOverride(conv.id), WebAccessOverride.off);
      expect(webToolsDeclared(), isFalse);
    },
  );

  testWidgets('toggle state persists across a fake restart (history reload)', (
    tester,
  ) async {
    // A SHARED in-memory database survives the "restart" (a fresh container reading the same db).
    final sharedDb = newTestDatabase();

    // First "session": turn the override on.
    final first = makeContainer(
      database: sharedDb,
      secureKeyStore: keyStore,
      overrides: [
        gemmaServiceProvider.overrideWithValue(
          FakeGemmaService(
            capabilitiesData: const ModelCapabilities(functionCalling: true),
          ),
        ),
        installedModelPathProvider.overrideWith((ref) async => '/fake/model'),
      ],
    );
    final repo = first.read(conversationRepositoryProvider);
    final conv = await repo.createConversation();
    await repo.setWebAccessOverride(conv.id, WebAccessOverride.on);
    // NOTE: `first` is intentionally NOT disposed here — disposing it would close the shared in-memory
    // db (the appDatabaseProvider override's onDispose). The "restart" is a fresh provider graph over
    // the SAME underlying data, which is what a real app relaunch sees.

    final restarted = makeContainer(
      database: sharedDb,
      secureKeyStore: keyStore,
      overrides: [
        gemmaServiceProvider.overrideWithValue(
          FakeGemmaService(
            capabilitiesData: const ModelCapabilities(functionCalling: true),
          ),
        ),
        installedModelPathProvider.overrideWith((ref) async => '/fake/model'),
      ],
    );
    addTearDown(restarted.dispose);

    // The persisted override survived the restart.
    expect(
      await restarted
          .read(conversationRepositoryProvider)
          .readWebAccessOverride(conv.id),
      WebAccessOverride.on,
    );
    // The composer toggle reflects it: open the restarted screen and confirm the active indicator.
    unawaited(
      restarted.read(chatControllerProvider.notifier).openConversation(conv.id),
    );
    await tester.pumpWidget(app(restarted));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(find.byKey(WebToggleButton.activeIndicatorKey), findsOneWidget);
  });

  testWidgets(
    'a mid-conversation toggle change recreates the session exactly once (FR-032)',
    (tester) async {
      final container = await buildContainer(globalWebEnabled: false);
      final repo = container.read(conversationRepositoryProvider);
      final conv = await repo.createConversation();
      await open(tester, container, conv.id);

      final before = gemma.loadCount;

      await tester.tap(find.byKey(WebToggleButton.buttonKey));
      await tester.pump();
      await tester.pump();

      // Exactly one reload: the session was recreated (close + reload) with the new tool list, not
      // merely re-instructed and not reloaded twice.
      expect(gemma.loadCount - before, 1);
    },
  );
}
