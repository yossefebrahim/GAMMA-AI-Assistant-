import 'package:ai_assistant/app/theme/app_colors.dart';
import 'package:ai_assistant/app/theme/app_spacing.dart';
import 'package:ai_assistant/app/theme/app_text.dart';
import 'package:ai_assistant/data/repositories/settings_repository.dart';
import 'package:ai_assistant/features/settings/web_research_controller.dart';
import 'package:ai_assistant/features/settings/widgets/settings_section_header.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Web research settings (006, US2). BYOK Tavily-key entry, a global on/off toggle (off by default,
/// blocked without a key — FR-005), key masking after save (FR-003), a clear-key action (FR-004),
/// and the three mandatory FR-002 privacy disclosures.
///
/// Monochrome throughout (design-system §2). Red is reserved for the destructive clear-key action
/// only. The raw key is NEVER read back from storage into a field (FR-003) — once saved, the field
/// is replaced by a masked "saved — tap to replace" affordance; tapping it re-opens the entry field.
class WebResearchSettingsScreen extends ConsumerStatefulWidget {
  const WebResearchSettingsScreen({super.key});

  // Test keys.
  static const Key toggleKey = Key('web-toggle');
  static const Key keyFieldKey = Key('web-key-field');
  static const Key saveKeyButtonKey = Key('web-save-key');
  static const Key savedMaskKey = Key('web-saved-mask');
  static const Key clearKeyButtonKey = Key('web-clear-key');
  static const Key noKeyPromptKey = Key('web-no-key-prompt');

  @override
  ConsumerState<WebResearchSettingsScreen> createState() =>
      _WebResearchSettingsScreenState();
}

class _WebResearchSettingsScreenState
    extends ConsumerState<WebResearchSettingsScreen> {
  final TextEditingController _keyController = TextEditingController();

  /// Whether a key is currently stored. Loaded asynchronously on init and after every mutation —
  /// the raw key value never enters widget state (FR-003), only this boolean.
  bool _hasKey = false;

  /// When true, the entry field is shown even though a key is stored (the user tapped "replace").
  bool _editing = false;

  /// Transient prompt shown when the user tries to enable the toggle without a key (FR-005).
  bool _showNoKeyPrompt = false;

  @override
  void initState() {
    super.initState();
    _refreshHasKey();
  }

  @override
  void dispose() {
    _keyController.dispose();
    super.dispose();
  }

  Future<void> _refreshHasKey() async {
    final hasKey = await ref
        .read(webResearchControllerProvider.notifier)
        .hasValidKey();
    if (!mounted) return;
    setState(() => _hasKey = hasKey);
  }

  Future<void> _save() async {
    final key = _keyController.text.trim();
    if (key.isEmpty) return;
    await ref.read(webResearchControllerProvider.notifier).saveKey(key);
    _keyController.clear();
    if (!mounted) return;
    setState(() {
      _editing = false;
      _showNoKeyPrompt = false;
    });
    await _refreshHasKey();
  }

  Future<void> _clear() async {
    await ref.read(webResearchControllerProvider.notifier).clearKey();
    _keyController.clear();
    if (!mounted) return;
    setState(() {
      _editing = false;
      _showNoKeyPrompt = false;
    });
    await _refreshHasKey();
  }

  Future<void> _onToggle(bool value) async {
    final applied = await ref
        .read(webResearchControllerProvider.notifier)
        .setGlobalToggle(value);
    if (!mounted) return;
    // FR-005: enabling without a key is rejected — surface the prompt and leave the toggle off.
    setState(() => _showNoKeyPrompt = value && !applied);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.extension<AppColors>()!;
    final webEnabled = ref.watch(webAccessEnabledProvider);
    final showField = !_hasKey || _editing;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          AppText.spec('web research'),
          style: theme.textTheme.labelSmall,
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.s8),
        children: [
          // ── Global toggle ────────────────────────────────────────────────────
          const SettingsSectionHeader(label: 'web access'),
          SwitchListTile(
            key: WebResearchSettingsScreen.toggleKey,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.s16,
              vertical: AppSpacing.s4,
            ),
            title: Text('allow web research', style: theme.textTheme.bodyLarge),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: AppSpacing.s4),
              child: Text(
                webEnabled
                    ? 'the assistant can search the web and read pages'
                    : 'the assistant answers from its own knowledge only',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: colors.textSecondary,
                ),
              ),
            ),
            value: webEnabled,
            // Monochrome thumb/track — no accent on toggles (design-system §2 accent discipline).
            activeThumbColor: colors.textPrimary,
            activeTrackColor: colors.surfaceContainerHigh,
            inactiveThumbColor: colors.textMuted,
            inactiveTrackColor: colors.outline,
            onChanged: _onToggle,
          ),
          if (_showNoKeyPrompt)
            Padding(
              key: WebResearchSettingsScreen.noKeyPromptKey,
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.s16,
                0,
                AppSpacing.s16,
                AppSpacing.s8,
              ),
              child: Text(
                'enter a tavily key first to enable web research',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: colors.accent,
                ),
              ),
            ),
          const Divider(height: AppSpacing.hairline),

          // ── BYOK key ─────────────────────────────────────────────────────────
          const SettingsSectionHeader(label: 'tavily key'),
          if (showField) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s16),
              child: TextField(
                key: WebResearchSettingsScreen.keyFieldKey,
                controller: _keyController,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                style: theme.textTheme.bodyLarge,
                decoration: InputDecoration(
                  hintText: 'paste your tavily api key',
                  hintStyle: theme.textTheme.bodyLarge?.copyWith(
                    color: colors.textMuted,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(
                      AppSpacing.radiusControl,
                    ),
                    borderSide: BorderSide(color: colors.outline),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(
                      AppSpacing.radiusControl,
                    ),
                    borderSide: BorderSide(color: colors.outline),
                  ),
                ),
                onSubmitted: (_) => _save(),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.s16,
                AppSpacing.s8,
                AppSpacing.s16,
                AppSpacing.s8,
              ),
              child: Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  key: WebResearchSettingsScreen.saveKeyButtonKey,
                  onPressed: _save,
                  style: TextButton.styleFrom(
                    foregroundColor: colors.textPrimary,
                    minimumSize: const Size(0, AppSpacing.s48),
                  ),
                  child: const Text('save key'),
                ),
              ),
            ),
          ] else
            ListTile(
              key: WebResearchSettingsScreen.savedMaskKey,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.s16,
                vertical: AppSpacing.s4,
              ),
              title: Text(
                'saved — tap to replace',
                style: theme.textTheme.bodyLarge,
              ),
              subtitle: Padding(
                padding: const EdgeInsets.only(top: AppSpacing.s4),
                child: Text(
                  AppText.spec('••••••••••••'),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
              ),
              trailing: TextButton(
                key: WebResearchSettingsScreen.clearKeyButtonKey,
                onPressed: _clear,
                style: TextButton.styleFrom(
                  foregroundColor: colors.accent,
                  minimumSize: const Size(0, AppSpacing.s48),
                ),
                child: const Text('clear key'),
              ),
              onTap: () => setState(() => _editing = true),
            ),
          const Divider(height: AppSpacing.hairline),

          // ── Privacy disclosures (FR-002 — all three mandatory, lowercase) ────
          const SettingsSectionHeader(label: 'privacy'),
          const _Disclosure(
            text: 'search queries are sent to tavily\'s servers',
          ),
          const _Disclosure(
            text:
                'when you fetch a page, your device contacts that website '
                'directly — not tavily',
          ),
          const _Disclosure(text: 'your key never leaves your device'),
        ],
      ),
    );
  }
}

/// One FR-002 privacy disclosure line — lowercase, secondary text, spec-sheet voice.
class _Disclosure extends StatelessWidget {
  const _Disclosure({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.extension<AppColors>()!;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s16,
        vertical: AppSpacing.s8,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.lock_outline,
            size: AppSpacing.s16,
            color: colors.textSecondary,
          ),
          const SizedBox(width: AppSpacing.s8),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colors.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
