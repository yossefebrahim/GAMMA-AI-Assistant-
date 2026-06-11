import 'package:ai_assistant/domain/services/timer_intent_service.dart';
import 'package:android_intent_plus/android_intent.dart';
import 'package:flutter/services.dart' show PlatformException;

/// `android_intent_plus`-backed [TimerIntentService] (004 R4) — the ONLY importer of
/// `android_intent_plus` (confined to `lib/infrastructure/tools/`, enforced by
/// tool/check_plugin_seam.sh). Fires `AlarmClock.ACTION_SET_TIMER` with `EXTRA_SKIP_UI` so the
/// hand-off is silent (spec Q2): the user stays in the conversation.
class AndroidIntentTimerService implements TimerIntentService {
  const AndroidIntentTimerService();

  // AlarmClock intent + extras (android.provider.AlarmClock constants).
  static const String _actionSetTimer = 'android.intent.action.SET_TIMER';
  static const String _extraLength = 'android.intent.extra.alarm.LENGTH';
  static const String _extraMessage = 'android.intent.extra.alarm.MESSAGE';
  static const String _extraSkipUi = 'android.intent.extra.alarm.SKIP_UI';

  @override
  Future<void> setTimer({required int seconds, String? label}) async {
    final intent = AndroidIntent(
      action: _actionSetTimer,
      arguments: <String, dynamic>{
        _extraLength: seconds,
        _extraSkipUi: true,
        if (label != null && label.isNotEmpty) _extraMessage: label,
      },
    );
    // Android 11+ package visibility: without the manifest <queries> entry this resolves to null
    // even with SET_ALARM granted. A null/false resolution → structured failure (FR-015).
    final resolvable = await intent.canResolveActivity();
    if (resolvable != true) {
      throw const TimerUnavailableException();
    }
    try {
      await intent.launch();
    } on PlatformException {
      // ActivityNotFoundException surfaces here on some OEMs despite resolving — same honest error.
      throw const TimerUnavailableException();
    }
  }
}
