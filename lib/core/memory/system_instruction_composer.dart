import 'package:ai_assistant/core/tools/tool_registry.dart';

/// Composes the final system instruction from up to three optional parts (R3):
///
///   1. **Facts block** — a pre-formatted id-prefixed block (already built by
///      `FactsBlockComposer`); omitted when null or empty.
///   2. **Memory capture instruction** — the R5 reliability lever; included only
///      when [memoryCapture] is true (i.e. `functionCalling && memoryEnabled`).
///   3. **Device tool-use instruction** — `ToolRegistry.systemInstruction`; included
///      only when [deviceTools] is true (i.e. `functionCalling`).
///
/// Parts are joined with blank lines (one empty line between consecutive parts).
/// Returns `null` when ALL parts are absent — guaranteeing byte-parity with the
/// pre-005 baseline (guarantee 29): a text-only model with memory empty/off sees
/// exactly `null`, the same as before this feature.
///
/// Pure and stateless — safe to call on any isolate.
abstract final class SystemInstructionComposer {
  /// The R5 capture instruction (wording per research.md R5, ~86 tokens).
  /// Lowercase, short, third-person-statement framing — the reliability lever that
  /// cleared SC-001 on the A34 by naming the instruction-shaped preference class
  /// the model otherwise silently obeyed without saving.
  static const String _captureInstruction =
      'you remember the user across chats. when the user shares a durable fact about '
      'themselves — their name, where they live, their job, or a lasting preference about '
      'how you should respond (tone, units, formatting) — call remember_fact with a short '
      'third-person statement and a category. don\'t save questions, one-off tasks, '
      'weather, math, or trivia.';

  /// Composes the system instruction from the three optional parts.
  ///
  /// - [factsBlock]: the pre-formatted facts block string (from `FactsBlockComposer`);
  ///   pass `null` or an empty string when there are no facts to inject.
  /// - [memoryCapture]: whether to include the memory capture instruction (true when
  ///   `functionCalling && memoryEnabled`).
  /// - [deviceTools]: whether to include the device tool-use instruction (true when
  ///   `functionCalling`).
  ///
  /// Returns `null` when every part is absent (byte-parity guarantee 29).
  static String? compose({
    String? factsBlock,
    required bool memoryCapture,
    required bool deviceTools,
  }) {
    final parts = <String>[];

    final trimmedFacts = factsBlock?.trim();
    if (trimmedFacts != null && trimmedFacts.isNotEmpty) {
      parts.add(trimmedFacts);
    }

    if (memoryCapture) {
      parts.add(_captureInstruction);
    }

    if (deviceTools) {
      parts.add(ToolRegistry.systemInstruction);
    }

    if (parts.isEmpty) return null;

    return parts.join('\n\n');
  }
}
