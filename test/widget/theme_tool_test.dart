import 'dart:async';

import 'package:ai_assistant/app/theme/app_theme.dart';
import 'package:ai_assistant/data/repositories/settings_repository.dart';
import 'package:ai_assistant/domain/entities/app_settings.dart';
import 'package:ai_assistant/domain/entities/message.dart';
import 'package:ai_assistant/domain/entities/tool_outcome.dart';
import 'package:ai_assistant/features/chat/tool_handler_providers.dart';
import 'package:ai_assistant/features/chat/widgets/tool_chip.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/container_harness.dart';

/// 004 US2 — set_theme flips the app theme LIVE (the rendered brightness changes), and the chip
/// records success including the already-active case. The persisted-settings stream is driven
/// deterministically here (its drift-watch timing under FakeAsync is the model-restore-recipe hang
/// hazard); the handler's real persistence + idempotence is covered by set_theme_handler_test.
void main() {
  late StreamController<AppSettings> settings;
  late ProviderContainer container;

  setUp(() {
    settings = StreamController<AppSettings>.broadcast();
    container = makeContainer(overrides: [
      settingsStreamProvider.overrideWith((ref) => settings.stream),
    ]);
  });

  tearDown(() {
    settings.close();
    container.dispose();
  });

  Widget app(Widget home) => UncontrolledProviderScope(
        container: container,
        child: Consumer(
          builder: (context, ref, _) => MaterialApp(
            theme: AppTheme.light,
            darkTheme: AppTheme.dark,
            themeMode: ref.watch(themeModeProvider).material,
            home: home,
          ),
        ),
      );

  testWidgets('a set_theme change flips the live app theme to light', (tester) async {
    await tester.pumpWidget(app(const Scaffold(body: SizedBox())));
    settings.add(const AppSettings(themeMode: AppThemeMode.dark));
    await tester.pump();
    expect(Theme.of(tester.element(find.byType(Scaffold))).brightness, Brightness.dark);

    // The handler flips the theme (set() updates the controller optimistically); the persisted
    // stream then propagates light. The whole app re-themes live.
    final outcome = await container
        .read(toolDispatcherProvider)
        .dispatch('set_theme', const {'theme': 'light'});
    expect(outcome, isA<ToolSuccess>());
    settings.add(const AppSettings(themeMode: AppThemeMode.light));
    await tester.pump();
    // MaterialApp animates the theme transition (~200ms) — pump past it.
    await tester.pump(const Duration(milliseconds: 400));

    expect(Theme.of(tester.element(find.byType(Scaffold))).brightness, Brightness.light);
  });

  testWidgets('a same-theme turn renders a success chip with the already-active summary',
      (tester) async {
    final chip = Message(
      id: 1,
      conversationId: 1,
      role: MessageRole.tool,
      content: 'theme dark · alreadyactive true',
      sequence: 0,
      createdAt: DateTime.utc(2026, 6, 10),
      status: MessageStatus.complete,
      toolName: 'set_theme',
      toolArgs: const {'theme': 'dark'},
      toolStatus: ToolCallStatus.success,
      toolResult: const {'theme': 'dark', 'alreadyActive': true},
    );

    await tester.pumpWidget(app(Scaffold(body: ToolChip(message: chip))));
    settings.add(const AppSettings(themeMode: AppThemeMode.dark));
    await tester.pump();

    expect(find.text('TOOL · SET_THEME'), findsOneWidget);
    expect(find.text('theme dark · alreadyactive true'), findsOneWidget);
  });
}
