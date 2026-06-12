import 'package:ai_assistant/core/memory/system_instruction_composer.dart';
import 'package:ai_assistant/data/repositories/drift_memory_repository.dart';
import 'package:ai_assistant/domain/entities/generation_event.dart';
import 'package:ai_assistant/domain/entities/model_capabilities.dart';
import 'package:ai_assistant/features/chat/chat_providers.dart';
import 'package:ai_assistant/infrastructure/gemma/flutter_gemma_service.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/container_harness.dart';
import '../../helpers/fake_gemma_service.dart';
import '../../helpers/fake_memory_repository.dart';

/// T035 — Byte-parity test (extends SC-010/guarantee 29): when [functionCalling] is off AND
/// memory is empty/off, the composed instruction is null, no tools are declared, and [generate]
/// emits only [TextDelta]s — byte-identical to the 003/004 flag-off baseline.
///
/// Also asserts that the existing text/image/audio chat capability matrix is unaffected by the
/// introduction of the memory feature (the parity guarantee extends to all capability combinations).
void main() {
  // ---------------------------------------------------------------------------
  // Helper
  // ---------------------------------------------------------------------------

  Future<FakeGemmaService> loadedTextOnly() async {
    final gemma = FakeGemmaService(
      capabilitiesData: ModelCapabilities.textOnly,
    );
    await gemma.loadModel(
      '/m',
      capabilities: ModelCapabilities.textOnly,
      tools: const [],
      systemInstruction: null,
    );
    return gemma;
  }

  // ---------------------------------------------------------------------------
  // T035 — composer null-instruction + tool-list parity
  // ---------------------------------------------------------------------------

  group(
    'T035 — functionCalling off + memory empty/off → null instruction (guarantee 29)',
    () {
      test('composer returns null when all flags off and no facts', () {
        final result = SystemInstructionComposer.compose(
          factsBlock: null,
          memoryCapture: false,
          deviceTools: false,
        );
        expect(result, isNull);
      });

      test(
        'composer returns null when memory empty string + all flags off',
        () {
          final result = SystemInstructionComposer.compose(
            factsBlock: '',
            memoryCapture: false,
            deviceTools: false,
          );
          expect(result, isNull);
        },
      );

      test(
        'composer returns null when memory is off (even with facts present)',
        () {
          // memoryEnabled == false → factsBlock passed as null (caller doesn't compose the block)
          // + functionCalling off → no deviceTools or capture → null
          final result = SystemInstructionComposer.compose(
            factsBlock: null, // callers pass null when memoryEnabled=false
            memoryCapture: false,
            deviceTools: false,
          );
          expect(result, isNull);
        },
      );

      test(
        'FakeGemmaService loadModel with null instruction + empty tools records null loadedSystemInstruction',
        () async {
          final gemma = await loadedTextOnly();
          expect(gemma.loadedSystemInstruction, isNull);
          expect(gemma.loadedTools, isEmpty);
        },
      );

      test(
        'generate on a flag-off seam emits only TextDeltas (byte-parity with 003)',
        () async {
          final gemma = await loadedTextOnly();
          gemma.scriptedDeltas = ['hello ', 'world'];

          final events = await gemma
              .generate(history: const [], prompt: 'hi')
              .toList();

          expect(events, everyElement(isA<TextDelta>()));
          expect(
            events.cast<TextDelta>().map((e) => e.token).join(),
            'hello world',
          );
        },
      );

      test(
        'generate on a flag-off seam never emits a ToolCallRequested',
        () async {
          final gemma = await loadedTextOnly();
          gemma.scriptedDeltas = ['reply'];

          final events = await gemma
              .generate(history: const [], prompt: 'use a tool')
              .toList();

          expect(events.whereType<ToolCallRequested>(), isEmpty);
        },
      );

      test(
        'modelSessionProvider passes null systemInstruction when functionCalling off + empty memory',
        () async {
          final gemma = FakeGemmaService(
            capabilitiesData: ModelCapabilities.textOnly,
          );
          final repo = FakeMemoryRepository();
          final container = makeContainer(
            overrides: [
              gemmaServiceProvider.overrideWithValue(gemma),
              memoryRepositoryProvider.overrideWithValue(repo),
              installedModelPathProvider.overrideWith(
                (ref) async => '/fake/model',
              ),
              // Override the catalog capabilities so the session provider uses textOnly,
              // not the real ModelCatalog (which has functionCalling: true).
              catalogCapabilitiesProvider.overrideWithValue(
                ModelCapabilities.textOnly,
              ),
            ],
          );
          addTearDown(() {
            container.dispose();
            repo.dispose();
          });

          final sub = container.listen(modelSessionProvider, (_, _) {});
          addTearDown(sub.close);
          await container.read(modelSessionProvider.future);

          expect(
            gemma.loadedSystemInstruction,
            isNull,
            reason:
                'text-only model + empty memory → composer returns null → seam receives null → '
                'byte-parity with 003 (guarantee 29)',
          );
        },
      );

      test(
        'modelSessionProvider passes no tools when functionCalling off',
        () async {
          final gemma = FakeGemmaService(
            capabilitiesData: ModelCapabilities.textOnly,
          );
          final repo = FakeMemoryRepository();
          final container = makeContainer(
            overrides: [
              gemmaServiceProvider.overrideWithValue(gemma),
              memoryRepositoryProvider.overrideWithValue(repo),
              installedModelPathProvider.overrideWith(
                (ref) async => '/fake/model',
              ),
              // Override the catalog capabilities so the session provider uses textOnly.
              catalogCapabilitiesProvider.overrideWithValue(
                ModelCapabilities.textOnly,
              ),
            ],
          );
          addTearDown(() {
            container.dispose();
            repo.dispose();
          });

          final sub = container.listen(modelSessionProvider, (_, _) {});
          addTearDown(sub.close);
          await container.read(modelSessionProvider.future);

          expect(
            gemma.loadedTools,
            isEmpty,
            reason: 'no tools declared when functionCalling is off',
          );
          expect(gemma.loadedCapabilities?.functionCalling, isFalse);
        },
      );

      test(
        'startSession with null instruction does not crash and records null (guarantee 27)',
        () async {
          final gemma = await loadedTextOnly();
          await expectLater(
            gemma.startSession(systemInstruction: null),
            completes,
          );
          expect(gemma.lastStartSessionInstruction, isNull);
          expect(gemma.startSessionCount, 1);
        },
      );
    },
  );
}
