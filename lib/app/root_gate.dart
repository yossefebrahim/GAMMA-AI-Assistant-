import 'package:ai_assistant/app/theme/app_colors.dart';
import 'package:ai_assistant/app/theme/app_spacing.dart';
import 'package:ai_assistant/app/theme/app_text.dart';
import 'package:ai_assistant/app/widgets/dot_pulse.dart';
import 'package:ai_assistant/features/chat/chat_providers.dart';
import 'package:ai_assistant/features/chat/chat_screen.dart';
import 'package:ai_assistant/features/onboarding/welcome_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// First-run routing (FR-001, T029): if a verified model is already installed, go straight to
/// chat; otherwise start onboarding. A brief dark splash covers the one-shot install check.
final appStartProvider = FutureProvider<bool>((ref) async {
  final path = await ref.watch(installedModelPathProvider.future);
  return path != null;
});

class RootGate extends ConsumerWidget {
  const RootGate({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final installed = ref.watch(appStartProvider);
    return installed.when(
      data: (isInstalled) =>
          isInstalled ? const ChatScreen() : const WelcomeScreen(),
      loading: () => const _Splash(),
      // Fail safe to onboarding if the check errors (e.g. storage unreadable).
      error: (_, _) => const WelcomeScreen(),
    );
  }
}

class _Splash extends StatelessWidget {
  const _Splash();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.extension<AppColors>()!;
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'gemma',
              style: AppText.dotMatrix(fontSize: 48, color: colors.textPrimary),
            ),
            const SizedBox(height: AppSpacing.s24),
            const DotPulse(),
          ],
        ),
      ),
    );
  }
}
