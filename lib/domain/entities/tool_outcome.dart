import 'package:meta/meta.dart';

/// Lifecycle of a persisted tool invocation (004 data-model §1, §4). `running` is transient — a
/// startup sweep finalizes any stale `running` row to `error('interrupted')` so reopened history
/// never shows an in-flight chip. `skipped` is reserved for exactly one case: stop requested
/// before dispatch (FR-026).
enum ToolCallStatus { running, success, error, skipped }

/// The typed result of [ToolDispatcher.dispatch] (004 data-model §1). `sealed` so the controller's
/// state machine handles every outcome exhaustively — the dispatcher NEVER throws (contract
/// guarantee 2), so this is the only surface the controller consumes.
@immutable
sealed class ToolOutcome {
  const ToolOutcome();
}

/// The handler ran and returned a result. [truncated] is set when the result JSON exceeded the
/// tool's `resultCharBound` and was clipped (R3).
@immutable
final class ToolSuccess extends ToolOutcome {
  const ToolSuccess(this.result, {this.truncated = false});

  final Map<String, Object?> result;
  final bool truncated;
}

/// The model named a tool that is not in the registry — a hallucinated tool (FR-022). The handler
/// map is never consulted.
@immutable
final class ToolUnknown extends ToolOutcome {
  const ToolUnknown(this.attemptedName);

  final String attemptedName;
}

/// The args failed schema validation; the handler never ran (FR-023). [reason] is the first
/// human-readable validation failure, surfaced on the chip.
@immutable
final class ToolInvalidArgs extends ToolOutcome {
  const ToolInvalidArgs(this.reason);

  final String reason;
}

/// The handler executed and failed (FR-025): empty clipboard, no clock app, etc. [reason] is the
/// structured, lowercase message the chip shows and the model is told about on resume.
@immutable
final class ToolFailure extends ToolOutcome {
  const ToolFailure(this.reason);

  final String reason;
}
