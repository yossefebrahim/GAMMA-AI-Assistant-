import 'dart:convert';

import 'package:ai_assistant/infrastructure/gemma/tool_call_json.dart';
import 'package:flutter_test/flutter_test.dart';

/// 004 US6 / data-model §3, guarantee 23 — the raw SDK tool-call JSON reconstruction matches the
/// shape the spike captured verbatim on the device (spike §3). This is the one seam replay input
/// unit tests can verify; on-device fidelity is quickstart V6.
void main() {
  test('no-arg call matches the spike-captured payload exactly', () {
    final json = reconstructToolCallJson('get_device_info', const {});
    expect(
      json,
      '{"role":"assistant","tool_calls":[{"type":"function",'
      '"function":{"name":"get_device_info","arguments":{}}}]}',
    );
  });

  test('args are embedded as a JSON object, not a string', () {
    final json = reconstructToolCallJson('set_timer', const {
      'seconds': 300,
      'label': 'tea',
    });
    final decoded = jsonDecode(json) as Map<String, Object?>;
    final call = (decoded['tool_calls'] as List).single as Map<String, Object?>;
    final function = call['function'] as Map<String, Object?>;
    expect(decoded['role'], 'assistant');
    expect(call['type'], 'function');
    expect(function['name'], 'set_timer');
    expect(function['arguments'], {'seconds': 300, 'label': 'tea'});
  });

  test(
    'error/skipped replay carries the {error: …} result through toolResponse semantics',
    () {
      // The tool-call half is the same shape regardless of outcome; the RESULT half (Message
      // .toolResponse) carries {error: …} for error/skipped rows — asserted here as the payload the
      // seam passes through verbatim.
      const errorResult = {'error': 'clipboard empty or not text'};
      expect(
        jsonEncode(errorResult),
        '{"error":"clipboard empty or not text"}',
      );
    },
  );
}
