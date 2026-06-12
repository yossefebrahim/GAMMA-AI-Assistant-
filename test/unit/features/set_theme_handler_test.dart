import 'package:ai_assistant/data/repositories/settings_repository.dart';
import 'package:ai_assistant/domain/entities/app_settings.dart';
import 'package:ai_assistant/domain/entities/tool_outcome.dart';
import 'package:ai_assistant/features/chat/tool_handler_providers.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/container_harness.dart';

/// 004 US2 — the set_theme handler binds the EXISTING persisted theme mechanism, flips the theme,
/// reports idempotent `alreadyActive`, and delegates persistence. Over a real in-memory drift DB
/// (the settings row), via the real dispatcher.
void main() {
  test('flips the theme and persists it (delegation)', () async {
    final container = makeContainer();
    addTearDown(container.dispose);
    // Default is dark; switch to light.
    final outcome = await container.read(toolDispatcherProvider).dispatch(
      'set_theme',
      const {'theme': 'light'},
    );

    expect(outcome, isA<ToolSuccess>());
    final success = outcome as ToolSuccess;
    expect(success.result['theme'], 'light');
    expect(success.result['alreadyActive'], false);
    expect(container.read(themeModeProvider), AppThemeMode.light);
    // Persisted (the row reflects the change).
    expect(
      (await container.read(settingsRepositoryProvider).read()).themeMode,
      AppThemeMode.light,
    );
  });

  test(
    'same-theme request → idempotent success with alreadyActive: true (FR-014)',
    () async {
      final container = makeContainer();
      addTearDown(container.dispose);
      // Default theme is dark — asking for dark again is already-active.
      final outcome = await container.read(toolDispatcherProvider).dispatch(
        'set_theme',
        const {'theme': 'dark'},
      );

      final success = outcome as ToolSuccess;
      expect(success.result['alreadyActive'], true);
      expect(container.read(themeModeProvider), AppThemeMode.dark);
    },
  );

  test(
    'invalid theme value is rejected by the schema before the handler runs',
    () async {
      final container = makeContainer();
      addTearDown(container.dispose);
      final outcome = await container.read(toolDispatcherProvider).dispatch(
        'set_theme',
        const {'theme': 'sepia'},
      );
      expect(outcome, isA<ToolInvalidArgs>());
      // The theme is untouched.
      expect(container.read(themeModeProvider), AppThemeMode.dark);
    },
  );
}
