/// Raised when no clock app can handle the SET_TIMER intent (R4, FR-015). Its [toString] is the
/// lowercase reason the dispatcher surfaces on the chip and tells the model.
class TimerUnavailableException implements Exception {
  const TimerUnavailableException();
  @override
  String toString() => 'no clock app available';
}

/// The `set_timer` tool seam (004 R4, spec Q2). Fires the system clock's SET_TIMER intent behind an
/// interface so the handler wiring is testable with a fake, while the concrete
/// `AndroidIntentTimerService` (in `lib/infrastructure/tools/`) is the ONLY importer of
/// `android_intent_plus` (Principle VII).
///
/// Bounds (1..86,400 s) are schema-enforced BEFORE the handler runs (R3), so this only fires the
/// intent. A silent hand-off (EXTRA_SKIP_UI): the user stays in the conversation; the timer runs in
/// the system clock and survives app death. Throws [TimerUnavailableException] when no clock app
/// resolves the intent.
abstract interface class TimerIntentService {
  Future<void> setTimer({required int seconds, String? label});
}
