import 'package:ai_assistant/domain/services/clipboard_tool_service.dart';

/// In-memory [ClipboardToolService] for tests (004 US5). Set [text] to the clipboard contents, or
/// null to simulate an empty/non-text clipboard (→ [ClipboardEmptyException]). Applies the same
/// 4,000-char bound as the real service.
class FakeClipboardToolService implements ClipboardToolService {
  FakeClipboardToolService({this.text});

  String? text;
  int callCount = 0;

  @override
  Future<Map<String, Object?>> read() async {
    callCount++;
    final value = text;
    if (value == null || value.isEmpty) {
      throw const ClipboardEmptyException();
    }
    const max = ClipboardToolService.maxClipboardChars;
    if (value.length > max) {
      return {'text': value.substring(0, max), 'truncated': true};
    }
    return {'text': value, 'truncated': false};
  }
}
