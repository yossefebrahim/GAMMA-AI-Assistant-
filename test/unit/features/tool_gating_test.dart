import 'package:ai_assistant/core/model_catalog.dart';
import 'package:ai_assistant/core/tools/tool_registry.dart';
import 'package:ai_assistant/domain/entities/model_capabilities.dart';
import 'package:ai_assistant/features/chat/chat_providers.dart';
import 'package:ai_assistant/infrastructure/gemma/flutter_gemma_service.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/container_harness.dart';
import '../../helpers/fake_gemma_service.dart';

/// 004 US3 — capability gating is provably data-driven. Tools couple STRUCTURALLY to
/// `capabilities.functionCalling` (guarantees 18/19): flag-off load passes empty tools + flag
/// false; flag-on passes the registry; an ungated `loadModel(tools:)` is a StateError. Verified at
/// the seam-contract level (the fake models the gate) and the provider-wiring level.
void main() {
  group('seam gate (guarantees 18 & 19)', () {
    test('flag-off: empty tools + functionCalling false — byte-parity inputs (guarantee 19)',
        () async {
      final gemma = FakeGemmaService();
      await gemma.loadModel('/m',
          capabilities: ModelCapabilities.textOnly, tools: const []);
      expect(gemma.loadedTools, isEmpty);
      expect(gemma.loadedCapabilities!.functionCalling, isFalse);
    });

    test('flag-on: the registry tools are passed, coupled to the capability', () async {
      final gemma = FakeGemmaService();
      await gemma.loadModel('/m',
          capabilities: const ModelCapabilities(functionCalling: true),
          tools: ToolRegistry.specs);
      expect(gemma.loadedTools, ToolRegistry.specs);
      expect(gemma.loadedCapabilities!.functionCalling, isTrue);
    });

    test('ungated tools (flag off + non-empty tools) → StateError (guarantee 18)', () async {
      final gemma = FakeGemmaService();
      expect(
        () => gemma.loadModel('/m',
            capabilities: ModelCapabilities.textOnly, tools: ToolRegistry.specs),
        throwsStateError,
      );
    });
  });

  group('provider wiring (the catalog flag drives the tools passed)', () {
    test('with the catalog flag on, modelSessionProvider threads the registry tools', () async {
      // Guard: this assertion only holds while the catalog declares function calling.
      expect(ModelCatalog.capabilities.functionCalling, isTrue);

      final gemma = FakeGemmaService();
      final container = makeContainer(overrides: [
        gemmaServiceProvider.overrideWithValue(gemma),
        installedModelPathProvider.overrideWith((ref) async => '/fake/model'),
      ]);
      addTearDown(container.dispose);

      final sub = container.listen(modelSessionProvider, (_, _) {});
      await container.read(modelSessionProvider.future);

      expect(gemma.loadedTools, ToolRegistry.specs);
      expect(gemma.loadedCapabilities!.functionCalling, isTrue);
      sub.close();
    });
  });
}
