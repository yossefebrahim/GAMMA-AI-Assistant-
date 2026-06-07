import 'package:ai_assistant/app/router.dart';
import 'package:ai_assistant/app/theme/app_colors.dart';
import 'package:ai_assistant/app/theme/app_spacing.dart';
import 'package:ai_assistant/app/theme/app_text.dart';
import 'package:ai_assistant/domain/entities/conversation.dart';
import 'package:ai_assistant/features/history/history_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Browsable conversation history (FR-019–FR-022). A reactive list of past conversations with
/// first-message labels + timestamps, a new-conversation action, and per-row delete with a
/// destructive-red confirm. Timestamps use `textSecondary` (8.03:1), NOT `textMuted` (research R6
/// AA rule, FR-031).
class HistoryScreen extends ConsumerWidget {
  const HistoryScreen({super.key});

  static const Key newConversationKey = Key('history-new-conversation');

  static Key rowKey(int id) => Key('history-row-$id');
  static Key deleteKey(int id) => Key('history-delete-$id');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final conversations = ref.watch(conversationsProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(AppText.spec('conversations'), style: theme.textTheme.labelSmall),
        actions: [
          IconButton(
            key: newConversationKey,
            tooltip: 'new conversation',
            icon: const Icon(Icons.add),
            onPressed: () {
              ref.read(historyControllerProvider.notifier).newConversation();
              _goToChat(context);
            },
          ),
        ],
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(1),
          child: Divider(height: 1),
        ),
      ),
      body: conversations.when(
        loading: () => const SizedBox.shrink(),
        error: (error, _) => Center(child: Text('$error')),
        data: (list) {
          if (list.isEmpty) return const _EmptyHistory();
          return ListView.separated(
            itemCount: list.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, index) => _ConversationRow(conversation: list[index]),
          );
        },
      ),
    );
  }

  static void _goToChat(BuildContext context) {
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    } else {
      Navigator.of(context).pushReplacementNamed(AppRoutes.chat);
    }
  }
}

class _ConversationRow extends ConsumerWidget {
  const _ConversationRow({required this.conversation});

  final Conversation conversation;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colors = theme.extension<AppColors>()!;
    return ListTile(
      key: HistoryScreen.rowKey(conversation.id),
      contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.s16, vertical: AppSpacing.s4),
      title: Text(
        conversation.title ?? 'untitled',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodyLarge?.copyWith(color: colors.textPrimary),
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: AppSpacing.s4),
        child: Text(
          AppText.spec(_formatTimestamp(conversation.updatedAt)),
          // AA rule (research R6 / FR-031): essential timestamps use textSecondary, not textMuted.
          style: theme.textTheme.labelSmall?.copyWith(color: colors.textSecondary),
        ),
      ),
      trailing: IconButton(
        key: HistoryScreen.deleteKey(conversation.id),
        tooltip: 'delete',
        icon: Icon(Icons.delete_outline, color: colors.textSecondary),
        onPressed: () => _confirmDelete(context, ref),
      ),
      onTap: () {
        ref.read(historyControllerProvider.notifier).openConversation(conversation.id);
        HistoryScreen._goToChat(context);
      },
    );
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref) async {
    final theme = Theme.of(context);
    final colors = theme.extension<AppColors>()!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('delete conversation?', style: theme.textTheme.titleMedium),
        content: Text(
          'this removes the conversation and its messages. it cannot be undone.',
          style: theme.textTheme.bodyMedium?.copyWith(color: colors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            style: TextButton.styleFrom(foregroundColor: colors.textPrimary),
            child: const Text('cancel'),
          ),
          // Destructive action — the one sanctioned red use here (design-system §2).
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: TextButton.styleFrom(foregroundColor: colors.accent),
            child: const Text('delete'),
          ),
        ],
      ),
    );
    if (confirmed ?? false) {
      await ref.read(historyControllerProvider.notifier).deleteConversation(conversation.id);
    }
  }

  static String _formatTimestamp(DateTime utc) {
    const months = [
      'jan', 'feb', 'mar', 'apr', 'may', 'jun',
      'jul', 'aug', 'sep', 'oct', 'nov', 'dec',
    ];
    final local = utc.toLocal();
    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');
    return '${months[local.month - 1]} ${local.day} · $hh:$mm';
  }
}

class _EmptyHistory extends StatelessWidget {
  const _EmptyHistory();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.extension<AppColors>()!;
    return Center(
      child: Text(
        'no conversations yet.',
        style: theme.textTheme.bodyLarge?.copyWith(color: colors.textSecondary),
      ),
    );
  }
}
