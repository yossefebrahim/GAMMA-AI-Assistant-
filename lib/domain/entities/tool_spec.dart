import 'package:meta/meta.dart';

/// Whether a tool only reads device/app state or changes it. Inert in v1 — all four tools
/// auto-execute (spec Q1) — but REQUIRED data so a future confirmation policy is a data change,
/// not a code change (FR-016).
enum ToolKind { readOnly, stateChanging }

/// One declarable local tool (004 data-model §1). Immutable, `const`-able — the registry is a
/// `const List<ToolSpec>`. Plugin-free: this is pure domain data the seam maps to the plugin's
/// `Tool` type, and the dispatcher validates against.
@immutable
class ToolSpec {
  const ToolSpec({
    required this.name,
    required this.description,
    required this.parameters,
    required this.kind,
    this.resultCharBound = defaultResultCharBound,
  });

  /// Default per-tool result-JSON cap (R3): keeps a tool turn well under the 1,536-token context
  /// budget. `summarize_clipboard` overrides this to [clipboardResultCharBound].
  static const int defaultResultCharBound = 2000;

  /// `summarize_clipboard`'s cap: 4,000 chars of clipboard text + ~400 for the JSON envelope
  /// (R3). Also the absolute ceiling the repository enforces (belt-and-braces).
  static const int clipboardResultCharBound = 4400;

  /// Unique in the registry; `snake_case`; the model-facing identifier. Persisted in DB rows and
  /// replayed to the model, so it is STABLE.
  final String name;

  /// The model's when-to-use guidance; non-empty. Carries user-visible constraints the model
  /// should explain (e.g. clipboard foregrounding, timer bounds) so it can describe its own tools.
  final String description;

  /// JSON-schema object for the args (the subset in research R3); `const`-able. Validated against
  /// the in-house [SchemaValidator] subset; the registry-sanity test proves every spec's schema is
  /// itself enforceable.
  final Map<String, Object?> parameters;

  /// Read-only vs state-changing (FR-016 — inert in v1).
  final ToolKind kind;

  /// Per-tool cap on the result JSON, in chars (R3). The dispatcher truncates oversize results.
  final int resultCharBound;
}
