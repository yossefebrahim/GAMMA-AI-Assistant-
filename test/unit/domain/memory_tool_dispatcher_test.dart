import 'package:ai_assistant/core/tools/tool_registry.dart';
import 'package:ai_assistant/domain/entities/memory.dart';
import 'package:ai_assistant/domain/entities/tool_outcome.dart';
import 'package:ai_assistant/domain/services/tool_dispatcher.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/fake_memory_repository.dart';

/// T014 + T032 — dispatcher / handler unit tests for the two 005 memory tools.
///
/// Covers (T014):
///   • remember_fact: created / superseded / unchanged → correct ToolSuccess payloads
///   • remember_fact: bad category (invalid enum) → ToolInvalidArgs (handler untouched)
///   • remember_fact: fact > 80 chars → ToolInvalidArgs (handler untouched)
///   • remember_fact handler throws (e.g. memory-disabled) → ToolFailure (dispatch never throws)
///   • congruence: the six-tool handler map covers exactly the six registry names
///   • forget_fact: id arriving as a whole-valued double is coerced to int before dispatch
///
/// Covers (T032):
///   • forget_fact(valid active id) → ToolSuccess({forgot: id}); activeCount drops
///   • forget_fact(unknown id) → ToolFailure('no such fact: `<id>`'); no deletion
///   • forget_fact(stale / already-deleted id) → ToolFailure; no deletion
///   • forget_fact(guessed id — spike §4 hazard) → ToolFailure; repo left intact
///
/// All tests are pure unit tests: no platform channels, no real DB, no device.
void main() {
  // ---------------------------------------------------------------------------
  // Test infrastructure helpers
  // ---------------------------------------------------------------------------

  late FakeMemoryRepository memRepo;

  /// Builds a [ToolDispatcher] with handlers for all six registry tools so the
  /// congruence invariant holds inside the tests too (mirrors the real wiring).
  /// Pass [rememberFact] / [forgetFact] to inject override closures; leave null
  /// to use the real memory-repo–backed handlers.
  ToolDispatcher buildDispatcher({
    ToolHandler? rememberFact,
    ToolHandler? forgetFact,
  }) {
    return ToolDispatcher(
      handlers: <String, ToolHandler>{
        // device tools — lightweight stubs (not under test here)
        'get_device_info': (_) async => {'model': 'A34'},
        'summarize_clipboard': (_) async => {'text': 'hello'},
        'set_theme': (a) async => {'theme': a['theme'], 'alreadyActive': false},
        'set_timer': (a) async => {'seconds': a['seconds'], 'set': true},

        // 005 memory handlers
        'remember_fact': rememberFact ?? _rememberFactHandler(memRepo),
        'forget_fact': forgetFact ?? _forgetFactHandler(memRepo),

        // 006 web tools — lightweight stubs (not under test here)
        'web_search': (a) async => {'results': <Object?>[]},
        'fetch_page': (a) async => {
          'url': a['url'],
          'text': '',
          'truncated': false,
        },
      },
    );
  }

  setUp(() {
    memRepo = FakeMemoryRepository();
  });

  tearDown(() async {
    await memRepo.dispose();
  });

  // ---------------------------------------------------------------------------
  // T014 — remember_fact outcome mapping
  // ---------------------------------------------------------------------------

  group('T014 — remember_fact outcome mapping', () {
    test(
      'new fact → ToolSuccess with {remembered, category} payload',
      () async {
        final dispatcher = buildDispatcher();

        final outcome = await dispatcher.dispatch('remember_fact', {
          'fact': 'lives in Cairo',
          'category': 'identity',
        });

        expect(outcome, isA<ToolSuccess>());
        final success = outcome as ToolSuccess;
        expect(success.result['remembered'], 'lives in Cairo');
        expect(success.result['category'], 'identity');
        expect(success.result.containsKey('updated'), isFalse);
        expect(success.result.containsKey('noted'), isFalse);
        // The repo should now hold one active fact.
        expect(await memRepo.activeCount(), 1);
      },
    );

    test(
      'superseded fact → ToolSuccess with {updated, category} payload',
      () async {
        // Pre-seed a fact so the incoming near-duplicate supersedes it.
        memRepo.seed(<Memory>[
          Memory(
            id: 1,
            fact: 'lives in Cairo',
            category: MemoryCategory.identity,
            createdAt: _t(0),
            updatedAt: _t(0),
          ),
        ]);
        final dispatcher = buildDispatcher();

        // "lives in Cairo, Egypt" shares enough content words with "lives in Cairo" to cross
        // the Jaccard ≥ 0.5 threshold (shared: {lives, cairo}; union: {lives, cairo, egypt} →
        // jaccard = 2/3 ≈ 0.67 ≥ 0.5).
        final outcome = await dispatcher.dispatch('remember_fact', {
          'fact': 'lives in Cairo, Egypt',
          'category': 'identity',
        });

        expect(outcome, isA<ToolSuccess>());
        final success = outcome as ToolSuccess;
        // supersede → 'updated' key, not 'remembered'
        expect(
          success.result.containsKey('updated'),
          isTrue,
          reason: 'near-duplicate supersede must produce the "updated" key',
        );
        expect(success.result['updated'], 'lives in Cairo, Egypt');
        expect(success.result['category'], 'identity');
        expect(success.result.containsKey('remembered'), isFalse);
        expect(
          await memRepo.activeCount(),
          1,
          reason: 'supersede does not add a new row',
        );
      },
    );

    test(
      'exact restatement → ToolSuccess with {noted} payload; no dup row',
      () async {
        memRepo.seed(<Memory>[
          Memory(
            id: 1,
            fact: 'prefers dark mode',
            category: MemoryCategory.preferences,
            createdAt: _t(0),
            updatedAt: _t(0),
          ),
        ]);
        final dispatcher = buildDispatcher();

        // Normalised exact match (same fact, same category).
        final outcome = await dispatcher.dispatch('remember_fact', {
          'fact': 'prefers dark mode',
          'category': 'preferences',
        });

        expect(outcome, isA<ToolSuccess>());
        final success = outcome as ToolSuccess;
        expect(
          success.result.containsKey('noted'),
          isTrue,
          reason: 'exact restatement must produce the "noted" key',
        );
        expect(success.result['noted'], 'prefers dark mode');
        expect(success.result.containsKey('remembered'), isFalse);
        expect(success.result.containsKey('updated'), isFalse);
        expect(
          await memRepo.activeCount(),
          1,
          reason: 'unchanged must not add a dup row',
        );
      },
    );

    // -------------------------------------------------------------------------
    // T014 — invalid-args cases: handler NEVER invoked
    // -------------------------------------------------------------------------

    test(
      'bad category (invalid enum value) → ToolInvalidArgs; handler untouched',
      () async {
        var handlerRan = false;
        final dispatcher = buildDispatcher(
          rememberFact: (args) async {
            handlerRan = true;
            return {'remembered': args['fact']};
          },
        );

        final outcome = await dispatcher.dispatch('remember_fact', {
          'fact': 'some fact',
          'category': 'hobbies',
        });

        expect(
          outcome,
          isA<ToolInvalidArgs>(),
          reason: 'an out-of-enum category must fail schema validation',
        );
        expect((outcome as ToolInvalidArgs).reason, contains('category'));
        expect(
          handlerRan,
          isFalse,
          reason: 'handler must not run on schema-invalid args',
        );
      },
    );

    test('fact > 80 chars → ToolInvalidArgs; handler untouched', () async {
      var handlerRan = false;
      final dispatcher = buildDispatcher(
        rememberFact: (args) async {
          handlerRan = true;
          return {'remembered': args['fact']};
        },
      );
      final over80 = 'x' * 81;

      final outcome = await dispatcher.dispatch('remember_fact', {
        'fact': over80,
        'category': 'identity',
      });

      expect(
        outcome,
        isA<ToolInvalidArgs>(),
        reason: 'a fact exceeding 80 chars must fail maxLength validation',
      );
      expect((outcome as ToolInvalidArgs).reason, contains('80'));
      expect(
        handlerRan,
        isFalse,
        reason: 'handler must not run on over-length fact',
      );
    });

    test('fact exactly 80 chars → ToolSuccess (at-bound is valid)', () async {
      final dispatcher = buildDispatcher();
      final exactly80 = 'a' * 80;

      final outcome = await dispatcher.dispatch('remember_fact', {
        'fact': exactly80,
        'category': 'other',
      });

      expect(
        outcome,
        isA<ToolSuccess>(),
        reason: 'exactly 80 chars is within the maxLength bound',
      );
    });

    // -------------------------------------------------------------------------
    // T014 — handler-throws → ToolFailure (dispatch never throws)
    // -------------------------------------------------------------------------

    test(
      'handler throws (memory-disabled guard) → ToolFailure; dispatch never throws',
      () async {
        final dispatcher = buildDispatcher(
          rememberFact: (_) async => throw _MemoryDisabledException(),
        );

        // Must not throw — the dispatcher catches all handler exceptions.
        final ToolOutcome outcome;
        try {
          outcome = await dispatcher.dispatch('remember_fact', {
            'fact': 'prefers dark mode',
            'category': 'preferences',
          });
        } catch (e) {
          fail('dispatch threw when it must not: $e');
        }

        expect(outcome, isA<ToolFailure>());
        expect((outcome as ToolFailure).reason, 'memory is off');
      },
    );

    test('handler throws generic error → ToolFailure with reason', () async {
      final dispatcher = buildDispatcher(
        rememberFact: (_) async =>
            throw StateError('unexpected internal failure'),
      );

      final outcome = await dispatcher.dispatch('remember_fact', {
        'fact': 'some fact',
        'category': 'work',
      });

      expect(outcome, isA<ToolFailure>());
      expect(
        (outcome as ToolFailure).reason,
        contains('unexpected internal failure'),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // T014 — congruence: six-tool handler map covers the six registry names
  // ---------------------------------------------------------------------------

  group('T014 — congruence over the ≤8 declared tools', () {
    test('buildDispatcher handler keys equal the full registry name set', () {
      // The helper covers exactly the eight names declared in the registry; we assert
      // this by comparing the literal key set against the live registry.
      const handlerKeys = <String>{
        'get_device_info',
        'summarize_clipboard',
        'set_theme',
        'set_timer',
        'remember_fact',
        'forget_fact',
        'web_search',
        'fetch_page',
      };
      final registryNames = ToolRegistry.specs.map((s) => s.name).toSet();
      expect(
        handlerKeys,
        equals(registryNames),
        reason:
            'the eight handler names must equal the eight registry names exactly',
      );
      // Sanity — registry is indeed eight tools (T021 contract).
      expect(registryNames, hasLength(8));
    });

    test('every registry tool has a handler in a fully-wired dispatcher', () async {
      // Each registry tool dispatches to either a stub or the real memory handler;
      // none must return ToolFailure('tool not available') (the missing-handler sentinel).
      final toolCalls = <String, Map<String, Object?>>{
        'get_device_info': {},
        'summarize_clipboard': {},
        'set_theme': {'theme': 'dark'},
        'set_timer': {'seconds': 5},
        'remember_fact': {'fact': 'name is Alice', 'category': 'identity'},
        'forget_fact': {
          'id': 999,
        }, // unknown id → ToolFailure, but NOT 'tool not available'
        'web_search': {'query': 'test query'},
        'fetch_page': {'url': 'https://example.com'},
      };

      final dispatcher = buildDispatcher();
      for (final entry in toolCalls.entries) {
        final outcome = await dispatcher.dispatch(entry.key, entry.value);
        if (outcome is ToolFailure) {
          expect(
            outcome.reason,
            isNot(equals('tool not available')),
            reason: '${entry.key} must have a bound handler',
          );
        }
      }
    });
  });

  // ---------------------------------------------------------------------------
  // T014 — forget_fact int-as-double coercion
  // ---------------------------------------------------------------------------

  group('T014 — forget_fact integer-double coercion', () {
    test(
      'id as whole-valued double → coerced to int; handler receives int',
      () async {
        // Seed a fact so forget can succeed.
        memRepo.seed(<Memory>[
          Memory(
            id: 7,
            fact: 'drinks coffee',
            category: MemoryCategory.preferences,
            createdAt: _t(0),
            updatedAt: _t(0),
          ),
        ]);
        final dispatcher = buildDispatcher();

        // The model/SDK emits JSON integers as Dart doubles (spike §3.2.3 / 004 hazard).
        final outcome = await dispatcher.dispatch('forget_fact', {'id': 7.0});

        expect(
          outcome,
          isA<ToolSuccess>(),
          reason: 'whole-valued double 7.0 should be coerced to int 7',
        );
        expect(
          (outcome as ToolSuccess).result['forgot'],
          7,
          reason: 'the result id must be an int, not a double',
        );
        expect((outcome).result['forgot'], isA<int>());
        // The fact must actually be gone.
        expect(await memRepo.activeCount(), 0);
      },
    );

    test('fractional double id → ToolInvalidArgs (not coerced)', () async {
      final dispatcher = buildDispatcher();

      final outcome = await dispatcher.dispatch('forget_fact', {'id': 1.5});

      expect(
        outcome,
        isA<ToolInvalidArgs>(),
        reason: 'fractional double is not coerced and fails integer validation',
      );
    });
  });

  // ---------------------------------------------------------------------------
  // T032 — forget_fact delete semantics
  // ---------------------------------------------------------------------------

  group('T032 — forget_fact delete semantics', () {
    test(
      'forget_fact(valid active id) → ToolSuccess({forgot: id}); activeCount drops',
      () async {
        memRepo.seed(<Memory>[
          Memory(
            id: 3,
            fact: 'speaks Arabic',
            category: MemoryCategory.identity,
            createdAt: _t(0),
            updatedAt: _t(0),
          ),
          Memory(
            id: 4,
            fact: 'mobile developer',
            category: MemoryCategory.work,
            createdAt: _t(0),
            updatedAt: _t(0),
          ),
        ]);
        final dispatcher = buildDispatcher();

        final outcome = await dispatcher.dispatch('forget_fact', {'id': 3});

        expect(outcome, isA<ToolSuccess>());
        final success = outcome as ToolSuccess;
        expect(success.result['forgot'], 3);
        // Count must have dropped: 2 → 1.
        expect(await memRepo.activeCount(), 1);
        // The remaining fact must be the OTHER one.
        final remaining = await memRepo.listActive();
        expect(remaining.single.id, 4);
      },
    );

    test(
      'forget_fact(unknown id) → ToolFailure("no such fact: <id>"); no deletion',
      () async {
        memRepo.seed(<Memory>[
          Memory(
            id: 2,
            fact: 'prefers dark mode',
            category: MemoryCategory.preferences,
            createdAt: _t(0),
            updatedAt: _t(0),
          ),
        ]);
        final dispatcher = buildDispatcher();

        // 999 is not an active id in the repo.
        final outcome = await dispatcher.dispatch('forget_fact', {'id': 999});

        expect(outcome, isA<ToolFailure>());
        expect(
          (outcome as ToolFailure).reason,
          'no such fact: 999',
          reason:
              'the exact error message from the contract (tool_registry_dispatcher.md)',
        );
        // The real fact must still be active — no deletion happened.
        expect(await memRepo.activeCount(), 1);
      },
    );

    test(
      'forget_fact(stale / already-deleted id) → ToolFailure; no further deletion',
      () async {
        // Seed a fact, then soft-delete it manually, then try to forget it again via the dispatcher.
        memRepo.seed(<Memory>[
          Memory(
            id: 5,
            fact: 'name is Alice',
            category: MemoryCategory.identity,
            createdAt: _t(0),
            updatedAt: _t(0),
            active: false, // already inactive (stale)
          ),
        ]);
        final dispatcher = buildDispatcher();

        final outcome = await dispatcher.dispatch('forget_fact', {'id': 5});

        expect(outcome, isA<ToolFailure>());
        expect((outcome as ToolFailure).reason, 'no such fact: 5');
        // Nothing to delete — count stays 0.
        expect(await memRepo.activeCount(), 0);
      },
    );

    test(
      'forget_fact(guessed id — spike §4 hazard) → ToolFailure; repo left intact',
      () async {
        // The model fabricates an id when no facts block was injected (spike §3.2 finding 1).
        // Even if that guessed id (e.g. 1) happens to exist, the dispatcher must validate
        // it against ACTIVE rows; this test seeds ONE active fact at a DIFFERENT id so the
        // guessed id 1 does not match — confirm ToolFailure and zero deletions.
        memRepo.seed(<Memory>[
          Memory(
            id: 42,
            fact: 'name is Bob',
            category: MemoryCategory.identity,
            createdAt: _t(0),
            updatedAt: _t(0),
          ),
        ]);
        final dispatcher = buildDispatcher();

        // The model guesses id = 1, which does not exist.
        final outcome = await dispatcher.dispatch('forget_fact', {'id': 1});

        expect(outcome, isA<ToolFailure>());
        expect((outcome as ToolFailure).reason, 'no such fact: 1');
        // The REAL fact (id=42) is untouched.
        expect(await memRepo.activeCount(), 1);
        final facts = await memRepo.listActive();
        expect(facts.single.id, 42);
      },
    );

    test(
      'forget_fact: exact error format matches contract string (no prefix, no trailing text)',
      () async {
        final dispatcher = buildDispatcher();
        // No facts seeded → any id is unknown.
        final outcome = await dispatcher.dispatch('forget_fact', {'id': 7});
        expect(outcome, isA<ToolFailure>());
        // Contract: 'no such fact: <id>' — no "Exception: " prefix (uses private exception type).
        final reason = (outcome as ToolFailure).reason;
        expect(
          reason,
          'no such fact: 7',
          reason:
              'dispatcher must NOT prefix the reason with "Exception:" or similar',
        );
      },
    );

    test(
      'forget_fact: id below minimum (0) → ToolInvalidArgs; no deletion',
      () async {
        memRepo.seed(<Memory>[
          Memory(
            id: 1,
            fact: 'some fact',
            category: MemoryCategory.other,
            createdAt: _t(0),
            updatedAt: _t(0),
          ),
        ]);
        final dispatcher = buildDispatcher();

        final outcome = await dispatcher.dispatch('forget_fact', {'id': 0});

        expect(
          outcome,
          isA<ToolInvalidArgs>(),
          reason: 'id=0 violates minimum:1 and must fail schema validation',
        );
        expect(
          await memRepo.activeCount(),
          1,
          reason: 'schema rejection must not reach the handler',
        );
      },
    );
  });
}

// ---------------------------------------------------------------------------
// Private helpers
// ---------------------------------------------------------------------------

/// Build a `remember_fact` handler backed by [repo] (mirrors the real handler logic in
/// `tool_handler_providers.dart`, minus the Riverpod wiring and memoryEnabled guard).
ToolHandler _rememberFactHandler(FakeMemoryRepository repo) {
  return (args) async {
    final fact = args['fact'] as String;
    final category = MemoryCategory.values.byName(args['category'] as String);
    final result = await repo.upsert(fact: fact, category: category);
    return switch (result) {
      UpsertCreated(:final memory) => {
        'remembered': memory.fact,
        'category': memory.category.name,
      },
      UpsertSuperseded(:final memory) => {
        'updated': memory.fact,
        'category': memory.category.name,
      },
      UpsertUnchanged(:final memory) => {'noted': memory.fact},
    };
  };
}

/// Build a `forget_fact` handler backed by [repo] (mirrors the real handler in
/// `tool_handler_providers.dart`).
ToolHandler _forgetFactHandler(FakeMemoryRepository repo) {
  return (args) async {
    final id = args['id'] as int;
    final deleted = await repo.softDeleteById(id);
    if (!deleted) throw _NoSuchFactException(id);
    return {'forgot': id};
  };
}

/// A fixed [DateTime] offset from epoch, used to produce deterministic timestamps in seeds.
DateTime _t(int offsetSeconds) =>
    DateTime.fromMillisecondsSinceEpoch(offsetSeconds * 1000, isUtc: true);

// Exception types that mirror the private ones in `tool_handler_providers.dart`.

class _MemoryDisabledException implements Exception {
  @override
  String toString() => 'memory is off';
}

class _NoSuchFactException implements Exception {
  const _NoSuchFactException(this.id);
  final int id;
  @override
  String toString() => 'no such fact: $id';
}
