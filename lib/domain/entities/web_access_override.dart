/// Three-state per-conversation web-access toggle (006, data-model §1, FR-007).
///
/// Persisted as `conversations.web_access_override` (TEXT or NULL — see data-model §2). The NULL
/// representation IS the [inherit] state; the enum name is never written to the DB for [inherit]
/// (null coercion: null DB value → [inherit]).
enum WebAccessOverride {
  /// Use the app-level `webAccessEnabled` setting. Stored as NULL in the DB. This is the default
  /// for all new and existing conversations.
  inherit,

  /// Force web tools ON for this conversation, overriding a global-off setting. Stored as `'on'`.
  on,

  /// Force web tools OFF for this conversation, overriding a global-on setting. Stored as `'off'`.
  off;

  /// Resolves the effective web-access flag given the app-level [globalEnabled] setting.
  ///
  /// - [inherit] → [globalEnabled]
  /// - [on] → `true`
  /// - [off] → `false`
  bool effectiveWebEnabled(bool globalEnabled) => switch (this) {
    WebAccessOverride.inherit => globalEnabled,
    WebAccessOverride.on => true,
    WebAccessOverride.off => false,
  };
}
