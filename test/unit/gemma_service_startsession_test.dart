import 'package:ai_assistant/domain/entities/model_capabilities.dart';
import 'package:ai_assistant/domain/services/gemma_service.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fake_gemma_service.dart';

/// F4 (audit) — `startSession` seam contract, modeled FOR REAL in [FakeGemmaService] so the
/// off-device tests pin what the concrete [FlutterGemmaService] now guarantees:
///
///   * guarantee 27: `startSession()` before a model is loaded throws `StateError` (was only
///     implicit before this fix);
///   * a recreation FAILURE leaves the seam in an honest state — `isLoaded == false` — matching
///     `loadModel`'s close()-then-rethrow contract, instead of `_loaded == true` with a null chat.
void main() {
  group('guarantee 27 — startSession before load', () {
    test('throws StateError when no model is loaded', () {
      final gemma = FakeGemmaService();
      expect(gemma.startSession, throwsStateError);
    });
  });

  group('startSession failure leaves an honest state (F4)', () {
    test('a failed recreation unloads the service (isLoaded == false)', () async {
      final gemma = FakeGemmaService(
        capabilitiesData: const ModelCapabilities(functionCalling: true),
      );
      await gemma.loadModel('/fake');
      expect(gemma.isLoaded, isTrue);

      gemma.throwOnStartSession = true;
      await expectLater(
        gemma.startSession(systemInstruction: 'facts'),
        throwsA(isA<ModelLoadException>()),
      );

      expect(
        gemma.isLoaded,
        isFalse,
        reason:
            'a recreation failure must fully unload (matches loadModel), never leave loaded '
            'with no chat',
      );
    });

    test('a successful refresh keeps the service loaded', () async {
      final gemma = FakeGemmaService();
      await gemma.loadModel('/fake');

      await gemma.startSession(systemInstruction: 'facts');

      expect(gemma.isLoaded, isTrue);
      expect(gemma.startSessionCount, 1);
      expect(gemma.lastStartSessionInstruction, 'facts');
    });
  });
}
