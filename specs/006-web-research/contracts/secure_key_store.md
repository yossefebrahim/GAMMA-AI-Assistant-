# Contract — SecureKeyStore (006)

Plugin-free interface (Principle VII, Constitution v2.0.0). Defined in
`lib/domain/services/secure_key_store.dart` (pure Dart — no `flutter_secure_storage` import).
The sole concrete implementation, `FlutterSecureKeyStore`, lives in
`lib/infrastructure/network/flutter_secure_key_store.dart` and is the ONLY file permitted to
import `flutter_secure_storage` (enforced by `check_network_seam.sh`).

All Settings widgets, Riverpod providers, and domain classes interact with the key exclusively
via this interface, injected through Riverpod. The abstract `SecureKeyStore` type is importable
from domain; the concrete `flutter_secure_storage` API is invisible above the infrastructure
layer.

---

## Interface

```dart
abstract interface class SecureKeyStore {
  /// Read the stored Tavily API key.
  /// Returns null if no key has been written or if the key was cleared.
  /// Never throws; returns null on any read error (e.g. Keystore unavailable).
  Future<String?> readTavilyKey();

  /// Persist [key] in Android Keystore-backed encrypted storage.
  /// [key] must be non-empty (enforced by the Settings form upstream).
  /// Overwrites any previously stored key.
  /// Never logs [key] — not in debug output, not in crash reports.
  Future<void> writeTavilyKey(String key);

  /// Remove the stored key from encrypted storage.
  /// After this call, [readTavilyKey] returns null.
  /// Idempotent — calling clear when no key is stored is a no-op, not an error.
  Future<void> clearTavilyKey();

  /// True iff a non-empty key is currently stored.
  /// Equivalent to `(await readTavilyKey()) != null && key.isNotEmpty`,
  /// but provided as a cheap poll for the triple-gate and the Settings UI
  /// (avoids passing the raw key value through provider state).
  Future<bool> hasValidKey();
}
```

---

## Storage mechanism

**Given** `flutter_secure_storage ^10.3.1` is the underlying implementation on Android,
**Then** the Tavily key is stored as follows:

- **Encryption**: AES/GCM/NoPadding (data) + RSA OAEP/SHA-256/MGF1Padding (key wrapping).
  The AES key is generated inside the Android Keystore hardware security module (Samsung A34:
  embedded Keystore in the Dimensity 1080 TEE). The encrypted blob is written to
  `SharedPreferences` under a stable key name (`tavily_api_key`).
- **`encryptedSharedPreferences: true` MUST NOT be passed** to `AndroidOptions` — it is
  deprecated in `flutter_secure_storage 10.x` and removed in favour of the RSA-OAEP path.
  The default `AndroidOptions()` constructor is correct.
- **Access scope**: the data is bound to the app's UID on the device. It persists across app
  restarts and OS updates; it does NOT survive a factory reset or an app uninstall (Keystore
  entry is tied to the app install; this is intentional — key must be re-entered after reinstall).
- **minSdk**: `flutter_secure_storage 10.x` requires `minSdkVersion = 23`; the project's
  `minSdk = 29` — no conflict.

---

## Never-logged guarantee (FR-003, SC-015)

1. **Given** `FlutterSecureKeyStore.writeTavilyKey(key)` is called,
   **Then** `key` MUST NOT appear in any `print()`, `debugPrint()`, `Logger.log()`,
   `FlutterError.reportError()`, or crash-report breadcrumb call, either directly or via
   `toString()` interpolation.

2. **Given** `readTavilyKey()` returns a non-null value,
   **Then** the returned string MUST NOT be passed to any logging facility. The caller
   (`TavilyNetworkResearchService`) uses it exclusively as the `Authorization: Bearer` header
   value; it is not stored in a Dart variable that persists beyond the HTTP request scope.

3. **Given** any exception is thrown by `flutter_secure_storage`,
   **Then** the exception's `message` field MUST NOT include the key value. The seam catches
   storage exceptions before they propagate and logs only the error type + a safe code,
   never the key string. `readTavilyKey()` returns null on any storage error.

4. **Given** the Settings key-entry field is submitted,
   **Then** the key value MUST NOT be written to: the SQLite conversation DB, any
   `tool_args`/`tool_result` column, any Riverpod state that persists to disk, or any
   analytics/telemetry path (none exist in this project). The key lives ONLY in
   `flutter_secure_storage`.

---

## UI masking guarantee (FR-003)

- After `writeTavilyKey()` completes, the Settings UI MUST display the key as masked
  (e.g. `••••••••••••` or `saved — tap to replace`). It MUST NOT re-display the plaintext key
  value from `readTavilyKey()` in any text field or label.
- `hasValidKey()` (not `readTavilyKey()`) drives the UI gating logic (toggle enabled/disabled,
  "no key" prompt) to avoid passing the plaintext through Riverpod state unnecessarily.

---

## Clear semantics (FR-004)

**Given** `clearTavilyKey()` is called (user taps "clear key"),
**Then** ALL of the following MUST occur atomically from the user's perspective:

1. The key entry is removed from `flutter_secure_storage` (Keystore entry + `SharedPreferences`
   blob deleted).
2. The global `webAccessEnabled` flag in the app settings row is set to `false`.
3. The per-conversation `webAccessOverride` for the current open conversation (if any) is set
   to `inherit` (NULL), so the global-off default applies immediately.
4. Any live LiteRT-LM session that had web tools declared is recreated without web tools (via
   `GemmaService.startSession`), consistent with FR-032.
5. `hasValidKey()` returns `false` on the next call.

After clear, `readTavilyKey()` returns `null` and `hasValidKey()` returns `false`. The seam
MUST NOT retain the key in memory (e.g. a cached field) after `clearTavilyKey()` completes.

---

## Guarantees (unit-testable via `FakeSecureKeyStore`)

1. **Idempotent clear**: calling `clearTavilyKey()` when no key is stored succeeds silently —
   no exception, no state change.
2. **Write-then-read round-trip**: `writeTavilyKey(k)` followed immediately by `readTavilyKey()`
   returns `k` (assuming no intervening clear and no Keystore failure).
3. **`hasValidKey()` reflects write/clear**: returns `true` after `writeTavilyKey` and `false`
   after `clearTavilyKey` or when no key has ever been written.
4. **No key in exceptions**: exceptions thrown by the concrete implementation (Keystore
   unavailable, etc.) MUST NOT contain the key string in their `message` or `toString()`.
5. **Seam import isolation**: `flutter_secure_storage` is imported ONLY in
   `lib/infrastructure/network/flutter_secure_key_store.dart`. `check_network_seam.sh`
   fails CI if any other file imports it.

---

## Fake / test double

`FakeSecureKeyStore` (in-memory `Map<String, String>`, plugin-free) for Settings provider,
triple-gate, and handler tests:

- Backed by an in-memory `String? _storedKey` field.
- Implements all four interface methods with synchronous `Future.value(...)` returns.
- Exposes `clearWasCalled` flag for testing the clear-then-tools-absent invariant.
- Does NOT import `flutter_secure_storage` or `dart:io`.
