import 'package:ai_assistant/app/router.dart';
import 'package:ai_assistant/app/theme/app_theme.dart';
import 'package:ai_assistant/data/repositories/settings_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Root of the On-Device Gemma Assistant. Applies the dark-first Material 3 themes and the
/// persisted theme mode (FR-023/FR-024), and delegates navigation to [AppRouter].
class GemmaAssistantApp extends ConsumerWidget {
  const GemmaAssistantApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);
    return MaterialApp(
      title: 'gemma assistant',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: themeMode.material,
      initialRoute: AppRoutes.root,
      onGenerateRoute: AppRouter.onGenerateRoute,
    );
  }
}
