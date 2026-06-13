import 'package:ai_assistant/app/theme/app_colors.dart';
import 'package:ai_assistant/app/theme/app_spacing.dart';
import 'package:ai_assistant/app/theme/app_text.dart';
import 'package:ai_assistant/data/repositories/drift_memory_repository.dart';
import 'package:ai_assistant/data/repositories/settings_repository.dart';
import 'package:ai_assistant/domain/entities/memory.dart';
import 'package:ai_assistant/features/settings/memory_controller.dart';
import 'package:ai_assistant/features/settings/widgets/settings_section_header.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Memory management screen (005, US3). Lists durable facts grouped by category in the same order
/// as the injected facts block (FR-015); per-row edit + delete; clear-all behind a destructive
/// confirm dialog; a global on/off toggle. NOT capability-gated — management works under any model
/// (text-only or otherwise). Monochrome throughout; red is reserved for destructive actions only
/// (design-system §2 accent discipline).
class MemoryScreen extends ConsumerWidget {
  const MemoryScreen({super.key});

  // Test keys (mirrors settings_screen.dart convention).
  static const Key toggleKey = Key('memory-toggle');
  static const Key clearAllKey = Key('memory-clear-all');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colors = theme.extension<AppColors>()!;
    final memoryEnabled = ref.watch(memoryEnabledProvider);
    final memoriesAsync = ref.watch(activeMemoriesProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(AppText.spec('memory'), style: theme.textTheme.labelSmall),
        actions: [
          // Global clear-all — only visible when there are facts.
          memoriesAsync.maybeWhen(
            data: (facts) => facts.isEmpty
                ? const SizedBox.shrink()
                : IconButton(
                    key: clearAllKey,
                    icon: const Icon(Icons.delete_sweep_outlined),
                    tooltip: 'clear all facts',
                    onPressed: () => _confirmClearAll(context, ref),
                  ),
            orElse: () => const SizedBox.shrink(),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.s8),
        children: [
          // ── Toggle ──────────────────────────────────────────────────────────
          const SettingsSectionHeader(label: 'memory'),
          SwitchListTile(
            key: toggleKey,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.s16,
              vertical: AppSpacing.s4,
            ),
            title: Text(
              'remember facts across chats',
              style: theme.textTheme.bodyLarge,
            ),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: AppSpacing.s4),
              child: Text(
                memoryEnabled
                    ? 'facts are captured and injected automatically'
                    : 'facts are stored but not used',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: colors.textSecondary,
                ),
              ),
            ),
            value: memoryEnabled,
            // Monochrome thumb/track — no accent on toggles (design-system §2 accent discipline).
            activeThumbColor: colors.textPrimary,
            activeTrackColor: colors.surfaceContainerHigh,
            inactiveThumbColor: colors.textMuted,
            inactiveTrackColor: colors.outline,
            onChanged: (value) =>
                ref.read(memoryControllerProvider.notifier).setEnabled(value),
          ),
          const Divider(height: AppSpacing.hairline),

          // ── Facts by category ───────────────────────────────────────────────
          const SettingsSectionHeader(label: 'facts'),
          memoriesAsync.when(
            loading: () => const Padding(
              padding: EdgeInsets.all(AppSpacing.s24),
              child: Center(child: CircularProgressIndicator(strokeWidth: 1)),
            ),
            error: (e, st) => Padding(
              padding: const EdgeInsets.all(AppSpacing.s16),
              child: Text(
                'could not load facts',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colors.textSecondary,
                ),
              ),
            ),
            data: (facts) => facts.isEmpty
                ? _EmptyState(memoryEnabled: memoryEnabled)
                : _FactList(facts: facts),
          ),
        ],
      ),
    );
  }

  /// Destructive confirm — uses red (accent) ONLY on the destructive action button (design-system §2).
  Future<void> _confirmClearAll(BuildContext context, WidgetRef ref) async {
    final theme = Theme.of(context);
    final colors = theme.extension<AppColors>()!;
    final confirmed = await showDialog<bool>(
      context: context,
      // No animation so dismiss completes in a single pump() — required by the
      // widget test pattern (pump() does not elapse fake-clock time, so a
      // non-zero DialogRoute animation never finishes in test).
      animationStyle: AnimationStyle.noAnimation,
      builder: (dialogContext) => AlertDialog(
        title: Text('clear all facts?', style: theme.textTheme.titleMedium),
        content: Text(
          'this permanently removes every saved fact. '
          'the assistant will start fresh in future chats.',
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
          // Red is the ONLY color, on destructive actions only.
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: TextButton.styleFrom(foregroundColor: colors.accent),
            child: const Text('clear all'),
          ),
        ],
      ),
    );
    if (confirmed ?? false) {
      await ref.read(memoryControllerProvider.notifier).clearAll();
    }
  }
}

// ── Category-grouped fact list ─────────────────────────────────────────────────

class _FactList extends ConsumerWidget {
  const _FactList({required this.facts});

  final List<Memory> facts;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Group by category in declaration order (MemoryCategory: identity, work, preferences, other).
    final grouped = <MemoryCategory, List<Memory>>{};
    for (final m in facts) {
      grouped.putIfAbsent(m.category, () => []).add(m);
    }

    // Render each category that has at least one fact, in enum declaration order (FR-015).
    final sections = <Widget>[];
    for (final category in MemoryCategory.values) {
      final group = grouped[category];
      if (group == null || group.isEmpty) continue;

      sections.add(_CategoryHeader(category: category));
      for (final memory in group) {
        sections.add(_FactRow(memory: memory));
        sections.add(
          const Divider(height: AppSpacing.hairline, indent: AppSpacing.s16),
        );
      }
    }

    return Column(children: sections);
  }
}

// ── Category header ────────────────────────────────────────────────────────────

class _CategoryHeader extends StatelessWidget {
  const _CategoryHeader({required this.category});

  final MemoryCategory category;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.extension<AppColors>()!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.s16,
        AppSpacing.s12,
        AppSpacing.s16,
        AppSpacing.s4,
      ),
      child: Text(
        AppText.spec(category.name),
        style: theme.textTheme.labelSmall?.copyWith(color: colors.textMuted),
      ),
    );
  }
}

// ── Fact row ──────────────────────────────────────────────────────────────────

class _FactRow extends ConsumerWidget {
  const _FactRow({required this.memory});

  final Memory memory;

  /// Edit/delete icon glyph size (the 48dp touch target is the enclosing SizedBox; the glyph is
  /// smaller for visual weight). Named so the literal isn't repeated across both buttons (F8).
  static const double _iconSize = 20;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colors = theme.extension<AppColors>()!;

    return ConstrainedBox(
      // 48dp minimum touch-target floor for the whole row (accessibility — Principle VI, FR-024).
      // A min (not fixed) height so a fact that wraps to two lines still grows; `minVerticalPadding:
      // 0` removes ListTile's own padding-based floor, so this constraint is what guarantees it.
      constraints: const BoxConstraints(minHeight: AppSpacing.minTouchTarget),
      child: ListTile(
        minVerticalPadding: 0,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.s16,
          vertical: AppSpacing.s4,
        ),
        title: Text(memory.fact, style: theme.textTheme.bodyLarge),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: AppSpacing.s4),
          child: Text(
            '#${memory.id}',
            style: theme.textTheme.labelSmall?.copyWith(
              color: colors.textMuted,
            ),
          ),
        ),
        // Trailing action row — edit + delete. Each icon button is its own 48dp touch target
        // (the SizedBox below); the row's own min height comes from the ConstrainedBox above.
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Edit — monochrome (not destructive).
            SizedBox(
              width: AppSpacing.s48,
              height: AppSpacing.s48,
              child: IconButton(
                icon: Icon(
                  Icons.edit_outlined,
                  color: colors.textSecondary,
                  size: _iconSize,
                ),
                tooltip: 'edit',
                onPressed: () => _showEditDialog(context, ref),
              ),
            ),
            // Delete — monochrome icon; confirm dialog uses red on the destructive button.
            SizedBox(
              width: AppSpacing.s48,
              height: AppSpacing.s48,
              child: IconButton(
                icon: Icon(
                  Icons.delete_outline,
                  color: colors.textSecondary,
                  size: _iconSize,
                ),
                tooltip: 'delete',
                onPressed: () => _confirmDelete(context, ref),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showEditDialog(BuildContext context, WidgetRef ref) async {
    final theme = Theme.of(context);
    final colors = theme.extension<AppColors>()!;

    // Pre-populate the edit fields with the current values.
    final factController = TextEditingController(text: memory.fact);
    MemoryCategory selectedCategory = memory.category;

    final committed = await showDialog<_EditResult>(
      context: context,
      // No animation — required by the widget test pattern (see _confirmClearAll).
      animationStyle: AnimationStyle.noAnimation,
      builder: (dialogContext) => StatefulBuilder(
        builder: (innerContext, setState) => AlertDialog(
          title: Text('edit fact', style: theme.textTheme.titleMedium),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Fact text field.
              TextField(
                controller: factController,
                style: theme.textTheme.bodyLarge,
                maxLength: 80,
                decoration: InputDecoration(
                  hintText: 'fact',
                  hintStyle: theme.textTheme.bodyLarge?.copyWith(
                    color: colors.textMuted,
                  ),
                  counterStyle: theme.textTheme.labelSmall?.copyWith(
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
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(
                      AppSpacing.radiusControl,
                    ),
                    borderSide: BorderSide(color: colors.textPrimary),
                  ),
                ),
                autofocus: true,
              ),
              const SizedBox(height: AppSpacing.s12),
              // Category selector — monochrome DropdownButton.
              Text(
                AppText.spec('category'),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: colors.textSecondary,
                ),
              ),
              const SizedBox(height: AppSpacing.s8),
              DropdownButton<MemoryCategory>(
                value: selectedCategory,
                isExpanded: true,
                underline: Container(
                  height: AppSpacing.hairline,
                  color: colors.outline,
                ),
                dropdownColor: colors.surface,
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: colors.textPrimary,
                ),
                items: MemoryCategory.values
                    .map(
                      (c) => DropdownMenuItem(
                        value: c,
                        child: Text(c.name, style: theme.textTheme.bodyLarge),
                      ),
                    )
                    .toList(),
                onChanged: (c) {
                  if (c != null) setState(() => selectedCategory = c);
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(null),
              style: TextButton.styleFrom(foregroundColor: colors.textPrimary),
              child: const Text('cancel'),
            ),
            TextButton(
              onPressed: () {
                final text = factController.text.trim();
                if (text.isNotEmpty) {
                  Navigator.of(
                    dialogContext,
                  ).pop(_EditResult(fact: text, category: selectedCategory));
                }
              },
              style: TextButton.styleFrom(foregroundColor: colors.textPrimary),
              child: const Text('save'),
            ),
          ],
        ),
      ),
    );
    if (committed != null) {
      await ref
          .read(memoryControllerProvider.notifier)
          .edit(memory.id, committed.fact, committed.category);
    }
    // factController is intentionally not disposed here. The dialog's
    // dismissal animation keeps the widget in the tree briefly after showDialog
    // returns, so calling dispose() immediately would cause "used after dispose"
    // errors when the animation rebuild runs. The controller is function-scoped
    // and short-lived; the GC reclaims it when the function exits.
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref) async {
    final theme = Theme.of(context);
    final colors = theme.extension<AppColors>()!;
    final confirmed = await showDialog<bool>(
      context: context,
      // No animation — required by the widget test pattern (see _confirmClearAll).
      animationStyle: AnimationStyle.noAnimation,
      builder: (dialogContext) => AlertDialog(
        title: Text('delete fact?', style: theme.textTheme.titleMedium),
        content: Text(
          '"${memory.fact}"',
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
          // Red is the ONLY color, on destructive actions only (design-system §2).
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: TextButton.styleFrom(foregroundColor: colors.accent),
            child: const Text('delete'),
          ),
        ],
      ),
    );
    if (confirmed ?? false) {
      await ref.read(memoryControllerProvider.notifier).delete(memory.id);
    }
  }
}

// ── Empty state ────────────────────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.memoryEnabled});

  final bool memoryEnabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.extension<AppColors>()!;
    final message = memoryEnabled
        ? 'no facts yet — the assistant will capture them automatically'
        : 'memory is off — enable it to capture and use facts';

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.heroPadding,
        vertical: AppSpacing.s32,
      ),
      child: Center(
        child: Text(
          message,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: colors.textSecondary,
          ),
        ),
      ),
    );
  }
}

// ── Internal transfer object ───────────────────────────────────────────────────

class _EditResult {
  const _EditResult({required this.fact, required this.category});

  final String fact;
  final MemoryCategory category;
}
