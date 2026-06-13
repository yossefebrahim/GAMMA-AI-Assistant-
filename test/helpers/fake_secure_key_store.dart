import 'package:ai_assistant/domain/services/secure_key_store.dart';

/// In-memory [SecureKeyStore] test double (006, contracts/secure_key_store.md).
///
/// Backed by a single [String? _storedKey] field. All four interface methods return
/// [Future.value] synchronously. Exposes [clearWasCalled] for asserting the clear-then-absent
/// invariant in gating tests.
///
/// Does NOT import `flutter_secure_storage` or `dart:io` — pure Dart (Principle VII).
class FakeSecureKeyStore implements SecureKeyStore {
  String? _storedKey;

  /// True iff [clearTavilyKey] has been called at least once since the last reset.
  bool clearWasCalled = false;

  /// Pre-seed the stored key (e.g. to simulate a key already written at app start).
  void seed(String key) => _storedKey = key;

  /// Reset state between tests.
  void reset() {
    _storedKey = null;
    clearWasCalled = false;
  }

  @override
  Future<String?> readTavilyKey() => Future.value(_storedKey);

  @override
  Future<void> writeTavilyKey(String key) {
    _storedKey = key;
    return Future.value();
  }

  @override
  Future<void> clearTavilyKey() {
    _storedKey = null;
    clearWasCalled = true;
    return Future.value();
  }

  @override
  Future<bool> hasValidKey() {
    final key = _storedKey;
    return Future.value(key != null && key.isNotEmpty);
  }
}
