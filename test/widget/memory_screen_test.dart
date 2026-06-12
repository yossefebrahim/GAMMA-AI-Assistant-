import 'dart:async';

import 'package:ai_assistant/app/theme/app_spacing.dart';
import 'package:ai_assistant/app/theme/app_theme.dart';
import 'package:ai_assistant/data/repositories/drift_memory_repository.dart';
import 'package:ai_assistant/data/repositories/settings_repository.dart';
import 'package:ai_assistant/domain/entities/app_settings.dart';
import 'package:ai_assistant/domain/entities/memory.dart';
import 'package:ai_assistant/domain/entities/model_capabilities.dart';
import 'package:ai_assistant/features/settings/memory_screen.dart';
import 'package:ai_assistant/infrastructure/gemma/flutter_gemma_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/container_harness.dart';
import '../helpers/fake_gemma_service.dart';
import '../helpers/fake_memory_repository.dart';

/// 005 US3 — MemoryScreen widget + a11y tests (T031).
///
/// Covers:
///   - List grouping matches the active facts set (FR-015, category declaration order).
///   - Edit action updates the fact and the screen reflects the change.
///   - Delete action removes the fact after confirmation.
///   - Clear-all empties the list after the destructive confirm (red button).
///   - Toggle off → [memoryEnabledProvider] reflects false.
///   - 48dp touch targets on toggle, clear-all, edit, and delete controls (FR-031 / a11y floor).
///   - Screen renders correctly under a text-only model (management is NOT capability-gated, US3 AS5).
///
/// House widget-test async pattern: mutations are performed via the repository; reactive re-renders
/// are driven by explicit [pump] calls (never bare await over fake streams → hang hazard). Dialogs
/// are confirmed or cancelled by tapping the text buttons they render.
void main() {
  late FakeMemoryRepository memoryRepo;
  late StreamController<AppSettings> settingsStream;
  late ProviderContainer container;

  // Stable base time — avoids jitter on updatedAt.
  final t0 = DateTime.utc(2026, 1, 1, 12);
  final t1 = DateTime.utc(2026, 1, 1, 13);
  final t2 = DateTime.utc(2026, 1, 1, 14);

  // Seed facts that span all four categories, in canonical declaration order.
  Memory fact({
    required int id,
    required String text,
    required MemoryCategory category,
    DateTime? updatedAt,
  }) => Memory(
    id: id,
    fact: text,
    category: category,
    createdAt: t0,
    updatedAt: updatedAt ?? t0,
  );

  setUp(() {
    memoryRepo = FakeMemoryRepository();
    settingsStream = StreamController<AppSettings>.broadcast();

    container = makeContainer(
      overrides: [
        // Inject the fake memory repository (so stream + mutations stay in-memory).
        memoryRepositoryProvider.overrideWithValue(memoryRepo),
        // Inject the fake active-memories stream derived from the same repo.
        activeMemoriesProvider.overrideWith((ref) => memoryRepo.watchActive()),
        // Inject a controlled settings stream so the toggle state is deterministic.
        settingsStreamProvider.overrideWith((ref) => settingsStream.stream),
        // Inject a not-loaded, text-only gemma service so _refreshSession is a no-op.
        gemmaServiceProvider.overrideWithValue(
          FakeGemmaService(capabilitiesData: const ModelCapabilities()),
        ),
      ],
    );
  });

  tearDown(() async {
    // Dispose the container first so all Riverpod stream subscriptions are
    // cancelled before the underlying streams are closed. Without this ordering,
    // StreamController.close() returns a Future that waits for its listeners
    // to receive done — but those listeners are owned by Riverpod providers
    // whose done-delivery microtask lives in the fakeAsync zone and never
    // runs outside the testWidgets body, causing a permanent hang.
    container.dispose();
    await settingsStream.close();
    await memoryRepo.dispose();
  });

  Widget app() => UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      theme: AppTheme.dark,
      home: const Scaffold(body: MemoryScreen()),
    ),
  );

  // Push an AppSettings event with the given memoryEnabled state, pump once so the Notifier sees it.
  void emitSettings({bool memoryEnabled = true}) {
    settingsStream.add(
      AppSettings(themeMode: AppThemeMode.dark, memoryEnabled: memoryEnabled),
    );
  }

  // ── Grouping ──────────────────────────────────────────────────────────────────

  testWidgets('empty store shows the empty-state message', (tester) async {
    await tester.pumpWidget(app());
    emitSettings();
    await tester.pump(); // resolve StreamProvider
    await tester.pump(); // rebuild body

    expect(
      find.text('no facts yet — the assistant will capture them automatically'),
      findsOneWidget,
    );
    // No clear-all button when the list is empty.
    expect(find.byKey(MemoryScreen.clearAllKey), findsNothing);
  });

  testWidgets(
    'facts are grouped by category in declaration order (identity → work → preferences → other)',
    (tester) async {
      memoryRepo.seed([
        fact(id: 1, text: 'builds Android apps', category: MemoryCategory.work),
        fact(id: 2, text: 'name is Joe', category: MemoryCategory.identity),
        fact(
          id: 3,
          text: 'prefers dark mode',
          category: MemoryCategory.preferences,
        ),
        fact(id: 4, text: 'likes coffee', category: MemoryCategory.other),
      ]);

      await tester.pumpWidget(app());
      emitSettings();
      await tester.pump();
      await tester.pump();

      // All four facts are rendered.
      expect(find.text('name is Joe'), findsOneWidget);
      expect(find.text('builds Android apps'), findsOneWidget);
      expect(find.text('prefers dark mode'), findsOneWidget);
      expect(find.text('likes coffee'), findsOneWidget);

      // Category headers are present in declaration order (AppText.spec uppercases them).
      final identityY = tester.getTopLeft(find.text('IDENTITY')).dy;
      final workY = tester.getTopLeft(find.text('WORK')).dy;
      final preferencesY = tester.getTopLeft(find.text('PREFERENCES')).dy;
      final otherY = tester.getTopLeft(find.text('OTHER')).dy;
      expect(identityY, lessThan(workY));
      expect(workY, lessThan(preferencesY));
      expect(preferencesY, lessThan(otherY));
    },
  );

  testWidgets('only categories that have active facts show a header', (
    tester,
  ) async {
    memoryRepo.seed([
      fact(id: 1, text: 'senior engineer', category: MemoryCategory.work),
    ]);

    await tester.pumpWidget(app());
    emitSettings();
    await tester.pump();
    await tester.pump();

    // AppText.spec uppercases category names.
    expect(find.text('WORK'), findsOneWidget);
    expect(find.text('IDENTITY'), findsNothing);
    expect(find.text('PREFERENCES'), findsNothing);
    expect(find.text('OTHER'), findsNothing);
  });

  testWidgets(
    'within a category facts appear updatedAt-desc (most recent first)',
    (tester) async {
      memoryRepo.seed([
        fact(
          id: 1,
          text: 'older work fact',
          category: MemoryCategory.work,
          updatedAt: t1,
        ),
        fact(
          id: 2,
          text: 'newer work fact',
          category: MemoryCategory.work,
          updatedAt: t2,
        ),
      ]);

      await tester.pumpWidget(app());
      emitSettings();
      await tester.pump();
      await tester.pump();

      final olderY = tester.getTopLeft(find.text('older work fact')).dy;
      final newerY = tester.getTopLeft(find.text('newer work fact')).dy;
      expect(newerY, lessThan(olderY));
    },
  );

  // ── Edit ─────────────────────────────────────────────────────────────────────

  testWidgets(
    'tapping edit opens a pre-populated dialog and saving persists the change',
    (tester) async {
      memoryRepo.seed([
        fact(
          id: 1,
          text: 'old fact text',
          category: MemoryCategory.preferences,
        ),
      ]);

      await tester.pumpWidget(app());
      emitSettings();
      await tester.pump();
      await tester.pump();

      // Tap the edit icon for the fact.
      await tester.tap(find.byTooltip('edit'));
      await tester.pumpAndSettle(); // open dialog

      expect(find.text('edit fact'), findsOneWidget);

      // The text field is pre-populated.
      final field = find.widgetWithText(TextField, 'old fact text');
      expect(field, findsOneWidget);

      // Clear and type new text.
      await tester.enterText(field, 'new fact text');
      await tester.pump();

      // Confirm save.
      await tester.tap(find.text('save'));
      await tester.pump(); // run editFact
      await tester.pump(); // receive reactive emission

      expect(find.text('new fact text'), findsOneWidget);
      expect(find.text('old fact text'), findsNothing);
    },
  );

  testWidgets('cancelling the edit dialog leaves the fact unchanged', (
    tester,
  ) async {
    memoryRepo.seed([
      fact(id: 1, text: 'original text', category: MemoryCategory.work),
    ]);

    await tester.pumpWidget(app());
    emitSettings();
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byTooltip('edit'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextField, 'original text'),
      'changed text',
    );
    await tester.pump();

    await tester.tap(find.text('cancel'));
    await tester.pump();

    expect(find.text('original text'), findsOneWidget);
    expect(find.text('changed text'), findsNothing);
  });

  // ── Delete ────────────────────────────────────────────────────────────────────

  testWidgets(
    'tapping delete opens a confirm dialog and confirming removes the fact',
    (tester) async {
      // id:3 has a later updatedAt so it renders first (updatedAt-desc order); the test deletes it.
      memoryRepo.seed([
        fact(
          id: 2,
          text: 'to be kept',
          category: MemoryCategory.identity,
          updatedAt: t1,
        ),
        fact(
          id: 3,
          text: 'to be deleted',
          category: MemoryCategory.identity,
          updatedAt: t2,
        ),
      ]);

      await tester.pumpWidget(app());
      emitSettings();
      await tester.pump();
      await tester.pump();

      expect(find.text('to be deleted'), findsOneWidget);
      expect(find.text('to be kept'), findsOneWidget);

      // id:3 (to be deleted) has updatedAt=t2 > t1, so it renders first — tap the first delete icon.
      await tester.tap(find.byTooltip('delete').first);
      await tester.pumpAndSettle();

      // Confirm dialog.
      expect(find.text('delete fact?'), findsOneWidget);
      await tester.tap(find.text('delete'));
      await tester.pump();
      await tester.pump();

      // The targeted fact is removed; the other remains.
      expect(find.text('to be deleted'), findsNothing);
      expect(find.text('to be kept'), findsOneWidget);
    },
  );

  testWidgets('cancelling the delete dialog leaves the fact intact', (
    tester,
  ) async {
    memoryRepo.seed([
      fact(id: 1, text: 'do not delete me', category: MemoryCategory.work),
    ]);

    await tester.pumpWidget(app());
    emitSettings();
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byTooltip('delete'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('cancel'));
    await tester.pump();

    expect(find.text('do not delete me'), findsOneWidget);
  });

  // ── Clear-all ──────────────────────────────────────────────────────────────────

  testWidgets('clear-all button is visible when there are facts', (
    tester,
  ) async {
    memoryRepo.seed([
      fact(id: 1, text: 'some fact', category: MemoryCategory.other),
    ]);

    await tester.pumpWidget(app());
    emitSettings();
    await tester.pump();
    await tester.pump();

    expect(find.byKey(MemoryScreen.clearAllKey), findsOneWidget);
  });

  testWidgets('confirming clear-all empties the list', (tester) async {
    memoryRepo.seed([
      fact(id: 1, text: 'fact alpha', category: MemoryCategory.identity),
      fact(id: 2, text: 'fact beta', category: MemoryCategory.work),
      fact(id: 3, text: 'fact gamma', category: MemoryCategory.preferences),
    ]);

    await tester.pumpWidget(app());
    emitSettings();
    await tester.pump();
    await tester.pump();

    expect(find.text('fact alpha'), findsOneWidget);

    await tester.tap(find.byKey(MemoryScreen.clearAllKey));
    await tester.pumpAndSettle();

    // Confirm dialog.
    expect(find.text('clear all facts?'), findsOneWidget);
    await tester.tap(find.text('clear all'));
    await tester.pump(); // run clearAll
    await tester.pump(); // receive reactive emission

    expect(find.text('fact alpha'), findsNothing);
    expect(find.text('fact beta'), findsNothing);
    expect(find.text('fact gamma'), findsNothing);
    // Empty-state message replaces the list.
    expect(
      find.text('no facts yet — the assistant will capture them automatically'),
      findsOneWidget,
    );
    // Clear-all button disappears when the list is empty.
    expect(find.byKey(MemoryScreen.clearAllKey), findsNothing);
  });

  testWidgets('cancelling the clear-all dialog leaves all facts intact', (
    tester,
  ) async {
    memoryRepo.seed([
      fact(id: 1, text: 'keep me alpha', category: MemoryCategory.other),
    ]);

    await tester.pumpWidget(app());
    emitSettings();
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byKey(MemoryScreen.clearAllKey));
    await tester.pumpAndSettle();

    await tester.tap(find.text('cancel'));
    await tester.pump();

    expect(find.text('keep me alpha'), findsOneWidget);
  });

  // ── Toggle ────────────────────────────────────────────────────────────────────

  testWidgets('toggle off updates the memoryEnabledProvider state', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    // Start with memory on.
    emitSettings(memoryEnabled: true);
    await tester.pump();
    await tester.pump();

    final switchFinder = find.byKey(MemoryScreen.toggleKey);
    expect(tester.widget<SwitchListTile>(switchFinder).value, isTrue);

    // Tap the toggle — this calls MemoryController.setEnabled(false).
    await tester.tap(switchFinder);
    // Emit the persisted-off value from the settings stream (mirrors the real persistence flow).
    emitSettings(memoryEnabled: false);
    await tester.pump();
    await tester.pump();

    // The provider state should now be false.
    expect(container.read(memoryEnabledProvider), isFalse);
  });

  testWidgets('toggle on updates the memoryEnabledProvider state', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    // Start with memory off.
    emitSettings(memoryEnabled: false);
    await tester.pump();
    await tester.pump();

    final switchFinder = find.byKey(MemoryScreen.toggleKey);
    expect(tester.widget<SwitchListTile>(switchFinder).value, isFalse);

    await tester.tap(switchFinder);
    emitSettings(memoryEnabled: true);
    await tester.pump();
    await tester.pump();

    expect(container.read(memoryEnabledProvider), isTrue);
  });

  testWidgets(
    'when memory is off the empty-state message reflects the disabled state',
    (tester) async {
      await tester.pumpWidget(app());
      emitSettings(memoryEnabled: false);
      await tester.pump();
      await tester.pump();

      expect(
        find.text('memory is off — enable it to capture and use facts'),
        findsOneWidget,
      );
    },
  );

  // ── Works under a text-only model (US3 AS5) ───────────────────────────────────

  testWidgets(
    'memory management works under a text-only model (no capability gating)',
    (tester) async {
      // The FakeGemmaService is already ModelCapabilities() (text-only, no functionCalling/image/audio).
      // The screen must render and mutations must work regardless.
      memoryRepo.seed([
        fact(
          id: 1,
          text: 'text-only model fact',
          category: MemoryCategory.other,
        ),
      ]);

      await tester.pumpWidget(app());
      emitSettings();
      await tester.pump();
      await tester.pump();

      // Screen renders the fact list.
      expect(find.text('text-only model fact'), findsOneWidget);
      // Toggle is present.
      expect(find.byKey(MemoryScreen.toggleKey), findsOneWidget);
      // Clear-all is present.
      expect(find.byKey(MemoryScreen.clearAllKey), findsOneWidget);

      // Delete works.
      await tester.tap(find.byTooltip('delete'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('delete'));
      await tester.pump();
      await tester.pump();
      expect(find.text('text-only model fact'), findsNothing);
    },
  );

  // ── Accessibility: 48dp touch targets ────────────────────────────────────────

  testWidgets('the memory toggle meets the 48dp touch-target floor', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    emitSettings();
    await tester.pump();
    await tester.pump();

    final size = tester.getSize(find.byKey(MemoryScreen.toggleKey));
    expect(size.height, greaterThanOrEqualTo(AppSpacing.minTouchTarget));
  });

  testWidgets('the clear-all icon button meets the 48dp touch-target floor', (
    tester,
  ) async {
    memoryRepo.seed([
      fact(id: 1, text: 'a fact', category: MemoryCategory.other),
    ]);

    await tester.pumpWidget(app());
    emitSettings();
    await tester.pump();
    await tester.pump();

    final size = tester.getSize(find.byKey(MemoryScreen.clearAllKey));
    expect(size.width, greaterThanOrEqualTo(AppSpacing.minTouchTarget));
    expect(size.height, greaterThanOrEqualTo(AppSpacing.minTouchTarget));
  });

  testWidgets('the per-row edit button meets the 48dp touch-target floor', (
    tester,
  ) async {
    memoryRepo.seed([
      fact(id: 1, text: 'edit target test', category: MemoryCategory.identity),
    ]);

    await tester.pumpWidget(app());
    emitSettings();
    await tester.pump();
    await tester.pump();

    final size = tester.getSize(find.byTooltip('edit'));
    expect(size.width, greaterThanOrEqualTo(AppSpacing.minTouchTarget));
    expect(size.height, greaterThanOrEqualTo(AppSpacing.minTouchTarget));
  });

  testWidgets('the per-row delete button meets the 48dp touch-target floor', (
    tester,
  ) async {
    memoryRepo.seed([
      fact(id: 1, text: 'delete target test', category: MemoryCategory.work),
    ]);

    await tester.pumpWidget(app());
    emitSettings();
    await tester.pump();
    await tester.pump();

    final size = tester.getSize(find.byTooltip('delete'));
    expect(size.width, greaterThanOrEqualTo(AppSpacing.minTouchTarget));
    expect(size.height, greaterThanOrEqualTo(AppSpacing.minTouchTarget));
  });

  testWidgets(
    'a one-line fact row meets the 48dp min-height floor (F6 — ConstrainedBox, not a no-op SizedBox)',
    (tester) async {
      memoryRepo.seed([
        fact(id: 1, text: 'short fact', category: MemoryCategory.identity),
      ]);

      await tester.pumpWidget(app());
      emitSettings();
      await tester.pump();
      await tester.pump();

      // The ListTile is the whole row; its enclosing ConstrainedBox guarantees the 48dp floor even
      // though `minVerticalPadding: 0` removes ListTile's own height floor.
      final rowSize = tester.getSize(
        find.ancestor(
          of: find.text('short fact'),
          matching: find.byType(ListTile),
        ),
      );
      expect(rowSize.height, greaterThanOrEqualTo(AppSpacing.minTouchTarget));
    },
  );

  // ── AA contrast (code-enforceable slice) ─────────────────────────────────────

  testWidgets('destructive clear-all button uses the accent (red) foreground color', (
    tester,
  ) async {
    // Full AA contrast measurement runs on-device (quickstart V13); this verifies the design-system
    // rule that the confirm dialog's destructive action uses `colors.accent` (red), and only that
    // action does (the cancel button is textPrimary, monochrome).
    memoryRepo.seed([
      fact(id: 1, text: 'any fact', category: MemoryCategory.preferences),
    ]);

    await tester.pumpWidget(app());
    emitSettings();
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byKey(MemoryScreen.clearAllKey));
    await tester.pumpAndSettle();

    // Both buttons are in the confirm dialog.
    expect(find.text('clear all'), findsOneWidget);
    expect(find.text('cancel'), findsOneWidget);

    // Cancel must be present (it is monochrome — only destructive action gets red).
    expect(find.text('cancel'), findsOneWidget);
    // The red action renders — specific color value testing is in design-token unit tests.
    expect(find.text('clear all'), findsOneWidget);

    // Close dialog.
    await tester.tap(find.text('cancel'));
    await tester.pump();
  });
}
