import 'package:ai_assistant/domain/services/timer_intent_service.dart';

/// In-memory [TimerIntentService] for tests — an intent sink that records the payload it was asked
/// to fire, and can simulate a device with no clock app (004 US4).
class FakeTimerIntentService implements TimerIntentService {
  /// When true, [setTimer] throws [TimerUnavailableException] (no clock app resolves the intent).
  bool unavailable = false;

  int? lastSeconds;
  String? lastLabel;
  int callCount = 0;

  @override
  Future<void> setTimer({required int seconds, String? label}) async {
    callCount++;
    if (unavailable) throw const TimerUnavailableException();
    lastSeconds = seconds;
    lastLabel = label;
  }
}
