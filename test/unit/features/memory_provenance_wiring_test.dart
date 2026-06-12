import 'package:ai_assistant/data/repositories/drift_conversation_repository.dart';
import 'package:ai_assistant/data/repositories/drift_memory_repository.dart';
import 'package:ai_assistant/domain/entities/generation_event.dart';
import 'package:ai_assistant/domain/entities/memory.dart';
import 'package:ai_assistant/domain/entities/model_capabilities.dart';
import 'package:ai_assistant/domain/entities/tool_outcome.dart';
import 'package:ai_assistant/features/chat/chat_controller.dart';
import 'package:ai_assistant/features/chat/chat_providers.dart';
import 'package:ai_assistant/features/chat/tool_handler_providers.dart';
import 'package:ai_assistant/features/settings/memory_controller.dart';
import 'package:ai_assistant/infrastructure/gemma/flutter_gemma_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/container_harness.dart';
import '../../helpers/fake_gemma_service.dart';

/// F2 (audit) — WIRING regression for T015 `sourceConversationId` provenance.
///
/// The bug the existing handler tests missed: they re-implement the handler over a fake repo, so
/// they never exercise `activeConversationIdProvider`, which was a plain `Provider<int?>(=> null)`
/// that NOTHING could set at runtime — every captured fact persisted with null provenance. These
/// tests go through the REAL provider graph (real `toolDispatcherProvider`, real handler, real
/// drift repo) so the controller→notifier→handler wiring is what's under test.
void main() {
  late FakeGemmaService gemma;
  late ProviderContainer container;

  setUp(() {
    gemma = FakeGemmaService(
      capabilitiesData: const ModelCapabilities(functionCalling: true),
    );
    container = makeContainer(
      overrides: [
        gemmaServiceProvider.overrideWithValue(gemma),
        modelCapabilitiesProvider.overrideWith(
          (ref) => const ModelCapabilities(functionCalling: true),
        ),
        // NOTE: toolDispatcherProvider and memoryRepositoryProvider are left REAL on purpose —
        // the whole point is to exercise the production dispatch + persistence path.
      ],
    );
  });

  tearDown(() => container.dispose());

  ChatController controller() =>
      container.read(chatControllerProvider.notifier);

  Future<List<Memory>> activeFacts() =>
      container.read(memoryRepositoryProvider).listActive();

  test(
    'open a conversation → remember_fact persists with that conversation id',
    () async {
      final convId =
          (await container
                  .read(conversationRepositoryProvider)
                  .createConversation())
              .id;
      await controller().openConversation(convId);

      final outcome = await container.read(toolDispatcherProvider).dispatch(
        'remember_fact',
        {'fact': 'name is Yossef', 'category': 'identity'},
      );

      expect(outcome, isA<ToolSuccess>());
      final facts = await activeFacts();
      expect(facts, hasLength(1));
      expect(
        facts.single.sourceConversationId,
        convId,
        reason: 'the open conversation id must be injected as provenance',
      );
    },
  );

  test(
    'lazy-create path: first send on a null-id chat → fact carries the newly created id',
    () async {
      gemma.scriptedEvents = const [
        ToolCallRequested('remember_fact', {
          'fact': 'lives in Cairo',
          'category': 'identity',
        }),
      ];
      gemma.resumeEvents = const [TextDelta('got it')];

      // Fresh thread — no conversation row exists until send lazily creates it.
      expect(container.read(chatControllerProvider).conversationId, isNull);
      await controller().send('I live in Cairo');

      final convId = container.read(chatControllerProvider).conversationId;
      expect(convId, isNotNull);
      final facts = await activeFacts();
      expect(facts, hasLength(1));
      expect(
        facts.single.sourceConversationId,
        convId,
        reason:
            'a first-message capture must carry the id of the just-created conversation',
      );
    },
  );

  test(
    'manual-add path: a settings-screen fact stays null provenance',
    () async {
      await container
          .read(memoryControllerProvider.notifier)
          .add(fact: 'prefers dark mode', category: MemoryCategory.preferences);

      final facts = await activeFacts();
      expect(facts, hasLength(1));
      expect(
        facts.single.sourceConversationId,
        isNull,
        reason:
            'manually-added facts have no source conversation (data-model §1)',
      );
    },
  );
}
