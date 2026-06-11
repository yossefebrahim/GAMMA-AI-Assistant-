import 'package:ai_assistant/data/repositories/settings_repository.dart';
import 'package:ai_assistant/domain/entities/app_settings.dart';
import 'package:ai_assistant/domain/services/clipboard_tool_service.dart';
import 'package:ai_assistant/domain/services/device_info_tool_service.dart';
import 'package:ai_assistant/domain/services/timer_intent_service.dart';
import 'package:ai_assistant/domain/services/tool_dispatcher.dart';
import 'package:ai_assistant/infrastructure/tools/clipboard_tool_service.dart';
import 'package:ai_assistant/infrastructure/tools/device_info_tool_service.dart';
import 'package:ai_assistant/infrastructure/tools/timer_intent_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Riverpod wiring for local tools (004): the registry's handler map + the [ToolDispatcher]. The
/// handler map covers EXACTLY the four registry names (dispatcher guarantee 5 — the congruence test
/// holds at every checkpoint).
///
/// All four handlers are bound: get_device_info (US1), set_theme (US2), set_timer (US4), and
/// summarize_clipboard (US5). `tool_handler_providers.dart` is the shared merge point across those
/// stories. Each underlying service is overridable in tests with a fake.

/// The `get_device_info` seam (US1). Overridable in tests with a fake.
final deviceInfoToolServiceProvider = Provider<DeviceInfoToolService>((ref) {
  return PlatformDeviceInfoToolService();
});

/// The `set_timer` seam (US4). Overridable in tests with a fake.
final timerIntentServiceProvider = Provider<TimerIntentService>((ref) {
  return const AndroidIntentTimerService();
});

/// The `summarize_clipboard` seam (US5). Overridable in tests with a fake.
final clipboardToolServiceProvider = Provider<ClipboardToolService>((ref) {
  return const FlutterClipboardToolService();
});

/// The injected handler map, keyed by registry tool name.
final toolHandlersProvider = Provider<Map<String, ToolHandler>>((ref) {
  final deviceInfo = ref.watch(deviceInfoToolServiceProvider);
  final timer = ref.watch(timerIntentServiceProvider);
  final clipboard = ref.watch(clipboardToolServiceProvider);
  return <String, ToolHandler>{
    'get_device_info': (args) => deviceInfo.read(args),
    // set_theme (US2) binds the EXISTING persisted theme mechanism; same-theme → idempotent
    // success (FR-014). `theme` is schema-validated to dark|light before the handler runs.
    'set_theme': (args) async {
      final requested = args['theme'] as String;
      final mode = requested == 'light' ? AppThemeMode.light : AppThemeMode.dark;
      final alreadyActive = ref.read(themeModeProvider) == mode;
      if (!alreadyActive) await ref.read(themeModeProvider.notifier).set(mode);
      return {'theme': requested, 'alreadyActive': alreadyActive};
    },
    // set_timer (US4): bounds (1..86400 s) are schema-enforced before the handler; the service
    // fires the silent SET_TIMER hand-off (a throw → ToolFailure('no clock app available')).
    'set_timer': (args) async {
      final seconds = args['seconds'] as int;
      final label = args['label'] as String?;
      await timer.setTimer(seconds: seconds, label: label);
      return {'seconds': seconds, 'label': ?label, 'set': true};
    },
    // summarize_clipboard (US5): returns the bounded clipboard text; the SUMMARY happens in the
    // resumed generation. Empty/non-text → ToolFailure('clipboard empty or not text').
    'summarize_clipboard': (args) => clipboard.read(),
  };
});

/// The dispatcher consuming [toolHandlersProvider].
final toolDispatcherProvider = Provider<ToolDispatcher>((ref) {
  return ToolDispatcher(handlers: ref.watch(toolHandlersProvider));
});
