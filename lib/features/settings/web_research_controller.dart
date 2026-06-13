import 'package:ai_assistant/data/repositories/settings_repository.dart';
import 'package:ai_assistant/features/chat/session_instruction.dart';
import 'package:ai_assistant/features/chat/tool_handler_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Settings-screen controller for web research (006, US2). Mirrors [MemoryController] in shape:
/// holds no state of its own — the global toggle comes from [webAccessEnabledProvider], the
/// presence of a key from [SecureKeyStore.hasValidKey] (NEVER the raw key — FR-003 masking).
///
/// Every mutating method delegates to the secure key store / settings repository, then refreshes
/// the active chat session via [refreshSessionInstruction] so the web tool declarations take effect
/// from the next conversation without a full model reload (FR-032, same session-boundary pattern as
/// 005 facts-refresh).
///
/// FR-003 (masking): the controller NEVER exposes the stored key value. The UI reads only
/// [hasValidKey] to drive the masked "saved — tap to replace" state and the toggle gating. The raw
/// key flows from the form field straight into [saveKey] → the key store and is never read back.
class WebResearchController extends Notifier<void> {
  @override
  void build() {}

  /// Whether a non-empty Tavily key is currently stored (FR-003). Drives the masked-field state and
  /// the toggle gating in the Settings UI WITHOUT passing the raw key value through provider state.
  Future<bool> hasValidKey() {
    return ref.read(secureKeyStoreProvider).hasValidKey();
  }

  /// Persist [key] in the secure key store (FR-003). The key is written straight to encrypted
  /// storage and never echoed back, logged, or placed in persisted Riverpod state. After a key is
  /// stored the global toggle becomes enable-able (it stays at its persisted value here — enabling
  /// is an explicit user action via [setGlobalToggle], FR-005).
  ///
  /// Recomposes the system instruction via [_refreshSession] (FR-032). Note: this does NOT by itself
  /// declare the `web_search` / `fetch_page` tools — like [clearKey]'s caveat, the genuine tool-list
  /// re-declaration happens at the next conversation open (when `modelSessionProvider` re-evaluates
  /// the triple gate at load time); `_refreshSession` here only refreshes the live system instruction.
  Future<void> saveKey(String key) async {
    await ref.read(secureKeyStoreProvider).writeTavilyKey(key);
    await _refreshSession();
  }

  /// Clear the stored key (FR-004). ALL of the following happen atomically from the user's
  /// perspective (contracts/secure_key_store.md §Clear semantics):
  ///   1. the key entry is removed from secure storage;
  ///   2. the global [webAccessEnabled] flag is set to `false` (a cleared key can never satisfy the
  ///      triple gate, so the global toggle must not linger in the on state);
  ///   3. the live session is recreated without web tools (FR-032) — refreshed below.
  ///
  /// The per-conversation override reset (step 3 of the contract) and the genuine tool-list
  /// re-declaration are handled by the chat layer at the next conversation open / by US3 (T045).
  Future<void> clearKey() async {
    await ref.read(secureKeyStoreProvider).clearTavilyKey();
    // A cleared key means the triple gate can never be satisfied — drop the global toggle so the UI
    // and the next session both reflect web-off (FR-004).
    await ref.read(webAccessEnabledProvider.notifier).set(false);
    await _refreshSession();
  }

  /// Set the global web-access toggle (FR-005). Rejects (returns `false`, no state change) when no
  /// key is stored — the toggle cannot be enabled without a key. Disabling is always allowed.
  /// Returns `true` when the new value was applied.
  Future<bool> setGlobalToggle(bool enabled) async {
    if (enabled && !await hasValidKey()) {
      // FR-005: enabling requires a key. Reject without mutating the persisted flag.
      return false;
    }
    await ref.read(webAccessEnabledProvider.notifier).set(enabled);
    await _refreshSession();
    return true;
  }

  /// Recompose the system instruction and recreate the chat session so the change takes effect for
  /// the next conversation (FR-032). No-op when no model is loaded (cold start / between sessions):
  /// the declarations are composed fresh at load time by `modelSessionProvider`.
  Future<void> _refreshSession() => refreshSessionInstruction(ref);
}

final webResearchControllerProvider =
    NotifierProvider<WebResearchController, void>(WebResearchController.new);
