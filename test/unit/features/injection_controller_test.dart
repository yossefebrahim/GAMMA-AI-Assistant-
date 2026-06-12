import 'package:ai_assistant/core/memory/facts_block_composer.dart';
import 'package:ai_assistant/core/memory/system_instruction_composer.dart';
import 'package:ai_assistant/data/repositories/drift_memory_repository.dart';
import 'package:ai_assistant/data/repositories/settings_repository.dart';
import 'package:ai_assistant/domain/entities/memory.dart';
import 'package:ai_assistant/domain/entities/model_capabilities.dart';
import 'package:ai_assistant/features/chat/chat_controller.dart';
import 'package:ai_assistant/infrastructure/gemma/flutter_gemma_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/container_harness.dart';
import '../../helpers/fake_gemma_service.dart';
import '../../helpers/fake_memory_repository.dart';

/// T026 — US2 AS1/AS3: a fact captured mid-conversation does NOT change the CURRENT chat's
/// recorded system instruction; the NEXT [openConversation] composes an instruction whose facts
/// block contains it.
///
/// The two invariants are structural: [generate] takes no per-call instruction (so mid-chat facts
/// can't change the running session), and [ChatController.openConversation] calls
/// [GemmaService.startSession] with a freshly composed instruction at every session boundary
/// (data-model §4 / R2).
void main() {
  late FakeGemmaService gemma;
  late FakeMemoryRepository repo;
  late ProviderContainer container;

  /// Build a container with the given capabilities already loaded.
  Future<void> setUp({
    ModelCapabilities caps = const ModelCapabilities(functionCalling: true),
  }) async {
    gemma = FakeGemmaService(capabilitiesData: caps);
    repo = FakeMemoryRepository();
    container = makeContainer(
      overrides: [
        gemmaServiceProvider.overrideWithValue(gemma),
        memoryRepositoryProvider.overrideWithValue(repo),
      ],
    );
    // Simulate the model already loaded (as if modelSessionProvider ran).
    await gemma.loadModel(
      '/fake/model.litertlm',
      capabilities: caps,
      tools: const [],
    );
  }

  tearDown(() {
    container.dispose();
    repo.dispose();
  });

  // ---------------------------------------------------------------------------
  // T026 — mid-chat capture does NOT mutate the current session instruction
  // ---------------------------------------------------------------------------

  group('T026 — injection session boundary semantics (US2 AS1/AS3)', () {
    test(
      'capturing a fact mid-conversation leaves the recorded loadModel instruction unchanged',
      () async {
        await setUp();
        final recordedAtLoad =
            gemma.loadedSystemInstruction; // snapshot from loadModel

        // Simulate a mid-conversation fact capture (no openConversation called).
        await repo.upsert(
          fact: 'name is Yossef',
          category: MemoryCategory.identity,
        );

        // No startSession should have been triggered by the upsert alone.
        expect(gemma.startSessionCount, 0);
        // The instruction recorded at load time has NOT changed.
        expect(gemma.loadedSystemInstruction, equals(recordedAtLoad));
      },
    );

    test(
      'openConversation after a mid-chat capture calls startSession exactly once',
      () async {
        await setUp();

        // Seed a fact that was "captured" in the previous conversation.
        repo.seed([
          Memory(
            id: 1,
            fact: 'name is Yossef',
            category: MemoryCategory.identity,
            createdAt: DateTime.utc(2026, 1, 1),
            updatedAt: DateTime.utc(2026, 1, 1),
          ),
        ]);

        final prevStartCount = gemma.startSessionCount;
        await container
            .read(chatControllerProvider.notifier)
            .openConversation(null);

        expect(gemma.startSessionCount, prevStartCount + 1);
      },
    );

    test(
      'openConversation composes a new system instruction containing the captured fact (AS3)',
      () async {
        await setUp();

        // Seed the fact that was captured in the prior session.
        const capturedFact = 'name is Yossef';
        repo.seed([
          Memory(
            id: 1,
            fact: capturedFact,
            category: MemoryCategory.identity,
            createdAt: DateTime.utc(2026, 1, 1),
            updatedAt: DateTime.utc(2026, 1, 1),
          ),
        ]);

        await container
            .read(chatControllerProvider.notifier)
            .openConversation(null);

        // The instruction passed to startSession must contain the fact.
        expect(gemma.lastStartSessionInstruction, isNotNull);
        expect(gemma.lastStartSessionInstruction, contains(capturedFact));
      },
    );

    test(
      'openConversation with empty memory yields null instruction when functionCalling off',
      () async {
        await setUp(caps: ModelCapabilities.textOnly);
        // repo has no facts

        await container
            .read(chatControllerProvider.notifier)
            .openConversation(null);

        // No facts, no tools, no instructions → null (byte-parity guarantee 29).
        expect(gemma.lastStartSessionInstruction, isNull);
      },
    );

    test(
      'startSession instruction has facts block in category order (identity before work)',
      () async {
        await setUp();

        final now = DateTime.utc(2026, 1, 1);
        repo.seed([
          Memory(
            id: 2,
            fact: 'Flutter developer',
            category: MemoryCategory.work,
            createdAt: now,
            updatedAt: now,
          ),
          Memory(
            id: 1,
            fact: 'name is Yossef',
            category: MemoryCategory.identity,
            createdAt: now,
            updatedAt: now,
          ),
        ]);

        await container
            .read(chatControllerProvider.notifier)
            .openConversation(42);

        final instruction = gemma.lastStartSessionInstruction!;
        // identity category appears before work category in the block
        expect(
          instruction.indexOf('name is Yossef'),
          lessThan(instruction.indexOf('Flutter developer')),
        );
      },
    );

    test(
      'composer output is byte-stable: running openConversation twice with the same repo '
      'state passes the same instruction',
      () async {
        await setUp();
        repo.seed([
          Memory(
            id: 1,
            fact: 'prefers dark mode',
            category: MemoryCategory.preferences,
            createdAt: DateTime.utc(2026, 1, 1),
            updatedAt: DateTime.utc(2026, 1, 1),
          ),
        ]);

        await container
            .read(chatControllerProvider.notifier)
            .openConversation(null);
        final first = gemma.lastStartSessionInstruction;
        await container
            .read(chatControllerProvider.notifier)
            .openConversation(null);
        final second = gemma.lastStartSessionInstruction;

        expect(first, equals(second));
      },
    );

    test(
      'the instruction composed at openConversation matches what SystemInstructionComposer '
      'would build from the same state (round-trip correctness)',
      () async {
        await setUp();
        const fact = 'lives in Cairo, Egypt';
        repo.seed([
          Memory(
            id: 1,
            fact: fact,
            category: MemoryCategory.identity,
            createdAt: DateTime.utc(2026, 1, 1),
            updatedAt: DateTime.utc(2026, 1, 1),
          ),
        ]);

        await container
            .read(chatControllerProvider.notifier)
            .openConversation(null);

        // Reproduce what the controller should have composed.
        final activeFacts = await repo.listActive();
        final caps = gemma.capabilitiesData;
        final memEnabled = container.read(memoryEnabledProvider);
        final factsBlock = memEnabled
            ? FactsBlockComposer.compose(activeFacts)
            : null;
        final expected = SystemInstructionComposer.compose(
          factsBlock: factsBlock,
          memoryCapture: caps.functionCalling && memEnabled,
          deviceTools: caps.functionCalling,
        );

        expect(gemma.lastStartSessionInstruction, equals(expected));
      },
    );
  });
}
