/// The ONE shared byte-size formatter (P10-1): `<= 0` → `'0B'`, otherwise step up through
/// `B` / `KB` / `MB` / `GB` and render with 0 decimals when the value is `>= 10` or still in bytes,
/// else 1 decimal. Used by the download progress readout and the settings model-storage line so the
/// formatting rule lives in exactly one place.
String formatBytes(int bytes) {
  if (bytes <= 0) return '0B';
  const units = ['B', 'KB', 'MB', 'GB'];
  var size = bytes.toDouble();
  var unit = 0;
  while (size >= 1024 && unit < units.length - 1) {
    size /= 1024;
    unit++;
  }
  final decimals = (size >= 10 || unit == 0) ? 0 : 1;
  return '${size.toStringAsFixed(decimals)}${units[unit]}';
}
