import 'package:ai_assistant/domain/services/web_url_launcher.dart';
import 'package:android_intent_plus/android_intent.dart';
import 'package:flutter/services.dart' show PlatformException;

/// `android_intent_plus`-backed [WebUrlLauncher] (006 T033) — confined to
/// `lib/infrastructure/tools/` (enforced by tool/check_plugin_seam.sh, alongside the 004
/// `AndroidIntentTimerService`). Fires `ACTION_VIEW` at the source URL so the device's default
/// browser opens it.
///
/// A non-resolvable target (no browser installed) or a launch failure is swallowed: opening a
/// source URL is a best-effort affordance, never a crash path for the chat surface (Principle V).
class AndroidIntentUrlLauncher implements WebUrlLauncher {
  const AndroidIntentUrlLauncher();

  static const String _actionView = 'android.intent.action.VIEW';

  @override
  Future<void> open(String url) async {
    final intent = AndroidIntent(action: _actionView, data: url);
    try {
      if (await intent.canResolveActivity() != true) return;
      await intent.launch();
    } on PlatformException {
      // ActivityNotFoundException on some OEMs despite resolving — best-effort, no crash.
      return;
    }
  }
}
