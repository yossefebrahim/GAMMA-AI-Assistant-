import 'package:ai_assistant/domain/entities/map_equality.dart';
import 'package:meta/meta.dart';

/// One event in a [GemmaService.generate] / `resumeWithToolResult` stream (004 R2).
///
/// The seam used to yield bare `String` tokens; function calling makes the tool call a first-class
/// semantic event the controller must persist and act on, so the stream now carries a sealed
/// [GenerationEvent]. With `functionCalling` off the stream degenerates to [TextDelta]s only and
/// the controller path is behaviorally identical to 003 (contract guarantee 19).
///
/// `sealed` so exhaustive `switch` handling is compiler-checked at every consumer.
@immutable
sealed class GenerationEvent {
  const GenerationEvent();
}

/// An incremental text token (the 001–003 streaming path, now wrapped). Emitted as the model
/// produces prose; the raw tool-call JSON leak is suppressed at the seam (guarantee 20) so a
/// [TextDelta] never carries it.
@immutable
final class TextDelta extends GenerationEvent {
  const TextDelta(this.token);

  final String token;

  @override
  bool operator ==(Object other) => other is TextDelta && other.token == token;

  @override
  int get hashCode => token.hashCode;
}

/// The model asked to call a tool. Always the FINAL event of its stream — the plugin yields the
/// `FunctionCallResponse` at end-of-stream on the gemma4 path (spike §1.3, guarantee 21).
///
/// [extraCallCount] > 0 records parallel calls the plugin surfaced alongside this one
/// (`ParallelFunctionCallResponse`): only the FIRST is executed; the remainder are noted on the
/// same chip and skipped (FR-006/FR-024 — one tool round trip per turn). The controller maps the
/// (name, args) to a dispatch and the single allowed `resumeWithToolResult`.
@immutable
final class ToolCallRequested extends GenerationEvent {
  const ToolCallRequested(this.name, this.args, {this.extraCallCount = 0});

  /// The model-facing tool name (may be a hallucinated name not in the registry — the dispatcher
  /// resolves that to `ToolUnknown`, never a crash).
  final String name;

  /// The model's arguments, as the plugin parsed them (escape-token-stripped, schema-shaped on the
  /// gemma4 path — spike: 10/10 valid). Validated against the registry schema before any handler.
  final Map<String, Object?> args;

  /// Discarded parallel calls (FR-024). Zero on the common single-call path.
  final int extraCallCount;

  @override
  bool operator ==(Object other) =>
      other is ToolCallRequested &&
      other.name == name &&
      other.extraCallCount == extraCallCount &&
      mapEquals(other.args, args);

  @override
  int get hashCode => Object.hash(name, extraCallCount, mapHash(args));
}
