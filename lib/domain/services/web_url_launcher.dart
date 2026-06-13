/// The source-URL-chip browser hand-off seam (006 T033, FR-013). Opens a source URL in the
/// device's default browser behind an interface so the chip's tap handler is testable with a fake,
/// while the concrete `AndroidIntentUrlLauncher` (in `lib/infrastructure/tools/`) is the ONLY
/// new importer of `android_intent_plus` for this feature (Principle VII).
///
/// A tappable source URL chip renders beneath every successful web tool reply (FR-013); tapping it
/// fires an `ACTION_VIEW` intent at the URL. The URL is always one already shown to the user on the
/// chip — never user content leaving the device silently (Principle I).
abstract interface class WebUrlLauncher {
  /// Open [url] in the default browser. Implementations swallow a non-resolvable target rather than
  /// throwing — a missing browser is not a failure the chat surface should crash on (Principle V).
  Future<void> open(String url);
}
