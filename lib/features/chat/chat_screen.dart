import 'package:ai_assistant/app/router.dart';
import 'package:ai_assistant/app/theme/app_colors.dart';
import 'package:ai_assistant/app/theme/app_spacing.dart';
import 'package:ai_assistant/app/theme/app_text.dart';
import 'package:ai_assistant/app/widgets/dot_pulse.dart';
import 'package:ai_assistant/core/model_catalog.dart';
import 'package:ai_assistant/features/chat/chat_controller.dart';
import 'package:ai_assistant/features/chat/chat_providers.dart';
import 'package:ai_assistant/features/chat/widgets/composer.dart';
import 'package:ai_assistant/features/chat/widgets/message_bubble.dart';
import 'package:ai_assistant/infrastructure/gemma/flutter_gemma_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The chat surface (US2). Loads the model on entry and releases it on exit (autoDispose) and on
/// app-background (the [AppLifecycleListener] below — `onDispose` does not fire on backgrounding,
/// R5). Renders the streaming reply incrementally with an always-available stop in the composer.
class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key});

  static const Key errorBannerKey = Key('chat-error-banner');
  static const Key errorDismissKey = Key('chat-error-dismiss');

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    // Resource hygiene (FR-029, Principle VIII): free the ~2.4 GB model when backgrounded, reload
    // it on return.
    _lifecycle = AppLifecycleListener(
      onStateChange: (state) {
        switch (state) {
          case AppLifecycleState.paused:
          case AppLifecycleState.detached:
          case AppLifecycleState.hidden:
            ref.read(gemmaServiceProvider).close();
          case AppLifecycleState.resumed:
            ref.invalidate(modelSessionProvider);
          case AppLifecycleState.inactive:
            break;
        }
      },
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final session = ref.watch(modelSessionProvider);

    return Scaffold(
      appBar: AppBar(
        titleSpacing: AppSpacing.s16,
        title: Text(AppText.spec('${ModelCatalog.displayName} · on-device'),
            style: theme.textTheme.labelSmall),
        actions: [
          IconButton(
            tooltip: 'new conversation',
            icon: const Icon(Icons.add),
            onPressed: () => ref.read(chatControllerProvider.notifier).openConversation(null),
          ),
          IconButton(
            tooltip: 'history',
            icon: const Icon(Icons.history),
            onPressed: () => Navigator.of(context).pushNamed(AppRoutes.history),
          ),
          IconButton(
            tooltip: 'settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.of(context).pushNamed(AppRoutes.settings),
          ),
        ],
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(1),
          child: Divider(height: 1),
        ),
      ),
      body: session.when(
        loading: () => const _ModelLoading(),
        error: (error, _) => _ModelError(message: '$error'),
        data: (_) => const _ChatBody(),
      ),
    );
  }
}

class _ModelLoading extends StatelessWidget {
  const _ModelLoading();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const DotPulse(),
          const SizedBox(height: AppSpacing.s16),
          Text(AppText.spec('loading model…'), style: theme.textTheme.labelSmall),
        ],
      ),
    );
  }
}

class _ModelError extends StatelessWidget {
  const _ModelError({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.extension<AppColors>()!;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.heroPadding),
        child: Text(
          'could not load the model on this device.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyLarge?.copyWith(color: colors.textSecondary),
        ),
      ),
    );
  }
}

class _ChatBody extends ConsumerStatefulWidget {
  const _ChatBody();

  @override
  ConsumerState<_ChatBody> createState() => _ChatBodyState();
}

class _ChatBodyState extends ConsumerState<_ChatBody> {
  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final conversationId = ref.watch(chatControllerProvider.select((s) => s.conversationId));
    final errorMessage = ref.watch(chatControllerProvider.select((s) => s.errorMessage));

    return Column(
      children: [
        Expanded(
          child: conversationId == null
              ? const _EmptyChat()
              : _MessageList(conversationId: conversationId, scroll: _scroll, onChanged: _scrollToBottom),
        ),
        if (errorMessage != null)
          _ErrorBanner(
            message: errorMessage,
            onDismiss: () => ref.read(chatControllerProvider.notifier).dismissError(),
          ),
        const Padding(
          padding: EdgeInsets.fromLTRB(
            AppSpacing.s16,
            AppSpacing.s8,
            AppSpacing.s16,
            AppSpacing.s12,
          ),
          child: SafeArea(top: false, child: Composer()),
        ),
      ],
    );
  }
}

/// A clear, dismissible failure message (FR-020) — e.g. an image the model couldn't process. Uses
/// the reserved accent for the error glyph (design-system §2/§8); the conversation stays usable.
class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message, required this.onDismiss});

  final String message;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.extension<AppColors>()!;
    return Container(
      key: ChatScreen.errorBannerKey,
      margin: const EdgeInsets.fromLTRB(AppSpacing.s16, AppSpacing.s8, AppSpacing.s16, 0),
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s12, vertical: AppSpacing.s8),
      decoration: BoxDecoration(
        color: colors.surfaceContainer,
        borderRadius: BorderRadius.circular(AppSpacing.radiusControl),
        border: Border.all(color: colors.outline),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, color: colors.accent, size: AppSpacing.s24),
          const SizedBox(width: AppSpacing.s8),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.bodyMedium?.copyWith(color: colors.textSecondary),
            ),
          ),
          IconButton(
            key: ChatScreen.errorDismissKey,
            tooltip: 'dismiss',
            onPressed: onDismiss,
            icon: Icon(Icons.close, color: colors.textSecondary),
          ),
        ],
      ),
    );
  }
}

class _MessageList extends ConsumerWidget {
  const _MessageList({
    required this.conversationId,
    required this.scroll,
    required this.onChanged,
  });

  final int conversationId;
  final ScrollController scroll;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final messages = ref.watch(chatMessagesProvider(conversationId));
    return messages.when(
      loading: () => const SizedBox.shrink(),
      error: (error, _) => Center(child: Text('$error')),
      data: (list) {
        if (list.isEmpty) return const _EmptyChat();
        onChanged();
        return ListView.builder(
          controller: scroll,
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.s16,
            vertical: AppSpacing.s12,
          ),
          itemCount: list.length,
          itemBuilder: (context, index) => MessageBubble(message: list[index]),
        );
      },
    );
  }
}

class _EmptyChat extends StatelessWidget {
  const _EmptyChat();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.extension<AppColors>()!;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('gemma', style: AppText.dotMatrix(fontSize: 40, color: colors.textPrimary)),
          const SizedBox(height: AppSpacing.s8),
          Text('ask anything. it stays on your device.', style: theme.textTheme.bodyMedium),
        ],
      ),
    );
  }
}
