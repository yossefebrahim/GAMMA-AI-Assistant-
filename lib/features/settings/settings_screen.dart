import 'package:ai_assistant/app/router.dart';
import 'package:ai_assistant/app/theme/app_colors.dart';
import 'package:ai_assistant/app/theme/app_spacing.dart';
import 'package:ai_assistant/app/theme/app_text.dart';
import 'package:ai_assistant/core/byte_format.dart';
import 'package:ai_assistant/core/model_catalog.dart';
import 'package:ai_assistant/data/repositories/settings_repository.dart';
import 'package:ai_assistant/domain/entities/app_settings.dart';
import 'package:ai_assistant/features/settings/settings_controller.dart';
import 'package:ai_assistant/features/settings/widgets/settings_section_header.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Settings (Polish). Model storage (on-disk size + delete → reclaim → back to onboarding, FR-030)
/// and the persisted theme toggle (dark / light / system, FR-024). Selected theme shows a
/// monochrome check, never a colored highlight (design-system §8).
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  static const Key deleteModelKey = Key('settings-delete-model');
  static const Key memoryRowKey = Key('settings-memory-row');
  static const Key webResearchRowKey = Key('settings-web-research-row');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colors = theme.extension<AppColors>()!;
    final themeMode = ref.watch(themeModeProvider);
    final storage = ref.watch(modelStorageBytesProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(
          AppText.spec('settings'),
          style: theme.textTheme.labelSmall,
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.s8),
        children: [
          const SettingsSectionHeader(label: 'model'),
          ListTile(
            contentPadding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.s16,
              vertical: AppSpacing.s4,
            ),
            title: Text(
              'model ( ${ModelCatalog.displayName} )',
              style: theme.textTheme.bodyLarge,
            ),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: AppSpacing.s4),
              child: Text(
                AppText.spec(
                  storage.maybeWhen(
                    data: (bytes) =>
                        bytes == null ? 'not installed' : formatBytes(bytes),
                    orElse: () => '…',
                  ),
                ),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: colors.textSecondary,
                ),
              ),
            ),
            trailing: TextButton(
              key: deleteModelKey,
              onPressed: () => _confirmDelete(context, ref),
              style: TextButton.styleFrom(foregroundColor: colors.accent),
              child: const Text('delete'),
            ),
          ),
          const Divider(height: AppSpacing.hairline),
          const SettingsSectionHeader(label: 'appearance'),
          for (final mode in AppThemeMode.values)
            ListTile(
              contentPadding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.s16,
                vertical: AppSpacing.s4,
              ),
              title: Text(mode.name, style: theme.textTheme.bodyLarge),
              trailing: themeMode == mode
                  // Selected = monochrome check, not a colored highlight.
                  ? Icon(Icons.check, color: colors.textPrimary)
                  : null,
              onTap: () =>
                  ref.read(settingsControllerProvider.notifier).setTheme(mode),
            ),
          const Divider(height: AppSpacing.hairline),
          const SettingsSectionHeader(label: 'memory'),
          ListTile(
            key: memoryRowKey,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.s16,
              vertical: AppSpacing.s4,
            ),
            title: Text('durable facts', style: theme.textTheme.bodyLarge),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: AppSpacing.s4),
              child: Text(
                AppText.spec(
                  'facts the assistant remembers across conversations',
                ),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: colors.textSecondary,
                ),
              ),
            ),
            trailing: Icon(Icons.chevron_right, color: colors.textSecondary),
            onTap: () => Navigator.of(context).pushNamed(AppRoutes.memory),
          ),
          const Divider(height: AppSpacing.hairline),
          const SettingsSectionHeader(label: 'web research'),
          ListTile(
            key: webResearchRowKey,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.s16,
              vertical: AppSpacing.s4,
            ),
            title: Text('web access', style: theme.textTheme.bodyLarge),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: AppSpacing.s4),
              child: Text(
                AppText.spec('byok tavily key · search + read pages'),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: colors.textSecondary,
                ),
              ),
            ),
            trailing: Icon(Icons.chevron_right, color: colors.textSecondary),
            onTap: () => Navigator.of(context).pushNamed(AppRoutes.webResearch),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref) async {
    final theme = Theme.of(context);
    final colors = theme.extension<AppColors>()!;
    final navigator = Navigator.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('delete the model?', style: theme.textTheme.titleMedium),
        content: Text(
          'this frees the ~2.4 gb on disk. you will need to download it again to chat.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: colors.textSecondary,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            style: TextButton.styleFrom(foregroundColor: colors.textPrimary),
            child: const Text('cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: TextButton.styleFrom(foregroundColor: colors.accent),
            child: const Text('delete'),
          ),
        ],
      ),
    );
    if (confirmed ?? false) {
      await ref.read(settingsControllerProvider.notifier).deleteModel();
      // Reclaimed → return to onboarding (no model installed anymore).
      await navigator.pushNamedAndRemoveUntil(AppRoutes.root, (route) => false);
    }
  }
}
