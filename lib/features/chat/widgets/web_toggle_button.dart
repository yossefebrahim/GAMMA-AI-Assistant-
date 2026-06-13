import 'package:ai_assistant/app/theme/app_colors.dart';
import 'package:ai_assistant/app/theme/app_spacing.dart';
import 'package:ai_assistant/data/repositories/settings_repository.dart';
import 'package:ai_assistant/domain/entities/web_access_override.dart';
import 'package:ai_assistant/features/chat/chat_controller.dart';
import 'package:ai_assistant/features/chat/chat_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The composer's three-state per-conversation web-access quick toggle (006 US3, T044, FR-008/FR-029).
///
/// Cycles `inherit → on → off → inherit` on each tap. The button's INITIAL state for a new
/// conversation inherits the global default ([webAccessEnabledProvider]) — a fresh thread with no
/// persisted override reads as `inherit` and shows the global on/off as its effective state. The
/// EFFECTIVE flag (whether web tools are actually active for this conversation) is
/// `override.effectiveWebEnabled(global)`; a visible active indicator (filled globe + a hairline
/// accent ring) is shown whenever that resolves true (FR-029).
///
/// Visible only when the active model can call tools (the sole render guard in `composer.dart`
/// checks `capabilities.functionCalling`) — there is no point offering a per-conversation web toggle
/// when the model can never declare tools. Function calling is a necessary but not sufficient
/// condition for web tools to be ACTIVE: effective enablement still requires a stored Tavily key via
/// the triple gate (`functionCalling && effectiveWebEnabled && hasValidKey`) enforced in
/// [modelSessionProvider]. The toggle can therefore show even without a key — flipping it on simply
/// has no effect until a key is added.
///
/// Tapping persists the new override and recreates the session with the recomputed tool list
/// (handled by [ChatController.toggleWebAccess], T045) BEFORE the next user turn (FR-032).
class WebToggleButton extends ConsumerWidget {
  const WebToggleButton({super.key});

  static const Key buttonKey = Key('composer-web-toggle');
  static const Key activeIndicatorKey = Key('composer-web-toggle-active');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = Theme.of(context).extension<AppColors>()!;
    final conversationId = ref.watch(
      chatControllerProvider.select((s) => s.conversationId),
    );
    final globalEnabled = ref.watch(webAccessEnabledProvider);

    // The per-conversation override (null = inherit). For a not-yet-created thread there is no row,
    // so it resolves to inherit synchronously below.
    final WebAccessOverride override = conversationId == null
        ? WebAccessOverride.inherit
        : ref
              .watch(conversationWebOverrideProvider(conversationId))
              .maybeWhen(
                data: (value) => value ?? WebAccessOverride.inherit,
                orElse: () => WebAccessOverride.inherit,
              );

    final effectiveOn = override.effectiveWebEnabled(globalEnabled);

    final tooltip = switch (override) {
      WebAccessOverride.inherit =>
        effectiveOn
            ? 'web access: following global (on)'
            : 'web access: following global (off)',
      WebAccessOverride.on => 'web access: on for this chat',
      WebAccessOverride.off => 'web access: off for this chat',
    };

    final icon = effectiveOn ? Icons.public : Icons.public_off;
    // Monochrome by default; the active state gets the sanctioned accent ring + filled glyph so the
    // "web is on for this conversation" affordance is visible at a glance (FR-029, Principle X — the
    // accent here is a bold/large active indicator, not body text).
    final foreground = effectiveOn ? colors.textPrimary : colors.textSecondary;

    return Tooltip(
      message: tooltip,
      child: IconButton(
        key: WebToggleButton.buttonKey,
        // Always tappable. Before a thread exists there is no row to persist the override against,
        // so the tap is a no-op ([ChatController.toggleWebAccess] returns early when
        // `conversationId == null`); an unsaved fresh thread still shows the inherited global state.
        onPressed: () => ref
            .read(chatControllerProvider.notifier)
            .toggleWebAccess(override.next),
        style: IconButton.styleFrom(
          foregroundColor: foreground,
          minimumSize: const Size(
            AppSpacing.minTouchTarget,
            AppSpacing.minTouchTarget,
          ),
          side: effectiveOn
              ? BorderSide(color: colors.accent, width: AppSpacing.hairline)
              : BorderSide.none,
          shape: const CircleBorder(),
        ),
        icon: Icon(
          icon,
          key: effectiveOn ? WebToggleButton.activeIndicatorKey : null,
        ),
      ),
    );
  }
}

/// The `inherit → on → off → inherit` cycle used by the composer quick toggle (T044).
extension WebAccessOverrideCycle on WebAccessOverride {
  WebAccessOverride get next => switch (this) {
    WebAccessOverride.inherit => WebAccessOverride.on,
    WebAccessOverride.on => WebAccessOverride.off,
    WebAccessOverride.off => WebAccessOverride.inherit,
  };
}
