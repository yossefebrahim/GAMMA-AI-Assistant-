import 'package:ai_assistant/core/memory/facts_block_composer.dart';
import 'package:ai_assistant/core/memory/system_instruction_composer.dart';
import 'package:ai_assistant/core/tools/tool_registry.dart';
import 'package:ai_assistant/data/repositories/drift_memory_repository.dart';
import 'package:ai_assistant/domain/entities/memory.dart';
import 'package:ai_assistant/domain/entities/model_capabilities.dart';
import 'package:ai_assistant/features/chat/chat_controller.dart';
import 'package:ai_assistant/features/chat/chat_providers.dart';
import 'package:ai_assistant/infrastructure/gemma/flutter_gemma_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/container_harness.dart';
import '../../helpers/fake_gemma_service.dart';
import '../../helpers/fake_memory_repository.dart';

/// T036 — FR-009/FR-018: facts-block injection is capability-INDEPENDENT.
///
/// A text-only model (functionCalling == false) still receives the facts block via
/// [GemmaService.startSession] when memory is enabled and active facts exist. HOWEVER,
/// the [remember_fact] and [forget_fact] tool declarations are NOT emitted to a text-only
/// model (they are gated on functionCalling, R6). The parity guarantee is preserved when
/// memory is empty (null instruction, as in T035); injection is the NEW case.
void main() {
  // ---------------------------------------------------------------------------
  // Helper: memory seeded but no function-calling
  // ---------------------------------------------------------------------------

  final fixedFact = Memory(
    id: 1,
    fact: 'name is Yossef',
    category: MemoryCategory.identity,
    createdAt: DateTime.utc(2026, 1, 1),
    updatedAt: DateTime.utc(2026, 1, 1),
  );

  // ---------------------------------------------------------------------------
  // T036 — composer: facts-only block when functionCalling off
  // ---------------------------------------------------------------------------

  group('T036 — composer: facts block present when functionCalling off', () {
    test('compose returns a non-null instruction containing the facts block '
        'when functionCalling=false but there ARE active facts', () {
      final facts = [fixedFact];
      final block = FactsBlockComposer.compose(facts);

      final result = SystemInstructionComposer.compose(
        factsBlock: block,
        memoryCapture:
            false, // functionCalling off → capture instruction absent
        deviceTools: false, // functionCalling off → device instruction absent
      );

      expect(result, isNotNull);
      expect(result, contains('name is Yossef'));
      expect(result, contains('#1'));
    });

    test(
      'composed facts-only instruction does NOT contain remember_fact or forget_fact keywords',
      () {
        final block = FactsBlockComposer.compose([fixedFact]);
        final result = SystemInstructionComposer.compose(
          factsBlock: block,
          memoryCapture: false,
          deviceTools: false,
        )!;

        // The capture instruction (which names remember_fact) must NOT be present.
        expect(result, isNot(contains('remember_fact')));
        expect(result, isNot(contains('forget_fact')));
      },
    );

    test(
      'composed facts-only instruction does NOT contain the device tool-use instruction',
      () {
        final block = FactsBlockComposer.compose([fixedFact]);
        final result = SystemInstructionComposer.compose(
          factsBlock: block,
          memoryCapture: false,
          deviceTools: false,
        )!;

        expect(result, isNot(contains(ToolRegistry.systemInstruction)));
      },
    );

    test(
      'the instruction equals exactly the raw facts block (single-part case, no separator)',
      () {
        final block = FactsBlockComposer.compose([fixedFact]);
        final result = SystemInstructionComposer.compose(
          factsBlock: block,
          memoryCapture: false,
          deviceTools: false,
        )!;

        expect(result, equals(block));
      },
    );
  });

  // ---------------------------------------------------------------------------
  // T036 — seam: no memory tools declared to a text-only model
  // ---------------------------------------------------------------------------

  group('T036 — seam: memory tools NOT declared to a text-only model', () {
    test(
      'FakeGemmaService gate: loadModel with tools + functionCalling=false throws StateError',
      () async {
        final gemma = FakeGemmaService(
          capabilitiesData: ModelCapabilities.textOnly,
        );
        expect(
          () => gemma.loadModel(
            '/m',
            capabilities: ModelCapabilities.textOnly,
            tools: ToolRegistry.memoryTools, // tools gated to fn-calling ONLY
          ),
          throwsStateError,
        );
      },
    );

    test(
      'loadModel with systemInstruction (facts block) but empty tools is accepted',
      () async {
        final gemma = FakeGemmaService(
          capabilitiesData: ModelCapabilities.textOnly,
        );
        final block = FactsBlockComposer.compose([fixedFact]);
        await expectLater(
          gemma.loadModel(
            '/m',
            capabilities: ModelCapabilities.textOnly,
            tools: const [], // no tools → seam gate passes
            systemInstruction: block,
          ),
          completes,
        );
        expect(gemma.loadedSystemInstruction, equals(block));
        expect(gemma.loadedTools, isEmpty);
      },
    );
  });

  // ---------------------------------------------------------------------------
  // T036 — openConversation with text-only model + facts → startSession carries facts block
  // ---------------------------------------------------------------------------

  group('T036 — openConversation: facts injected into text-only session', () {
    late FakeGemmaService gemma;
    late FakeMemoryRepository repo;
    late ProviderContainer container;

    setUp(() async {
      gemma = FakeGemmaService(capabilitiesData: ModelCapabilities.textOnly);
      repo = FakeMemoryRepository();
      container = makeContainer(
        overrides: [
          gemmaServiceProvider.overrideWithValue(gemma),
          memoryRepositoryProvider.overrideWithValue(repo),
          modelCapabilitiesProvider.overrideWith(
            (_) => ModelCapabilities.textOnly,
          ),
        ],
      );
      await gemma.loadModel(
        '/fake/model.litertlm',
        capabilities: ModelCapabilities.textOnly,
        tools: const [],
      );
    });

    tearDown(() {
      container.dispose();
      repo.dispose();
    });

    test(
      'openConversation calls startSession with a non-null instruction containing the facts block',
      () async {
        repo.seed([fixedFact]);

        await container
            .read(chatControllerProvider.notifier)
            .openConversation(null);

        expect(gemma.startSessionCount, 1);
        expect(gemma.lastStartSessionInstruction, isNotNull);
        expect(gemma.lastStartSessionInstruction, contains('name is Yossef'));
      },
    );

    test(
      'openConversation instruction does NOT contain capture or device tool keywords '
      'when functionCalling is off',
      () async {
        repo.seed([fixedFact]);

        await container
            .read(chatControllerProvider.notifier)
            .openConversation(null);

        final instr = gemma.lastStartSessionInstruction!;
        expect(instr, isNot(contains('remember_fact')));
        expect(instr, isNot(contains('forget_fact')));
        expect(instr, isNot(contains('clipboard')));
        expect(instr, isNot(contains('timer')));
      },
    );

    test(
      'openConversation with empty memory + functionCalling off → null instruction '
      '(parity preserved when no facts)',
      () async {
        // repo is empty (no seed)

        await container
            .read(chatControllerProvider.notifier)
            .openConversation(null);

        expect(gemma.lastStartSessionInstruction, isNull);
      },
    );
  });
}
