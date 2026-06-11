import 'package:ai_assistant/domain/services/clipboard_tool_service.dart';
import 'package:flutter/services.dart' show Clipboard;

/// Flutter built-in clipboard-backed [ClipboardToolService] (004 R4) — no new dependency. Reads
/// `text/plain` at execution time, bounds it to [ClipboardToolService.maxClipboardChars] with a
/// `truncated` marker, and maps an empty/non-text clipboard to [ClipboardEmptyException].
class FlutterClipboardToolService implements ClipboardToolService {
  const FlutterClipboardToolService();

  @override
  Future<Map<String, Object?>> read() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty) {
      throw const ClipboardEmptyException();
    }
    const max = ClipboardToolService.maxClipboardChars;
    if (text.length > max) {
      return {'text': text.substring(0, max), 'truncated': true};
    }
    return {'text': text, 'truncated': false};
  }
}
