import 'package:ai_assistant/app/root_gate.dart';
import 'package:ai_assistant/app/theme/app_text.dart';
import 'package:ai_assistant/domain/entities/device_capability.dart';
import 'package:ai_assistant/features/chat/chat_screen.dart';
import 'package:ai_assistant/features/download/download_screen.dart';
import 'package:ai_assistant/features/history/history_screen.dart';
import 'package:ai_assistant/features/onboarding/license_screen.dart';
import 'package:ai_assistant/features/onboarding/preflight_blocked_screen.dart';
import 'package:ai_assistant/features/settings/memory_screen.dart';
import 'package:ai_assistant/features/settings/settings_screen.dart';
import 'package:ai_assistant/features/settings/web_research_screen.dart';
import 'package:flutter/material.dart';

/// Named routes for the app's primary screens.
abstract final class AppRoutes {
  /// First-run gate: decides onboarding vs chat from install state (T029).
  static const String root = '/';
  static const String license = '/license';
  static const String preflightBlocked = '/blocked';
  static const String download = '/download';
  static const String chat = '/chat';
  static const String history = '/history';
  static const String settings = '/settings';
  static const String memory = '/memory';
  static const String webResearch = '/web-research';
}

/// Route table. Onboarding/download/chat are real screens (US1/US2); history and settings remain
/// skeletons until their phases (US4 / Polish).
abstract final class AppRouter {
  static Route<dynamic> onGenerateRoute(RouteSettings settings) {
    final WidgetBuilder builder = switch (settings.name) {
      AppRoutes.root => (_) => const RootGate(),
      AppRoutes.license => (_) => const LicenseScreen(),
      AppRoutes.preflightBlocked => (_) => PreflightBlockedScreen(
        reason:
            (settings.arguments as IneligibleReason?) ??
            IneligibleReason.insufficientMemory,
      ),
      AppRoutes.download => (_) => const DownloadScreen(),
      AppRoutes.chat => (_) => const ChatScreen(),
      AppRoutes.history => (_) => const HistoryScreen(),
      AppRoutes.settings => (_) => const SettingsScreen(),
      AppRoutes.memory => (_) => const MemoryScreen(),
      AppRoutes.webResearch => (_) => const WebResearchSettingsScreen(),
      _ => (_) => const _RouteSkeleton(label: 'not found'),
    };
    return MaterialPageRoute<dynamic>(builder: builder, settings: settings);
  }
}

/// Placeholder for routes not yet built (history → US4, settings → Polish).
class _RouteSkeleton extends StatelessWidget {
  const _RouteSkeleton({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(AppText.spec(label), style: theme.textTheme.labelSmall),
      ),
      body: Center(
        child: Text(
          AppText.spec('$label · coming soon'),
          style: theme.textTheme.labelSmall,
        ),
      ),
    );
  }
}
