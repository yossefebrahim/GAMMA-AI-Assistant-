import 'package:ai_assistant/core/memory/facts_block_composer.dart';
import 'package:ai_assistant/domain/entities/memory.dart';
import 'package:flutter_test/flutter_test.dart';

/// T019 — FactsBlockComposer unit tests (data-model §2, R3/R4).
/// Covers: empty input; id-prefixed lines; category declaration order; updatedAt-desc within
/// category; 20-fact count cap (oldest-first drop); 900-char char cap (oldest-first drop).
void main() {
  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  /// Build a [Memory] with the given fields; sensible defaults for the rest.
  Memory mem({
    required int id,
    required String fact,
    required MemoryCategory category,
    required DateTime updatedAt,
  }) {
    return Memory(
      id: id,
      fact: fact,
      category: category,
      createdAt: updatedAt,
      updatedAt: updatedAt,
      active: true,
    );
  }

  final t0 = DateTime(2024, 1, 1);
  final t1 = DateTime(2024, 1, 2);
  final t2 = DateTime(2024, 1, 3);

  // ---------------------------------------------------------------------------
  // Tests
  // ---------------------------------------------------------------------------

  group('empty input', () {
    test('empty list returns empty string', () {
      expect(FactsBlockComposer.compose([]), '');
    });
  });

  group('header', () {
    test('non-empty input starts with the expected header', () {
      final facts = [
        mem(
          id: 1,
          fact: 'name is Joe',
          category: MemoryCategory.identity,
          updatedAt: t0,
        ),
      ];
      final block = FactsBlockComposer.compose(facts);
      expect(
        block,
        startsWith('known facts about the user (saved across chats):'),
      );
    });
  });

  group('id-prefixed lines', () {
    test('single fact carries its id prefix', () {
      final facts = [
        mem(
          id: 7,
          fact: 'name is Joe',
          category: MemoryCategory.identity,
          updatedAt: t0,
        ),
      ];
      final block = FactsBlockComposer.compose(facts);
      expect(block, contains('#7 name is Joe'));
    });

    test(
      'multiple facts in one category are joined by semicolons with id prefixes',
      () {
        final facts = [
          mem(
            id: 1,
            fact: 'name is Joe',
            category: MemoryCategory.identity,
            updatedAt: t1,
          ),
          mem(
            id: 2,
            fact: 'lives in Cairo',
            category: MemoryCategory.identity,
            updatedAt: t0,
          ),
        ];
        final block = FactsBlockComposer.compose(facts);
        // Both ids must appear on the same category line.
        expect(block, contains('#1 name is Joe'));
        expect(block, contains('#2 lives in Cairo'));
        // Joined with '; '
        expect(block, contains('; #'));
      },
    );
  });

  group('category ordering', () {
    test(
      'categories appear in declaration order regardless of input order',
      () {
        final facts = [
          mem(
            id: 10,
            fact: 'wants metric units',
            category: MemoryCategory.preferences,
            updatedAt: t0,
          ),
          mem(
            id: 4,
            fact: 'builds Flutter apps',
            category: MemoryCategory.work,
            updatedAt: t0,
          ),
          mem(
            id: 1,
            fact: 'name is Joe',
            category: MemoryCategory.identity,
            updatedAt: t0,
          ),
          mem(
            id: 12,
            fact: 'uses vim',
            category: MemoryCategory.other,
            updatedAt: t0,
          ),
        ];
        final block = FactsBlockComposer.compose(facts);
        final identityPos = block.indexOf('identity');
        final workPos = block.indexOf('work');
        final prefsPos = block.indexOf('preferences');
        final otherPos = block.indexOf('other');
        expect(identityPos, lessThan(workPos));
        expect(workPos, lessThan(prefsPos));
        expect(prefsPos, lessThan(otherPos));
      },
    );

    test('only categories that have facts appear in the output', () {
      // Only identity + other facts → work and preferences lines must be absent.
      final facts = [
        mem(
          id: 1,
          fact: 'name is Joe',
          category: MemoryCategory.identity,
          updatedAt: t0,
        ),
        mem(
          id: 5,
          fact: 'uses vim',
          category: MemoryCategory.other,
          updatedAt: t0,
        ),
      ];
      final block = FactsBlockComposer.compose(facts);
      expect(block, contains('identity'));
      expect(block, contains('other'));
      expect(block, isNot(contains('work —')));
      expect(block, isNot(contains('preferences —')));
    });

    test('exact format matches data-model example shape', () {
      // data-model §2 example (abridged):
      // known facts about the user (saved across chats):
      // identity — #1 name is Joe; #2 lives in Cairo, Egypt (GMT+2)
      // work — #4 builds Android apps with Flutter and Dart; #5 mobile developer
      final facts = [
        mem(
          id: 1,
          fact: 'name is Joe',
          category: MemoryCategory.identity,
          updatedAt: t1,
        ),
        mem(
          id: 2,
          fact: 'lives in Cairo, Egypt (GMT+2)',
          category: MemoryCategory.identity,
          updatedAt: t0,
        ),
        mem(
          id: 4,
          fact: 'builds Android apps with Flutter and Dart',
          category: MemoryCategory.work,
          updatedAt: t1,
        ),
        mem(
          id: 5,
          fact: 'mobile developer',
          category: MemoryCategory.work,
          updatedAt: t0,
        ),
      ];
      final block = FactsBlockComposer.compose(facts);
      expect(
        block,
        contains('identity — #1 name is Joe; #2 lives in Cairo, Egypt (GMT+2)'),
      );
      expect(
        block,
        contains(
          'work — #4 builds Android apps with Flutter and Dart; #5 mobile developer',
        ),
      );
    });
  });

  group('updatedAt-desc ordering within category', () {
    test('most-recently updated fact appears first within its category', () {
      // id=3 has the newest updatedAt → should appear before id=1.
      final facts = [
        mem(
          id: 1,
          fact: 'old fact',
          category: MemoryCategory.identity,
          updatedAt: t0,
        ),
        mem(
          id: 3,
          fact: 'new fact',
          category: MemoryCategory.identity,
          updatedAt: t2,
        ),
      ];
      final block = FactsBlockComposer.compose(facts);
      final pos1 = block.indexOf('#1 old fact');
      final pos3 = block.indexOf('#3 new fact');
      expect(
        pos3,
        lessThan(pos1),
        reason: '#3 (newer) must come before #1 (older)',
      );
    });

    test('three facts in one category are desc-ordered', () {
      final facts = [
        mem(
          id: 10,
          fact: 'fact A',
          category: MemoryCategory.work,
          updatedAt: t0,
        ),
        mem(
          id: 20,
          fact: 'fact B',
          category: MemoryCategory.work,
          updatedAt: t2,
        ),
        mem(
          id: 30,
          fact: 'fact C',
          category: MemoryCategory.work,
          updatedAt: t1,
        ),
      ];
      final block = FactsBlockComposer.compose(facts);
      // Expected order: id=20 (t2), id=30 (t1), id=10 (t0)
      final pos20 = block.indexOf('#20');
      final pos30 = block.indexOf('#30');
      final pos10 = block.indexOf('#10');
      expect(pos20, lessThan(pos30));
      expect(pos30, lessThan(pos10));
    });

    test('ordering is defensive (input already in wrong order)', () {
      // Pass in ascending order; output must still be descending.
      final facts = [
        mem(
          id: 1,
          fact: 'oldest fact',
          category: MemoryCategory.preferences,
          updatedAt: t0,
        ),
        mem(
          id: 2,
          fact: 'middle fact',
          category: MemoryCategory.preferences,
          updatedAt: t1,
        ),
        mem(
          id: 3,
          fact: 'newest fact',
          category: MemoryCategory.preferences,
          updatedAt: t2,
        ),
      ];
      final block = FactsBlockComposer.compose(facts);
      final pos3 = block.indexOf('#3');
      final pos2 = block.indexOf('#2');
      final pos1 = block.indexOf('#1');
      expect(pos3, lessThan(pos2));
      expect(pos2, lessThan(pos1));
    });
  });

  group('20-fact count cap — oldest-first drop', () {
    test('exactly 20 facts are kept intact', () {
      final facts = List.generate(
        20,
        (i) => mem(
          id: i + 1,
          fact: 'fact $i',
          category: MemoryCategory.other,
          updatedAt: t0.add(Duration(hours: i)),
        ),
      );
      final block = FactsBlockComposer.compose(facts);
      for (final f in facts) {
        expect(block, contains('#${f.id}'));
      }
    });

    test('21st fact (oldest) is dropped when count exceeds 20', () {
      // id=1 has the earliest updatedAt → must be dropped when 21 facts are provided.
      final oldest = mem(
        id: 1,
        fact: 'i am oldest',
        category: MemoryCategory.other,
        updatedAt: t0,
      );
      final rest = List.generate(
        20,
        (i) => mem(
          id: i + 2,
          fact: 'fact $i',
          category: MemoryCategory.other,
          updatedAt: t1.add(Duration(hours: i)),
        ),
      );
      final block = FactsBlockComposer.compose([oldest, ...rest]);
      expect(block, isNot(contains('#1 i am oldest')));
      // All 20 newer facts are retained.
      for (final f in rest) {
        expect(block, contains('#${f.id}'));
      }
    });

    test('oldest facts are dropped across categories', () {
      // 11 identity + 11 work = 22 facts; the 2 globally oldest must be dropped.
      final allFacts = <Memory>[];
      for (int i = 0; i < 11; i++) {
        allFacts.add(
          mem(
            id: i + 1,
            fact: 'identity $i',
            category: MemoryCategory.identity,
            updatedAt: DateTime(2024, 1, i + 1),
          ),
        );
        allFacts.add(
          mem(
            id: i + 101,
            fact: 'work $i',
            category: MemoryCategory.work,
            updatedAt: DateTime(2024, 2, i + 1),
          ),
        );
      }
      final block = FactsBlockComposer.compose(allFacts);
      // Count retained facts by counting '#' occurrences in fact positions.
      final idMatches = RegExp(r'#\d+').allMatches(block).length;
      expect(idMatches, 20);
      // The 2 globally oldest are identity i=0 (Jan 1) and identity i=1 (Jan 2).
      expect(block, isNot(contains('#1 identity 0')));
      expect(block, isNot(contains('#2 identity 1')));
    });
  });

  group('900-char char cap — oldest-first drop', () {
    test('output is within 900 chars for a normal fact set', () {
      final facts = List.generate(
        10,
        (i) => mem(
          id: i + 1,
          fact: 'short fact $i',
          category: MemoryCategory.other,
          updatedAt: t0.add(Duration(hours: i)),
        ),
      );
      final block = FactsBlockComposer.compose(facts);
      expect(block.length, lessThanOrEqualTo(900));
    });

    test('long facts are trimmed to ≤ 900 chars by dropping oldest first', () {
      // Build 15 facts each ~70 chars; the combined block will exceed 900 chars.
      // The globally oldest (id=1, updatedAt earliest) must be absent from the final block.
      final oldest = mem(
        id: 1,
        fact: 'a' * 70, // 70-char fact
        category: MemoryCategory.preferences,
        updatedAt: t0,
      );
      final rest = List.generate(
        14,
        (i) => mem(
          id: i + 2,
          fact: 'b' * 70, // 70-char fact
          category: MemoryCategory.preferences,
          updatedAt: t1.add(Duration(hours: i + 1)),
        ),
      );
      final block = FactsBlockComposer.compose([oldest, ...rest]);
      expect(block.length, lessThanOrEqualTo(900));
      // The oldest fact must have been trimmed (its content is 70 × 'a').
      expect(block, isNot(contains('a' * 70)));
    });

    test('empty string returned when every fact would push the block over the cap', () {
      // One very long single fact that itself exceeds 900 chars is not the scenario (facts are
      // capped at 80 chars each); but a block with just the header (48 chars) + one 80-char fact
      // +category line  is well under 900.  The cap can only trigger with several facts.
      // Verify the extreme: 20 × 80-char facts → the block is under 900 or it is trimmed without
      // returning empty (empty only when nothing fits at all).
      //
      // With the header at ~48 chars and each category line being ~87 chars (category + ' — ' + id
      // prefix + 80-char fact), 10 facts in one category ≈ 48 + 10*89 ≈ 938 chars → over 900.
      // So the composer must drop some.
      final facts = List.generate(
        10,
        (i) => mem(
          id: i + 1,
          fact: 'x' * 79, // 79-char fact (within the 80 limit)
          category: MemoryCategory.other,
          updatedAt: t0.add(Duration(hours: i)),
        ),
      );
      final block = FactsBlockComposer.compose(facts);
      // Must be non-empty (at least 1 fact fits) AND within 900 chars.
      expect(block, isNotEmpty);
      expect(block.length, lessThanOrEqualTo(900));
    });

    test(
      'empty string only when the list is empty, not due to char trimming alone',
      () {
        // Confirm that even a 1-fact list (within individual fact size bounds) always produces a
        // non-empty block — char cap never empties a valid single-fact store.
        final single = [
          mem(
            id: 42,
            fact: 'name is Alice',
            category: MemoryCategory.identity,
            updatedAt: t0,
          ),
        ];
        expect(FactsBlockComposer.compose(single), isNotEmpty);
      },
    );
  });

  group('combined count + char cap', () {
    test('both caps applied when 21 long facts provided', () {
      // 21 facts × 79 chars each exceeds both the count cap (21 > 20) and the char cap.
      // The oldest must be dropped; the result must be ≤ 900 chars.
      final facts = List.generate(
        21,
        (i) => mem(
          id: i + 1,
          fact:
              'y' * 60 + i.toString().padLeft(2, '0'), // unique, 62-char facts
          category: MemoryCategory.work,
          updatedAt: t0.add(Duration(hours: i)),
        ),
      );
      final block = FactsBlockComposer.compose(facts);
      // id=1 (oldest) must be absent.
      expect(block, isNot(contains('#1 ')));
      expect(block.length, lessThanOrEqualTo(900));
    });
  });
}
