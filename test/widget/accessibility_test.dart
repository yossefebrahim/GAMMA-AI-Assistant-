import 'package:ai_assistant/app/theme/app_spacing.dart';
import 'package:ai_assistant/app/theme/app_theme.dart';
import 'package:ai_assistant/app/widgets/primary_button.dart';
import 'package:ai_assistant/features/chat/widgets/composer.dart';
import 'package:ai_assistant/infrastructure/gemma/flutter_gemma_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/container_harness.dart';
import '../helpers/fake_gemma_service.dart';

/// Polish T050 — the code-enforceable slice of the accessibility gate (FR-031/SC-012): interactive
/// controls meet the 48dp touch-target floor. (The full Android Accessibility Scanner pass + AA
/// contrast measurement run on a device; the contrast rule is enforced in the tokens — timestamps
/// use `textSecondary`, red is reserved for large/icon/fill.)
void main() {
  testWidgets('the composer send control is at least a 48dp touch target', (tester) async {
    final container = makeContainer(
      overrides: [gemmaServiceProvider.overrideWithValue(FakeGemmaService())],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.dark,
          home: const Scaffold(body: Composer()),
        ),
      ),
    );
    await tester.pump();

    final size = tester.getSize(find.byKey(Composer.sendKey));
    expect(size.width, greaterThanOrEqualTo(AppSpacing.minTouchTarget));
    expect(size.height, greaterThanOrEqualTo(AppSpacing.minTouchTarget));
  });

  testWidgets('the primary button is a full 48dp-high target', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: Scaffold(
          body: Center(
            child: PrimaryButton(label: 'continue', onPressed: () {}),
          ),
        ),
      ),
    );

    final size = tester.getSize(find.byType(PrimaryButton));
    expect(size.height, greaterThanOrEqualTo(AppSpacing.minTouchTarget));
  });
}
