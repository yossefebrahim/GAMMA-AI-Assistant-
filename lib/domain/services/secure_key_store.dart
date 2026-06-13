/// Plugin-free interface for secure API-key storage (006, contracts/secure_key_store.md,
/// Principle VII). The sole concrete implementation, `FlutterSecureKeyStore`, lives in
/// `lib/infrastructure/network/flutter_secure_key_store.dart` and is the ONLY file permitted to
/// import `flutter_secure_storage`.
///
/// All Settings widgets, Riverpod providers, and domain classes interact with the key exclusively
/// via this interface, injected through Riverpod.
abstract interface class SecureKeyStore {
  /// Read the stored Tavily API key.
  ///
  /// Returns `null` if no key has been written or if the key was cleared.
  /// Never throws; returns `null` on any read error (e.g. Keystore unavailable).
  Future<String?> readTavilyKey();

  /// Persist [key] in Android Keystore-backed encrypted storage.
  ///
  /// [key] must be non-empty (enforced by the Settings form upstream). Overwrites any previously
  /// stored key. Never logs [key] — not in debug output, not in crash reports.
  Future<void> writeTavilyKey(String key);

  /// Remove the stored key from encrypted storage.
  ///
  /// After this call, [readTavilyKey] returns `null`. Idempotent — calling clear when no key is
  /// stored is a no-op, not an error.
  Future<void> clearTavilyKey();

  /// True iff a non-empty key is currently stored.
  ///
  /// Equivalent to `(await readTavilyKey()) != null && key.isNotEmpty`, but provided as a cheap
  /// poll for the triple-gate and the Settings UI (avoids passing the raw key value through
  /// provider state).
  Future<bool> hasValidKey();
}
