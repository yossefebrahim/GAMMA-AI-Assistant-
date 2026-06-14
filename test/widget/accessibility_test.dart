import 'package:ai_assistant/app/theme/app_spacing.dart';
import 'package:ai_assistant/app/theme/app_theme.dart';
import 'package:ai_assistant/app/widgets/primary_button.dart';
import 'package:ai_assistant/data/model/background_model_downloader.dart';
import 'package:ai_assistant/data/repositories/drift_conversation_repository.dart';
import 'package:ai_assistant/domain/entities/message.dart';
import 'package:ai_assistant/domain/entities/model_capabilities.dart';
import 'package:ai_assistant/domain/entities/tool_outcome.dart';
import 'package:ai_assistant/features/chat/widgets/composer.dart';
import 'package:ai_assistant/features/chat/widgets/source_url_chips.dart';
import 'package:ai_assistant/features/chat/widgets/tool_chip.dart';
import 'package:ai_assistant/features/chat/widgets/web_toggle_button.dart';
import 'package:ai_assistant/features/history/history_screen.dart';
import 'package:ai_assistant/features/settings/settings_screen.dart';
import 'package:ai_assistant/infrastructure/gemma/flutter_gemma_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/container_harness.dart';
import '../helpers/fake_gemma_service.dart';
import '../helpers/fake_model_downloader.dart';

/// Polish T050 + 006 device-validation T061/T062 — the code-enforceable slice of the accessibility
/// gate (FR-031/SC-012; FR-029/SC-013): every interactive control meets the 48dp touch-target floor,
/// and the non-interactive [ToolChip] carries a screen-reader [Semantics] label. (The full Android
/// Accessibility Scanner pass + AA contrast measurement run on a device; the contrast rule is
/// enforced in the tokens — timestamps use `textSecondary`, red is reserved for large/icon/fill.)
void main() {
  testWidgets('the composer send control is at least a 48dp touch target', (
    tester,
  ) async {
    final container = makeContainer(
      overrides: [gemmaServiceProvider.overrideWithValue(FakeGemmaService())],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.dark,
          home: const Scaffold(body: Composer()),
        ),
      ),
    );
    await tester.pump();

    final size = tester.getSize(find.byKey(Composer.sendKey));
    expect(size.width, greaterThanOrEqualTo(AppSpacing.minTouchTarget));
    expect(size.height, greaterThanOrEqualTo(AppSpacing.minTouchTarget));
  });

  testWidgets('the primary button is a full 48dp-high target', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: Scaffold(
          body: Center(
            child: PrimaryButton(label: 'continue', onPressed: () {}),
          ),
        ),
      ),
    );

    final size = tester.getSize(find.byType(PrimaryButton));
    expect(size.height, greaterThanOrEqualTo(AppSpacing.minTouchTarget));
  });

  // ---------------------------------------------------------------------------
  // T061/T062 (SC-013, FR-029) — the interactive surfaces not yet covered above.
  // Each assertion ties a real control to the 48dp floor; where a control's width
  // is content-driven (chips, full-width list rows) only the height is asserted,
  // with a note saying why.
  // ---------------------------------------------------------------------------

  group('history screen targets (SC-013)', () {
    // The per-row DELETE IconButton is the long-standing gap: a tightly-packed
    // destructive control that must still clear the 48dp floor. The screen needs
    // conversations seeded over the in-memory drift DB (mirrors history_screen_test.dart).
    late ProviderContainer container;

    setUp(() {
      container = makeContainer(
        overrides: [
          // Keep model-storage + chat navigation safe in tests (no path_provider / native model).
          modelDownloaderProvider.overrideWithValue(
            FakeModelDownloader()..completedPath = null,
          ),
          gemmaServiceProvider.overrideWithValue(FakeGemmaService()),
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
        home: const HistoryScreen(),
      ),
    );

    testWidgets('the per-row delete control clears the 48dp floor', (
      tester,
    ) async {
      final repo = container.read(conversationRepositoryProvider);
      final conversation = await repo.createConversation();
      await repo.appendUserMessage(conversation.id, 'delete me');

      await tester.pumpWidget(app());
      await tester.pump(); // receive the reactive emission
      await tester.pump();

      // SC-013: the destructive per-row delete IconButton is a full 48dp target.
      final size = tester.getSize(
        find.byKey(HistoryScreen.deleteKey(conversation.id)),
      );
      expect(size.width, greaterThanOrEqualTo(AppSpacing.minTouchTarget));
      expect(size.height, greaterThanOrEqualTo(AppSpacing.minTouchTarget));
    });

    testWidgets('the new-conversation app-bar action clears the 48dp floor', (
      tester,
    ) async {
      await tester.pumpWidget(app());
      await tester.pump();
      await tester.pump();

      // SC-013: the new-conversation IconButton meets the floor in both axes.
      final size = tester.getSize(find.byKey(HistoryScreen.newConversationKey));
      expect(size.width, greaterThanOrEqualTo(AppSpacing.minTouchTarget));
      expect(size.height, greaterThanOrEqualTo(AppSpacing.minTouchTarget));
    });
  });

  group('settings screen targets (SC-013)', () {
    late ProviderContainer container;

    setUp(() {
      container = makeContainer(
        overrides: [
          // modelStorageBytesProvider reads the downloader — keep it off-device.
          modelDownloaderProvider.overrideWithValue(
            FakeModelDownloader()..sizeBytes = 2400000000,
          ),
        ],
      );
    });

    tearDown(() => container.dispose());

    Future<void> pumpSettings(WidgetTester tester) async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: AppTheme.light,
            darkTheme: AppTheme.dark,
            themeMode: ThemeMode.dark,
            home: const SettingsScreen(),
          ),
        ),
      );
      await tester.pump(); // resolve modelStorageBytesProvider
      await tester.pump();
    }

    testWidgets('the memory row clears the 48dp height floor', (tester) async {
      await pumpSettings(tester);

      // SC-013: ListTile rows are full-width (width is content/layout-driven), so only the
      // tappable HEIGHT is the touch-target concern for a row.
      final size = tester.getSize(find.byKey(SettingsScreen.memoryRowKey));
      expect(size.height, greaterThanOrEqualTo(AppSpacing.minTouchTarget));
    });

    testWidgets('the web-research row clears the 48dp height floor', (
      tester,
    ) async {
      await pumpSettings(tester);

      // SC-013: full-width row → assert height only (see memory-row note above).
      final size = tester.getSize(find.byKey(SettingsScreen.webResearchRowKey));
      expect(size.height, greaterThanOrEqualTo(AppSpacing.minTouchTarget));
    });

    testWidgets('the delete-model action clears the 48dp height floor', (
      tester,
    ) async {
      await pumpSettings(tester);

      // SC-013: the delete-model TextButton sits in a row trailing; its width hugs the
      // 'delete' label, so the tappable HEIGHT is the floor that applies here.
      final size = tester.getSize(find.byKey(SettingsScreen.deleteModelKey));
      expect(size.height, greaterThanOrEqualTo(AppSpacing.minTouchTarget));
    });
  });

  testWidgets('the composer web toggle is a full 48dp target (FR-029)', (
    tester,
  ) async {
    // The toggle only renders when the model can call tools; render it standalone with a
    // function-calling fake. It declares an explicit 48x48 minimumSize, so both axes hold.
    final container = makeContainer(
      overrides: [
        gemmaServiceProvider.overrideWithValue(
          FakeGemmaService(
            capabilitiesData: const ModelCapabilities(functionCalling: true),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.dark,
          home: const Scaffold(body: WebToggleButton()),
        ),
      ),
    );
    await tester.pump();

    // SC-013/FR-029: the per-conversation web quick toggle meets the floor in both axes.
    final size = tester.getSize(find.byKey(WebToggleButton.buttonKey));
    expect(size.width, greaterThanOrEqualTo(AppSpacing.minTouchTarget));
    expect(size.height, greaterThanOrEqualTo(AppSpacing.minTouchTarget));
  });

  testWidgets('source URL chips clear the 48dp height floor (SC-013)', (
    tester,
  ) async {
    // SourceUrlChips reads webUrlLauncherProvider (provided by the harness); render a couple
    // of chips and assert the FIRST. Multiple chips share the same key (intentional), so the
    // finder must be disambiguated with .first.
    final container = makeContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.dark,
          home: const Scaffold(
            body: SourceUrlChips(
              urls: ['https://dart.dev/guides', 'https://flutter.dev'],
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // SC-013: a source chip's width hugs its host label (content-driven and may be < 48dp),
    // so only the tappable HEIGHT is asserted — guaranteed by the chip's `minHeight: 48`.
    final size = tester.getSize(find.byKey(SourceUrlChips.chipKey).first);
    expect(size.height, greaterThanOrEqualTo(AppSpacing.minTouchTarget));
  });

  testWidgets('tool chip is non-interactive but carries a Semantics label (a11y)', (
    tester,
  ) async {
    // ToolChip is intentionally non-interactive in v1 (no tap target → no 48dp floor); the
    // accessibility guarantee instead is a screen-reader label naming the tool + status.
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: Scaffold(
          body: ToolChip(
            message: Message(
              id: 1,
              conversationId: 1,
              role: MessageRole.tool,
              content: '3 results for "latest dart version"',
              sequence: 0,
              createdAt: DateTime.utc(2026, 6, 14),
              status: MessageStatus.complete,
              toolName: 'web_search',
              toolArgs: const {'query': 'latest dart version'},
              toolStatus: ToolCallStatus.success,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // SC-013: the screen reader announces the tool, its status, and the summary.
    expect(
      find.bySemanticsLabel(
        'tool web_search: success — 3 results for "latest dart version"',
      ),
      findsOneWidget,
    );
  });
}
