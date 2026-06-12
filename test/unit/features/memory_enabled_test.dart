import 'package:ai_assistant/data/repositories/settings_repository.dart';
import 'package:ai_assistant/domain/entities/app_settings.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/container_harness.dart';

/// T027 — memoryEnabled persistence (005 Clarifications Q3).
void main() {
  late ProviderContainer container;

  setUp(() {
    container = makeContainer();
  });

  tearDown(() => container.dispose());

  group('SettingsRepository.readMemoryEnabled / setMemoryEnabled', () {
    test('defaults to true on a fresh row', () async {
      final repo = container.read(settingsRepositoryProvider);
      expect(await repo.readMemoryEnabled(), isTrue);
    });

    test('setMemoryEnabled(false) persists and round-trips as false', () async {
      final repo = container.read(settingsRepositoryProvider);
      await repo.setMemoryEnabled(false);
      expect(await repo.readMemoryEnabled(), isFalse);
    });

    test('setMemoryEnabled(true) after false restores true', () async {
      final repo = container.read(settingsRepositoryProvider);
      await repo.setMemoryEnabled(false);
      await repo.setMemoryEnabled(true);
      expect(await repo.readMemoryEnabled(), isTrue);
    });

    test('setMemoryEnabled does not disturb themeMode', () async {
      final repo = container.read(settingsRepositoryProvider);
      await repo.setThemeMode(AppThemeMode.light);
      await repo.setMemoryEnabled(false);
      final settings = await repo.read();
      expect(settings.themeMode, AppThemeMode.light);
      expect(settings.memoryEnabled, isFalse);
    });
  });

  group('memoryEnabledProvider (MemoryEnabledController)', () {
    test('initial state is true (default)', () {
      expect(container.read(memoryEnabledProvider), isTrue);
    });

    test('set(false) updates state optimistically and persists', () async {
      await container.read(memoryEnabledProvider.notifier).set(false);

      expect(container.read(memoryEnabledProvider), isFalse);
      expect(
        await container.read(settingsRepositoryProvider).readMemoryEnabled(),
        isFalse,
      );
    });

    test('set(true) after set(false) restores true', () async {
      await container.read(memoryEnabledProvider.notifier).set(false);
      await container.read(memoryEnabledProvider.notifier).set(true);

      expect(container.read(memoryEnabledProvider), isTrue);
      expect(
        await container.read(settingsRepositoryProvider).readMemoryEnabled(),
        isTrue,
      );
    });

    test('set does not affect themeModeProvider', () async {
      await container.read(themeModeProvider.notifier).set(AppThemeMode.light);
      await container.read(memoryEnabledProvider.notifier).set(false);

      expect(container.read(themeModeProvider), AppThemeMode.light);
      expect(container.read(memoryEnabledProvider), isFalse);
    });
  });
}
