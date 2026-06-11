/// Raised when the clipboard is empty or holds non-text content (R4, FR-025). Its [toString] is the
/// lowercase reason the dispatcher surfaces on the chip and tells the model.
class ClipboardEmptyException implements Exception {
  const ClipboardEmptyException();
  @override
  String toString() => 'clipboard empty or not text';
}

/// The `summarize_clipboard` tool seam (004 R4). Reads the clipboard text at execution time behind
/// an interface so the handler wiring is testable with a fake (the Flutter `Clipboard` platform
/// channel is unavailable in unit tests). The concrete `FlutterClipboardToolService` (in
/// `lib/infrastructure/tools/`) wraps Flutter's built-in clipboard.
///
/// Returns `{text, truncated}` — the bounded clipboard text (capped at [maxClipboardChars] with a
/// `truncated` marker); the SUMMARY itself happens in the resumed generation, not here. Throws
/// [ClipboardEmptyException] when the clipboard is empty or not text (foreground-only on Android
/// 10+ — the tool runs during an active turn, so the app holds focus; the OS may toast the read).
abstract interface class ClipboardToolService {
  /// Clipboard text cap (R4): 4,000 chars, leaving ~400 for the JSON envelope under the tool's
  /// 4,400-char `resultCharBound`.
  static const int maxClipboardChars = 4000;

  Future<Map<String, Object?>> read();
}
