import 'package:ai_assistant/features/chat/chat_providers.dart';
import 'package:ai_assistant/infrastructure/gemma/flutter_gemma_service.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/container_harness.dart';
import '../../helpers/fake_gemma_service.dart';

/// Polish T053 — resource-hygiene LOGIC (FR-029, Principle VIII). The on-device memory drop needs
/// a profiler, but the release wiring is verifiable here: the model session loads on first watch
/// and releases on dispose (leaving chat), and it does not reload an already-loaded model.
void main() {
  test('model session loads once and releases on dispose (FR-029)', () async {
    final gemma = FakeGemmaService();
    final container = makeContainer(
      overrides: [
        gemmaServiceProvider.overrideWithValue(gemma),
        installedModelPathProvider.overrideWith((ref) async => '/fake/model'),
      ],
    );

    // Watch keeps the autoDispose provider alive until we close the subscription.
    final sub = container.listen(modelSessionProvider, (_, _) {});
    await container.read(modelSessionProvider.future);
    expect(gemma.isLoaded, isTrue);
    expect(gemma.loadCount, 1);

    // Leaving chat = no more listeners → autoDispose → release.
    sub.close();
    await Future<void>.delayed(Duration.zero);
    expect(gemma.closeCount, greaterThanOrEqualTo(1));
    expect(gemma.isLoaded, isFalse);

    container.dispose();
  });

  test('an already-loaded model is not reloaded (single active)', () async {
    final gemma = FakeGemmaService();
    await gemma.loadModel('/preloaded');
    final container = makeContainer(
      overrides: [
        gemmaServiceProvider.overrideWithValue(gemma),
        installedModelPathProvider.overrideWith((ref) async => '/fake/model'),
      ],
    );
    addTearDown(container.dispose);

    final sub = container.listen(modelSessionProvider, (_, _) {});
    await container.read(modelSessionProvider.future);

    // The session saw it was already loaded and did not load again.
    expect(gemma.loadCount, 1);
    sub.close();
  });
}
