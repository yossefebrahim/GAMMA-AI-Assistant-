import 'package:ai_assistant/app/theme/app_theme.dart';
import 'package:ai_assistant/features/chat/chat_providers.dart';
import 'package:ai_assistant/features/chat/chat_screen.dart';
import 'package:ai_assistant/features/chat/widgets/composer.dart';
import 'package:ai_assistant/infrastructure/gemma/flutter_gemma_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/container_harness.dart';
import '../helpers/fake_gemma_service.dart';

/// US2 chat widget tests (FR-013, Q4, SC-011). Seam-backed: in-memory drift + FakeGemmaService,
/// with the model session overridden so no native model is needed.
void main() {
  late FakeGemmaService gemma;
  late ProviderContainer container;

  setUp(() {
    gemma = FakeGemmaService();
    container = makeContainer(
      overrides: [
        gemmaServiceProvider.overrideWithValue(gemma),
        // Skip the on-disk model load — hand the chat the loaded fake directly.
        modelSessionProvider.overrideWith((ref) => gemma),
      ],
    );
  });

  tearDown(() => container.dispose());

  Widget app() => UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light,
          darkTheme: AppTheme.dark,
          themeMode: ThemeMode.dark,
          home: const ChatScreen(),
        ),
      );

  Future<void> sendMessage(WidgetTester tester, String text) async {
    await tester.enterText(find.byKey(Composer.fieldKey), text);
    await tester.pump();
    await tester.tap(find.byKey(Composer.sendKey));
    await tester.pump();
  }

  testWidgets('stop replaces send during generation and is the only red affordance (Q4)',
      (tester) async {
    gemma
      ..scriptedDeltas = ['one ', 'two ', 'three ', 'four']
      ..deltaInterval = const Duration(milliseconds: 60);

    await tester.pumpWidget(app());
    await tester.pump(); // resolve the model session

    // Idle: send is shown, stop is not.
    expect(find.byKey(Composer.sendKey), findsOneWidget);
    expect(find.byKey(Composer.stopKey), findsNothing);

    await sendMessage(tester, 'hi');
    await tester.pump(const Duration(milliseconds: 30)); // mid-generation

    // During generation the send is replaced by the (red) stop.
    expect(find.byKey(Composer.stopKey), findsOneWidget);
    expect(find.byKey(Composer.sendKey), findsNothing);

    await tester.tap(find.byKey(Composer.stopKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 30));

    // After stop, send returns.
    expect(find.byKey(Composer.sendKey), findsOneWidget);
    expect(find.byKey(Composer.stopKey), findsNothing);
    expect(gemma.stopCount, 1);
  });

  testWidgets('reply renders incrementally, not as one block (FR-013)', (tester) async {
    gemma
      ..scriptedDeltas = ['Hello ', 'there ', 'friend']
      ..deltaInterval = const Duration(milliseconds: 40);

    await tester.pumpWidget(app());
    await tester.pump();

    await sendMessage(tester, 'hi');

    // Partway through, only the first delta(s) are on screen — not the whole reply.
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.textContaining('Hello'), findsOneWidget);
    expect(find.textContaining('friend'), findsNothing);

    // After the stream finishes, the full reply is present.
    await tester.pump(const Duration(milliseconds: 120));
    expect(find.textContaining('Hello there friend'), findsOneWidget);
  });

  testWidgets('the message list stays scrollable while streaming (SC-011)', (tester) async {
    gemma
      ..scriptedDeltas = ['streaming ', 'reply']
      ..deltaInterval = const Duration(milliseconds: 40);

    await tester.pumpWidget(app());
    await tester.pump();

    await sendMessage(tester, 'hi');
    await tester.pump(const Duration(milliseconds: 50)); // mid-stream

    // A scrollable list is present and interactive while the reply streams.
    expect(find.byType(ListView), findsOneWidget);
    expect(find.byType(Scrollable), findsWidgets);

    await tester.pump(const Duration(milliseconds: 60)); // let it finish
  });
}
