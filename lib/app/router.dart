import 'package:ai_assistant/app/theme/app_spacing.dart';
import 'package:ai_assistant/app/theme/app_text.dart';
import 'package:flutter/material.dart';

/// Named routes for the app's ~6 primary screens.
abstract final class AppRoutes {
  static const String onboarding = '/';
  static const String download = '/download';
  static const String chat = '/chat';
  static const String history = '/history';
  static const String settings = '/settings';
}

/// Route table for the app. The screens here are intentionally **skeletons** — each is replaced
/// by its real feature screen in a later phase:
///   * onboarding/download → US1 (T027–T029)
///   * chat                → US2 (T035) and US4 navigation (T044)
///   * history             → US4 (T043)
///   * settings            → Polish (T048)
///
/// First-run routing (no model installed → onboarding; installed → chat) is wired in T029.
abstract final class AppRouter {
  static Route<dynamic> onGenerateRoute(RouteSettings settings) {
    final WidgetBuilder builder = switch (settings.name) {
      AppRoutes.onboarding => (_) => const _RouteSkeleton(label: 'onboarding'),
      AppRoutes.download => (_) => const _RouteSkeleton(label: 'download'),
      AppRoutes.chat => (_) => const _RouteSkeleton(label: 'chat'),
      AppRoutes.history => (_) => const _RouteSkeleton(label: 'history'),
      AppRoutes.settings => (_) => const _RouteSkeleton(label: 'settings'),
      _ => (_) => const _RouteSkeleton(label: 'not found'),
    };
    return MaterialPageRoute<dynamic>(builder: builder, settings: settings);
  }
}

/// Placeholder screen proving the theme is wired (dark canvas, dot-matrix wordmark, mono spec
/// line). Replaced per-route by the real feature screens in later phases.
class _RouteSkeleton extends StatelessWidget {
  const _RouteSkeleton({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.heroPadding),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('gemma', style: AppText.dotMatrix(fontSize: 40, color: theme.colorScheme.onSurface)),
              const SizedBox(height: AppSpacing.s8),
              Text('everything runs on your device.', style: theme.textTheme.bodyMedium),
              const SizedBox(height: AppSpacing.s24),
              Text(
                AppText.spec('screen · $label'),
                style: theme.textTheme.labelSmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
