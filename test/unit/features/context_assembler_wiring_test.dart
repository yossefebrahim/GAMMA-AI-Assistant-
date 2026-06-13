import 'package:ai_assistant/data/repositories/drift_memory_repository.dart';
import 'package:ai_assistant/data/repositories/settings_repository.dart';
import 'package:ai_assistant/domain/entities/audio_input.dart';
import 'package:ai_assistant/domain/entities/chat_turn.dart';
import 'package:ai_assistant/domain/entities/image_input.dart';
import 'package:ai_assistant/domain/entities/memory.dart';
import 'package:ai_assistant/domain/entities/message.dart';
import 'package:ai_assistant/domain/entities/model_capabilities.dart';
import 'package:ai_assistant/features/chat/chat_controller.dart';
import 'package:ai_assistant/features/chat/chat_providers.dart';
import 'package:ai_assistant/features/chat/context_assembler.dart';
import 'package:ai_assistant/infrastructure/gemma/flutter_gemma_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/container_harness.dart';
import '../../helpers/fake_gemma_service.dart';
import '../../helpers/fake_memory_repository.dart';

/// F1 (audit) — WIRING regression for the T025 memory token reserve.
///
/// The class of bug here was "unit-green, never called": `ContextAssembler` gained
/// `reserveMemoryBlock` / `reserveMemoryCaptureInstruction` (fully unit-tested) but the only
/// production call site — `ChatController._assembleHistory` — passed only `reserveToolInstruction`,
/// so both memory reserves defaulted to false in production. These tests assert what the CONTROLLER
/// passes by spying on the assembler and driving a real `send`.
void main() {
  late FakeGemmaService gemma;
  late FakeMemoryRepository repo;
  late _SpyAssembler spy;
  late ProviderContainer container;

  /// Build a container wired with the spy assembler and the given capabilities. Memory defaults to
  /// on (the persisted default); pass [memoryEnabled] false to exercise the off path.
  Future<void> build({
    required ModelCapabilities caps,
    bool memoryEnabled = true,
    List<Memory> facts = const [],
  }) async {
    gemma = FakeGemmaService(capabilitiesData: caps)..scriptedDeltas = ['ok'];
    repo = FakeMemoryRepository();
    if (facts.isNotEmpty) repo.seed(facts);
    spy = _SpyAssembler();
    container = makeContainer(
      overrides: [
        gemmaServiceProvider.overrideWithValue(gemma),
        memoryRepositoryProvider.overrideWithValue(repo),
        contextAssemblerProvider.overrideWithValue(spy),
        // _assembleHistory derives reserveToolInstruction from this provider.
        modelCapabilitiesProvider.overrideWith((ref) => caps),
      ],
    );
    if (!memoryEnabled) {
      await container.read(memoryEnabledProvider.notifier).set(false);
    }
  }

  tearDown(() {
    container.dispose();
    repo.dispose();
  });

  Memory makeFact() => Memory(
    id: 1,
    fact: 'name is Yossef',
    category: MemoryCategory.identity,
    createdAt: DateTime.utc(2026, 1, 1),
    updatedAt: DateTime.utc(2026, 1, 1),
  );

  test(
    '(a) memory on + ≥1 fact + functionCalling → both memory reserves true',
    () async {
      await build(
        caps: const ModelCapabilities(functionCalling: true),
        facts: [makeFact()],
      );

      await container.read(chatControllerProvider.notifier).send('hi');

      expect(spy.reserveToolInstruction, isTrue);
      expect(spy.reserveMemoryBlock, isTrue);
      expect(spy.reserveMemoryCaptureInstruction, isTrue);
    },
  );

  test('(b) memory off → both memory reserves false', () async {
    await build(
      caps: const ModelCapabilities(functionCalling: true),
      memoryEnabled: false,
      facts: [makeFact()],
    );

    await container.read(chatControllerProvider.notifier).send('hi');

    expect(spy.reserveMemoryBlock, isFalse);
    expect(spy.reserveMemoryCaptureInstruction, isFalse);
  });

  test(
    '(c) memory on + 0 facts → block false, capture still true (functionCalling on)',
    () async {
      await build(caps: const ModelCapabilities(functionCalling: true));

      await container.read(chatControllerProvider.notifier).send('hi');

      expect(
        spy.reserveMemoryBlock,
        isFalse,
        reason: 'no active facts → no block to reserve for',
      );
      expect(
        spy.reserveMemoryCaptureInstruction,
        isTrue,
        reason: 'capture instruction is injected whenever fc + memory are on',
      );
    },
  );

  test(
    '(d) text-only caps → capture false even with memory on (block still reserved for facts)',
    () async {
      await build(caps: ModelCapabilities.textOnly, facts: [makeFact()]);

      await container.read(chatControllerProvider.notifier).send('hi');

      expect(
        spy.reserveMemoryCaptureInstruction,
        isFalse,
        reason: 'no function calling → no capture instruction injected',
      );
      expect(
        spy.reserveMemoryBlock,
        isTrue,
        reason: 'facts are injected regardless of function calling',
      );
    },
  );
}

/// Records the named reserve flags the controller passes, then delegates to the real assembler.
class _SpyAssembler extends ContextAssembler {
  bool? reserveToolInstruction;
  bool? reserveMemoryBlock;
  bool? reserveMemoryCaptureInstruction;
  bool? reserveWebTools;

  @override
  List<ChatTurn> assemble(
    List<Message> priorMessages, {
    Map<int, ImageInput> images = const <int, ImageInput>{},
    Map<int, AudioInput> audio = const <int, AudioInput>{},
    bool reserveToolInstruction = false,
    bool reserveMemoryBlock = false,
    bool reserveMemoryCaptureInstruction = false,
    bool reserveWebTools = false,
  }) {
    this.reserveToolInstruction = reserveToolInstruction;
    this.reserveMemoryBlock = reserveMemoryBlock;
    this.reserveMemoryCaptureInstruction = reserveMemoryCaptureInstruction;
    this.reserveWebTools = reserveWebTools;
    return super.assemble(
      priorMessages,
      images: images,
      audio: audio,
      reserveToolInstruction: reserveToolInstruction,
      reserveMemoryBlock: reserveMemoryBlock,
      reserveMemoryCaptureInstruction: reserveMemoryCaptureInstruction,
      reserveWebTools: reserveWebTools,
    );
  }
}
