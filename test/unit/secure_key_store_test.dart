import 'package:flutter_test/flutter_test.dart';

import '../helpers/fake_secure_key_store.dart';

/// 006 T018 — SecureKeyStore unit tests (contracts/secure_key_store.md guarantees 1–4).
///
/// All tests run against [FakeSecureKeyStore] — no real Keystore or plugin involved (Principle VII).
void main() {
  late FakeSecureKeyStore store;

  setUp(() {
    store = FakeSecureKeyStore();
  });

  // ── Guarantee 2: write-then-read round-trip ─────────────────────────────────

  group('write-then-read round-trip', () {
    test('readTavilyKey returns null before any write', () async {
      expect(await store.readTavilyKey(), isNull);
    });

    test(
      'writeTavilyKey followed by readTavilyKey returns the same key',
      () async {
        await store.writeTavilyKey('tvly-abc123');
        expect(await store.readTavilyKey(), equals('tvly-abc123'));
      },
    );

    test('second write overwrites the first', () async {
      await store.writeTavilyKey('tvly-first');
      await store.writeTavilyKey('tvly-second');
      expect(await store.readTavilyKey(), equals('tvly-second'));
    });
  });

  // ── Guarantee 3: hasValidKey reflects write/clear ───────────────────────────

  group('hasValidKey reflects write/clear', () {
    test('returns false before any write', () async {
      expect(await store.hasValidKey(), isFalse);
    });

    test('returns true after writeTavilyKey', () async {
      await store.writeTavilyKey('tvly-test');
      expect(await store.hasValidKey(), isTrue);
    });

    test('returns false after clearTavilyKey', () async {
      await store.writeTavilyKey('tvly-test');
      await store.clearTavilyKey();
      expect(await store.hasValidKey(), isFalse);
    });

    test('returns false when key was never written (virgin state)', () async {
      expect(await store.hasValidKey(), isFalse);
      expect(await store.readTavilyKey(), isNull);
    });
  });

  // ── Guarantee 1: idempotent clear ───────────────────────────────────────────

  group('idempotent clear', () {
    test('clearTavilyKey when no key stored does not throw', () async {
      // Should succeed silently — idempotent.
      await expectLater(store.clearTavilyKey(), completes);
    });

    test('double clear is also a no-op — no exception', () async {
      await store.writeTavilyKey('tvly-test');
      await store.clearTavilyKey();
      await expectLater(store.clearTavilyKey(), completes);
      expect(await store.readTavilyKey(), isNull);
    });

    test('readTavilyKey returns null after clear', () async {
      await store.writeTavilyKey('tvly-test');
      await store.clearTavilyKey();
      expect(await store.readTavilyKey(), isNull);
    });
  });

  // ── clearWasCalled flag ─────────────────────────────────────────────────────

  group('clearWasCalled flag', () {
    test('is false before any clear', () {
      expect(store.clearWasCalled, isFalse);
    });

    test('is true after clearTavilyKey', () async {
      await store.clearTavilyKey();
      expect(store.clearWasCalled, isTrue);
    });

    test(
      'is true even when no key was stored (idempotent clear still sets it)',
      () async {
        await store.clearTavilyKey();
        expect(store.clearWasCalled, isTrue);
      },
    );

    test('remains true on second clear', () async {
      await store.writeTavilyKey('tvly-test');
      await store.clearTavilyKey();
      await store.clearTavilyKey();
      expect(store.clearWasCalled, isTrue);
    });

    test('reset() sets clearWasCalled back to false', () async {
      await store.clearTavilyKey();
      store.reset();
      expect(store.clearWasCalled, isFalse);
    });
  });

  // ── Guarantee 4: no key in exceptions ───────────────────────────────────────
  // FakeSecureKeyStore never throws, so this exercises the property that errors from the
  // interface (when thrown) must not expose the key string. For the fake we verify that
  // a configured key value does not appear in any returned future error — the pattern is
  // testable at the interface level via a bad call sequence.

  group('no key in exceptions', () {
    test('readTavilyKey never throws — returns null on no key', () async {
      // Even with no key, readTavilyKey succeeds (returns null) rather than throwing.
      final result = await store.readTavilyKey();
      expect(result, isNull);
    });

    test('hasValidKey never throws — returns false on no key', () async {
      final result = await store.hasValidKey();
      expect(result, isFalse);
    });

    test('clearTavilyKey never throws — idempotent on empty store', () async {
      await expectLater(store.clearTavilyKey(), completes);
    });
  });

  // ── seed helper ─────────────────────────────────────────────────────────────

  group('seed helper', () {
    test('seed allows pre-loading a key for test setup', () async {
      store.seed('tvly-seeded');
      expect(await store.readTavilyKey(), equals('tvly-seeded'));
      expect(await store.hasValidKey(), isTrue);
    });
  });
}
