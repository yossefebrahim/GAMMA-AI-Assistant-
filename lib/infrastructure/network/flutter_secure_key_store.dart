import 'package:ai_assistant/domain/services/secure_key_store.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Concrete [SecureKeyStore] backed by [FlutterSecureStorage] (006, T026).
///
/// This is the ONLY file in the codebase permitted to import `flutter_secure_storage`
/// (enforced by `check_network_seam.sh` + `check_plugin_seam.sh`, Principle VII). All other
/// code interacts with the key exclusively via the [SecureKeyStore] interface.
///
/// **Storage**: AES/GCM/NoPadding (data) + RSA OAEP/SHA-256/MGF1Padding (key wrapping) inside
/// the Android Keystore TEE. The encrypted blob is stored in SharedPreferences under the stable
/// key name [_kKeyName]. This is the default behaviour of `flutter_secure_storage 10.x` with the
/// default [AndroidOptions] constructor.
///
/// **`encryptedSharedPreferences: true` MUST NOT be passed** to [AndroidOptions] — it is
/// deprecated in `flutter_secure_storage 10.x`. The default constructor uses the RSA-OAEP path.
///
/// **Key never logged**: the key string is used only as the `Authorization: Bearer` header value
/// in `TavilyNetworkResearchService`; it never appears in `print()`, `debugPrint()`, log calls,
/// or exception messages. Exceptions from the underlying storage are caught and their messages
/// sanitised before propagation (SC-015, FR-003).
class FlutterSecureKeyStore implements SecureKeyStore {
  // Stable storage key — never changes across app versions (would lose the stored key if renamed).
  static const String _kKeyName = 'tavily_api_key';

  // Default AndroidOptions (no encryptedSharedPreferences — deprecated in 10.x).
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions.defaultOptions,
  );

  @override
  Future<String?> readTavilyKey() async {
    try {
      final value = await _storage.read(key: _kKeyName);
      if (value == null || value.isEmpty) return null;
      return value;
    } catch (_) {
      // Never expose the key in caught exceptions. Return null on any read error
      // (e.g. Keystore unavailable) — callers must handle null as "no key".
      return null;
    }
  }

  @override
  Future<void> writeTavilyKey(String key) async {
    // key must be non-empty (enforced upstream by the Settings form).
    // Never log `key` — not here, not in exceptions.
    try {
      await _storage.write(key: _kKeyName, value: key);
    } catch (e) {
      // Re-throw as a safe exception without the key string in the message.
      throw Exception('SecureKeyStore: write failed (storage unavailable)');
    }
  }

  @override
  Future<void> clearTavilyKey() async {
    try {
      await _storage.delete(key: _kKeyName);
    } catch (_) {
      // Idempotent — if deletion fails (e.g. already absent), treat as success.
    }
  }

  @override
  Future<bool> hasValidKey() async {
    try {
      final value = await _storage.read(key: _kKeyName);
      return value != null && value.isNotEmpty;
    } catch (_) {
      return false;
    }
  }
}
