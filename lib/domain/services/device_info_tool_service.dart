/// The `get_device_info` tool seam (004 R4). Reads device facts — model/OS, RAM, battery, free
/// storage — behind an interface so the controller/handler wiring is testable with a fake while the
/// concrete `PlatformDeviceInfoToolService` (in `lib/infrastructure/tools/`) is the ONLY importer of
/// `battery_plus` + the StatFs channel (Principle VII; device_info_plus is already in the stack).
///
/// Contract: returns the FULL device snapshot as a structured map (the spike trial-10 lesson — the
/// optional `section` arg only orders/labels; always return the superset). Each field degrades to
/// `'unknown'` on a probe failure; the service NEVER throws (the dispatcher would map a throw to a
/// failure, but graceful per-field degradation gives the model more to work with — Principle V).
abstract interface class DeviceInfoToolService {
  /// Read the device snapshot. [args] may carry the optional `section`; it does not change WHICH
  /// fields are returned (superset always), only how the model is expected to present them.
  Future<Map<String, Object?>> read(Map<String, Object?> args);
}
