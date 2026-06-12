import 'dart:convert';

/// Reconstruct the raw SDK tool-call JSON the model expects as its OWN prior assistant turn when a
/// tool turn is replayed into context (004 data-model §3, contract guarantee 23). PURE — no plugin
/// import — so the exact shape is unit-testable against the spike's captured payload (spike §3),
/// the one seam input that unit tests can otherwise only verify on-device (quickstart V6).
///
/// The shape, captured verbatim from the device run:
/// `{"role":"assistant","tool_calls":[{"type":"function","function":{"name":<n>,"arguments":<a>}}]}`
String reconstructToolCallJson(String name, Map<String, Object?> args) =>
    jsonEncode({
      'role': 'assistant',
      'tool_calls': [
        {
          'type': 'function',
          'function': {'name': name, 'arguments': args},
        },
      ],
    });
