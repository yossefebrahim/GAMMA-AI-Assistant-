import 'package:ai_assistant/data/repositories/drift_memory_repository.dart';
import 'package:ai_assistant/data/repositories/settings_repository.dart';
import 'package:ai_assistant/domain/entities/app_settings.dart';
import 'package:ai_assistant/domain/entities/memory.dart';
import 'package:ai_assistant/domain/services/clipboard_tool_service.dart';
import 'package:ai_assistant/domain/services/device_info_tool_service.dart';
import 'package:ai_assistant/domain/services/network_research_service.dart';
import 'package:ai_assistant/domain/services/secure_key_store.dart';
import 'package:ai_assistant/domain/services/timer_intent_service.dart';
import 'package:ai_assistant/domain/services/tool_dispatcher.dart';
import 'package:ai_assistant/domain/services/web_url_launcher.dart';
import 'package:ai_assistant/infrastructure/network/flutter_secure_key_store.dart';
import 'package:ai_assistant/infrastructure/network/tavily_network_research_service.dart';
import 'package:ai_assistant/infrastructure/tools/android_intent_url_launcher.dart';
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

/// The secure key store seam (006 T017). Overridable in tests with [FakeSecureKeyStore].
///
/// The concrete [FlutterSecureKeyStore] is the ONLY file permitted to import
/// `flutter_secure_storage` (Principle VII, check_network_seam.sh). All other code
/// interacts via this provider's [SecureKeyStore] interface.
final secureKeyStoreProvider = Provider<SecureKeyStore>((ref) {
  return FlutterSecureKeyStore();
});

/// The source-URL-chip browser hand-off seam (006 T033, FR-013). Overridable in tests with a fake
/// [WebUrlLauncher] so a chip tap can be asserted without firing a real Android intent.
///
/// The concrete [AndroidIntentUrlLauncher] (in `lib/infrastructure/tools/`) is one of only two
/// importers of `android_intent_plus` (Principle VII, check_plugin_seam.sh).
final webUrlLauncherProvider = Provider<WebUrlLauncher>((ref) {
  return const AndroidIntentUrlLauncher();
});

/// The network research seam (006 T017). Overridable in tests with [FakeNetworkResearchService].
///
/// The concrete [TavilyNetworkResearchService] is the ONLY file permitted to import
/// `package:http` (Principle VII, check_network_seam.sh). All other code interacts via this
/// provider's [NetworkResearchService] interface.
final networkResearchServiceProvider = Provider<NetworkResearchService>((ref) {
  final keyStore = ref.watch(secureKeyStoreProvider);
  return TavilyNetworkResearchService(keyStore: keyStore);
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
  //
  // Structural StateError guard shared by both web handlers (contracts/web_research_tools.md): the
  // triple gate should have prevented declaration without a valid key, so reaching a web handler
  // with no key is a coding error — surfaced as a ToolFailure (the dispatcher catches the throw),
  // never a silent call. The StateError type + message are part of that contract.
  Future<void> requireKey() async {
    if (!await ref.read(secureKeyStoreProvider).hasValidKey()) {
      throw StateError('web tools called without a valid key');
    }
  }

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
    // web_search (006 US1): searches via Tavily and returns the top ≤ 3 results as
    // {title, url, content, score} objects — the field name is `content`, NOT `snippet` (FR-010).
    // The query is schema-validated (non-empty, ≤ 400 chars) before reaching here.
    //
    // Structural StateError guard (contracts/web_research_tools.md): the triple gate should have
    // prevented declaration without a valid key, so reaching the handler with no key is a coding
    // error — surfaced as a ToolFailure (the dispatcher catches the throw), never a silent call.
    //
    // ResearchError subtypes thrown by the seam propagate out of the closure and are mapped to a
    // plain-language ToolFailure by the dispatcher's catch (see ResearchError → message table). The
    // service is reached only via the NetworkResearchService interface — no plugin import here
    // (Principle VII).
    'web_search': (args) async {
      await requireKey();
      final query = args['query'] as String;
      final results = await ref
          .read(networkResearchServiceProvider)
          .search(query);
      if (results.isEmpty) {
        return const {
          'results': <Object?>[],
          'note': 'no results found — answering from own knowledge',
        };
      }
      // `content` is Tavily's field name and MUST NOT be renamed (FR-010). `sourceUrls` is the
      // answer-grounding reference rendered as tappable source URL chips (FR-013, Decision 4).
      //
      // Pre-truncate each `content` value so the SERIALISED result stays within the spec's 2,000-char
      // bound (FR-014). The dispatcher's `resultCharBound` is the belt-and-braces safety net, but it
      // can only shrink TOP-LEVEL string values — it cannot reach into the nested `results` array —
      // so the handler is the primary truncation site for web_search (contracts/web_research_tools.md
      // §Dispatcher coercion/bounding 1). The per-result budget divides the content allowance evenly.
      final contentBudget = (_kWebSearchContentBudget / results.length).floor();
      return {
        'results': [
          for (final r in results)
            {
              'title': r.title,
              'url': r.url,
              'content': _truncate(r.content, contentBudget),
              'score': r.score,
            },
        ],
        'sourceUrls': [for (final r in results) r.url],
      };
    },
    // fetch_page (006 US4): bound in checkpoint 2 (T036). Declared here in checkpoint 1 only when
    // the triple gate is true; the registry/handler congruence test asserts the map covers exactly
    // the declared names.
    'fetch_page': (args) async {
      await requireKey();
      final url = args['url'] as String;
      final result = await ref
          .read(networkResearchServiceProvider)
          .fetchPage(url);
      return {
        'url': result.url,
        'text': result.extractedText,
        'truncated': result.wasTruncated,
        'sourceUrls': [result.url],
      };
    },
  };
});

/// The dispatcher consuming [toolHandlersProvider].
final toolDispatcherProvider = Provider<ToolDispatcher>((ref) {
  return ToolDispatcher(handlers: ref.watch(toolHandlersProvider));
});

/// Combined character allowance shared across the ≤ 3 `web_search` result `content` snippets so the
/// serialised tool result stays within the spec's 2,000-char bound (FR-014). Sized conservatively
/// to leave headroom for the surrounding JSON keys, titles, urls, scores, and `sourceUrls` array.
const int _kWebSearchContentBudget = 1500;

/// Hard-truncate [text] to [maxChars] characters, appending an ellipsis when clipped. Used by the
/// `web_search` handler to pre-truncate each result's content before serialisation.
String _truncate(String text, int maxChars) {
  if (maxChars <= 0) return '';
  if (text.length <= maxChars) return text;
  return '${text.substring(0, maxChars)}…';
}

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
/// A WRITABLE manual Notifier (house pattern) — NOT a plain `Provider`, which can only be set at
/// container-creation time and so could never carry the live conversation id. `ChatController` calls
/// [ActiveConversationId.set] whenever the open conversation changes (`openConversation`, and the
/// lazy-create path in `send`) so the `remember_fact` handler reads the CURRENT id at dispatch time
/// and persists it as [Memory.sourceConversationId] (contract guarantee 4 — provenance is injected
/// by the framework, never a tool argument).
///
/// This provider exists to break a potential import cycle: `chat_controller.dart` imports THIS file
/// (`tool_handler_providers.dart`), so this file cannot import `chat_controller.dart` in return.
/// The dependency flows one way: controller → handlers. Tests can drive it through a real
/// `ProviderContainer` (set the id, then dispatch) or override it outright.
class ActiveConversationId extends Notifier<int?> {
  @override
  int? build() => null;

  void set(int? id) => state = id;
}

final activeConversationIdProvider =
    NotifierProvider<ActiveConversationId, int?>(ActiveConversationId.new);
