import 'package:ai_assistant/app/theme/app_colors.dart';
import 'package:ai_assistant/app/theme/app_theme.dart';
import 'package:ai_assistant/app/widgets/dot_pulse.dart';
import 'package:ai_assistant/domain/entities/message.dart';
import 'package:ai_assistant/domain/entities/tool_outcome.dart';
import 'package:ai_assistant/features/chat/widgets/tool_chip.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 004 US1 / data-model §5 — the monochrome ToolChip renders all four states from tokens only (no
/// hardcoded hex), carries a Semantics label, and is non-interactive. Red is the sanctioned accent
/// for the error state ONLY (Principle VI/X).
void main() {
  Widget host(Message message) => MaterialApp(
        theme: AppTheme.light,
        darkTheme: AppTheme.dark,
        themeMode: ThemeMode.dark,
        home: Scaffold(body: ToolChip(message: message)),
      );

  Message toolRow({
    required ToolCallStatus status,
    String content = '',
    Map<String, Object?>? args,
    Map<String, Object?>? result,
  }) =>
      Message(
        id: 1,
        conversationId: 1,
        role: MessageRole.tool,
        content: content,
        sequence: 0,
        createdAt: DateTime.utc(2026, 6, 10),
        status: MessageStatus.complete,
        toolName: 'get_device_info',
        toolArgs: args,
        toolStatus: status,
        toolResult: result,
      );

  testWidgets('success: mono tag, args summary, quiet result line', (tester) async {
    await tester.pumpWidget(host(toolRow(
      status: ToolCallStatus.success,
      content: 'battery 83%',
      args: const {'section': 'battery'},
    )));
    await tester.pump();

    expect(find.text('TOOL · GET_DEVICE_INFO'), findsOneWidget);
    expect(find.byKey(ToolChip.argsKey), findsOneWidget);
    expect(find.text('battery 83%'), findsOneWidget);
  });

  testWidgets('running: shows the dot-pulse, no result line', (tester) async {
    await tester.pumpWidget(host(toolRow(status: ToolCallStatus.running)));
    await tester.pump();

    expect(find.byKey(ToolChip.runningKey), findsOneWidget);
    expect(find.byType(DotPulse), findsOneWidget);
    expect(find.byKey(ToolChip.contentKey), findsNothing);
  });

  testWidgets('error: the error glyph uses the sanctioned accent (red)', (tester) async {
    await tester.pumpWidget(host(toolRow(
      status: ToolCallStatus.error,
      content: 'clipboard empty or not text',
    )));
    await tester.pump();

    const colors = AppColors.dark;
    final icon = tester.widget<Icon>(find.byIcon(Icons.error_outline));
    expect(icon.color, colors.accent, reason: 'error is the sanctioned red use');
    expect(find.text('clipboard empty or not text'), findsOneWidget);
  });

  testWidgets('skipped: shows the skipped spec line', (tester) async {
    await tester.pumpWidget(host(toolRow(status: ToolCallStatus.skipped, content: 'skipped')));
    await tester.pump();
    expect(find.text('skipped'), findsOneWidget);
  });

  testWidgets('carries a Semantics label naming tool + status', (tester) async {
    await tester.pumpWidget(host(toolRow(
      status: ToolCallStatus.success,
      content: 'battery 83%',
    )));
    await tester.pump();
    expect(find.bySemanticsLabel('tool get_device_info: success — battery 83%'), findsOneWidget);
  });

  testWidgets('is non-interactive — no tap target (InkWell / GestureDetector)', (tester) async {
    await tester.pumpWidget(host(toolRow(status: ToolCallStatus.success, content: 'ok')));
    await tester.pump();
    expect(find.byType(InkWell), findsNothing);
    expect(find.byType(GestureDetector), findsNothing);
  });
}
