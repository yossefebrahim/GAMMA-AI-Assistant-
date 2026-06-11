/// Suppresses the raw tool-call JSON leak that flutter_gemma 0.15.3 spills into the TEXT channel
/// on 100% of tool calls (spike §3, contract guarantee 20). PURE — no plugin import — so it is
/// unit-tested against the spike's captured chunk shapes without a device.
///
/// The leak is a CHUNK-LEVEL, position-independent phenomenon: the plugin's
/// `extractTextFromResponse` passes any chunk lacking a `content` key through verbatim, so the raw
/// SDK JSON (`{"role":"assistant","tool_calls":[…]}`) streams as text BEFORE the typed
/// `FunctionCallResponse` arrives — and it can FOLLOW legitimate prose deltas in the same turn.
///
/// Strategy (guarantee 20): while tools are [active], from the first chunk whose trimmed text
/// starts with `{`, all subsequent text is WITHHELD; prose emitted before that chunk flows
/// normally. The turn's terminator decides the withheld text's fate:
///   * ends in a tool call → [discardOnToolCall] (it was the leak);
///   * ends as text        → [flushOnText] emits it verbatim (it was legitimate prose that merely
///     happened to start with `{` — a false positive; fidelity is preserved).
///
/// With tools inactive (flag off) the filter is a pass-through — byte-parity with 003 (guarantee
/// 19). One instance per `generate`/`resumeWithToolResult` stream; not reused across turns.
class LeakFilter {
  LeakFilter({this.active = true});

  /// When false (flag off), every chunk passes through untouched — no buffering, no behavior
  /// change vs. 003.
  final bool active;

  final StringBuffer _withheld = StringBuffer();
  bool _withholding = false;

  /// Whether the filter is currently holding back suspected leak text (exposed for assertions).
  bool get isWithholding => _withholding;

  /// Process one streamed text [chunk]; returns the text to emit downstream (may be empty when
  /// withholding). Once a chunk (trimmed) starts with `{`, this and every subsequent chunk are
  /// withheld until the turn terminates.
  String process(String chunk) {
    if (!active) return chunk;
    if (_withholding) {
      _withheld.write(chunk);
      return '';
    }
    if (chunk.trimLeft().startsWith('{')) {
      _withholding = true;
      _withheld.write(chunk);
      return '';
    }
    return chunk;
  }

  /// The turn ended WITHOUT a tool call: the withheld text was legitimate prose (a `{`-prefix
  /// false positive). Return it verbatim to emit, and reset for safety.
  String flushOnText() {
    final pending = _withheld.toString();
    _reset();
    return pending;
  }

  /// The turn ended in a tool call: the withheld text was the raw-JSON leak — discard it.
  void discardOnToolCall() => _reset();

  void _reset() {
    _withheld.clear();
    _withholding = false;
  }
}
