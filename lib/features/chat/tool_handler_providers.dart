import 'package:ai_assistant/data/repositories/drift_memory_repository.dart';
import 'package:ai_assistant/data/repositories/settings_repository.dart';
import 'package:ai_assistant/domain/entities/app_settings.dart';
import 'package:ai_assistant/domain/entities/memory.dart';
import 'package:ai_assistant/domain/services/clipboard_tool_service.dart';
import 'package:ai_assistant/domain/services/device_info_tool_service.dart';
import 'package:ai_assistant/domain/services/timer_intent_service.dart';
import 'package:ai_assistant/domain/services/tool_dispatcher.dart';
import 'package:ai_assistant/infrastructure/tools/clipboard_tool_service.dart';
import 'package:ai_assistant/infrastructure/tools/device_info_tool_service.dart';
import 'package:ai_assistant/infrastructure/tools/timer_intent_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Riverpod wiring for local tools (004 + 005): the registry's handler map + the [ToolDispatcher].
/// The handler map covers EXACTLY the declared registry names (dispatcher guarantee 5 — the
/// congruence test holds at every checkpoint).
///
/// 004 handlers: get_device_info, set_theme, set_timer, summarize_clipboard.
/// 005 handlers: remember_fact, forget_fact (bound to [MemoryRepository]).
/// `tool_handler_providers.dart` is the shared merge point. Each service is overridable in tests.

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
///
/// Memory handlers (005) read the active conversation id from [chatControllerProvider] so the
/// [sourceConversationId] provenance is injected by the framework — never a tool argument (contract
/// guarantee 4). They also guard [memoryEnabledProvider] as a defense for the rare mid-session
/// toggle-off window before [startSession] reapplies (contract guarantee 2).
final toolHandlersProvider = Provider<Map<String, ToolHandler>>((ref) {
  final deviceInfo = ref.watch(deviceInfoToolServiceProvider);
  final timer = ref.watch(timerIntentServiceProvider);
  final clipboard = ref.watch(clipboardToolServiceProvider);
  final memRepo = ref.watch(memoryRepositoryProvider);
  // Read the active conversation id lazily (at dispatch time) so this provider does not need to
  // be rebuilt every time the conversation changes — the closure captures [ref], not the state.
  return <String, ToolHandler>{
    'get_device_info': (args) => deviceInfo.read(args),
    // set_theme (US2) binds the EXISTING persisted theme mechanism; same-theme → idempotent
    // success (FR-014). `theme` is schema-validated to dark|light before the handler runs.
    'set_theme': (args) async {
      final requested = args['theme'] as String;
      final mode = requested == 'light'
          ? AppThemeMode.light
          : AppThemeMode.dark;
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
    // remember_fact (005 US1): normalize/dedupe is handled inside [MemoryRepository.upsert]; the
    // schema validator already enforces fact ≤ 80 chars + valid category before reaching here.
    // Guard: if memory is toggled off in the rare window between session start and the call, return
    // a structured failure rather than silently capturing (contract guarantee 2).
    'remember_fact': (args) async {
      if (!ref.read(memoryEnabledProvider)) {
        throw const _MemoryDisabledException();
      }
      final fact = args['fact'] as String;
      final category = MemoryCategory.values.byName(args['category'] as String);
      // sourceConversationId is injected from the active conversation — not a tool argument
      // (contract guarantee 4). Lazily read so this closure captures ref, not a stale int?.
      final conversationId = ref.read(activeConversationIdProvider);
      final result = await memRepo.upsert(
        fact: fact,
        category: category,
        sourceConversationId: conversationId,
      );
      return switch (result) {
        UpsertCreated(:final memory) => {
          'remembered': memory.fact,
          'category': memory.category.name,
        },
        UpsertSuperseded(:final memory) => {
          'updated': memory.fact,
          'category': memory.category.name,
        },
        UpsertUnchanged(:final memory) => {'noted': memory.fact},
      };
    },
    // forget_fact (005 US5): soft-deletes the fact iff an ACTIVE row with this id exists. A stale
    // or guessed id (spike §4 hazard) returns false → the handler throws → dispatcher catches →
    // ToolFailure('no such fact: <id>'). Integer-double coercion is done upstream by the
    // controller before dispatch (contract guarantee 3).
    'forget_fact': (args) async {
      final id = args['id'] as int;
      final deleted = await memRepo.softDeleteById(id);
      if (!deleted) throw _NoSuchFactException(id);
      return {'forgot': id};
    },
  };
});

/// The dispatcher consuming [toolHandlersProvider].
final toolDispatcherProvider = Provider<ToolDispatcher>((ref) {
  return ToolDispatcher(handlers: ref.watch(toolHandlersProvider));
});

// Private exception types so the dispatcher's _reasonOf sees the bare message (no "Exception: "
// prefix), matching the TimerUnavailableException pattern used by 004 handlers.

class _MemoryDisabledException implements Exception {
  const _MemoryDisabledException();
  @override
  String toString() => 'memory is off';
}

class _NoSuchFactException implements Exception {
  const _NoSuchFactException(this.id);
  final int id;
  @override
  String toString() => 'no such fact: $id';
}

/// The active conversation id for memory provenance (005). Defaults to null (no open conversation).
///
/// This provider exists to break a potential import cycle: `chat_controller.dart` imports THIS file
/// (`tool_handler_providers.dart`), so this file cannot import `chat_controller.dart` in return.
/// Instead, `chat_controller.dart` / `chat_providers.dart` can override this provider (or read it
/// from the notifier's state) at runtime; tests override it with a fixed value to exercise the
/// `remember_fact` handler without a full controller setup. The dependency flows one way:
/// controller → handlers.
final activeConversationIdProvider = Provider<int?>((ref) => null);
