import 'package:ai_assistant/domain/entities/tool_spec.dart';

/// The const, static four-tool registry (004 contract: tool_registry_dispatcher.md). Pure data —
/// no plugin imports, no logic beyond [byName]. The seam maps these to the plugin's `Tool` type
/// when `capabilities.functionCalling` is on; the dispatcher validates args against the schemas.
///
/// Invariants (proven by the registry-sanity test): names unique + `snake_case`, every
/// `parameters` map self-validates against the [SchemaValidator] subset, descriptions non-empty,
/// `kind` set on all four.
abstract final class ToolRegistry {
  /// Exactly four entries in v1 (Lean Scope, Principle IX). Order is the model-facing declaration
  /// order.
  static const List<ToolSpec> specs = <ToolSpec>[
    ToolSpec(
      name: 'get_device_info',
      description:
          'report facts about the phone this assistant runs on: model and android version, '
          'total/free ram, battery level and charging state, and free/total storage. use when '
          'the user asks about this device. the optional "section" only orders the answer; the '
          'full device snapshot is always available.',
      kind: ToolKind.readOnly,
      parameters: <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'section': <String, Object?>{
            'type': 'string',
            'enum': <String>['hardware', 'memory', 'battery', 'storage', 'all'],
            'description': 'which group to emphasize; defaults to the full snapshot',
          },
        },
        'required': <String>[],
      },
    ),
    ToolSpec(
      name: 'summarize_clipboard',
      description:
          'read the text currently on the clipboard so you can summarize or answer about it. '
          'takes no arguments. android may briefly toast that this app read the clipboard — that '
          'is expected. fails honestly if the clipboard is empty or not text.',
      kind: ToolKind.readOnly,
      resultCharBound: ToolSpec.clipboardResultCharBound,
      parameters: <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{},
        'required': <String>[],
      },
    ),
    ToolSpec(
      name: 'set_theme',
      description:
          "switch the app's appearance between dark and light. use when the user asks to change "
          'the theme. if the requested theme is already active, that is reported as a success.',
      kind: ToolKind.stateChanging,
      parameters: <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'theme': <String, Object?>{
            'type': 'string',
            'enum': <String>['dark', 'light'],
            'description': 'the theme to switch to',
          },
        },
        'required': <String>['theme'],
      },
    ),
    ToolSpec(
      name: 'set_timer',
      description:
          "start a countdown timer in the phone's clock app. use when the user asks to set a "
          'timer. translate any natural duration (e.g. "five minutes", "a quarter of an hour") '
          'into whole seconds, between 1 second and 24 hours. the timer runs in the system clock; '
          'the user stays in this conversation.',
      kind: ToolKind.stateChanging,
      parameters: <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'seconds': <String, Object?>{
            'type': 'integer',
            'minimum': 1,
            'maximum': 86400,
            'description': 'timer duration in whole seconds (1 second to 24 hours)',
          },
          'label': <String, Object?>{
            'type': 'string',
            'description': 'optional label shown on the timer',
          },
        },
        'required': <String>['seconds'],
      },
    ),
  ];

  /// Resolve a (possibly hallucinated) tool name to its spec, or null if unknown (the dispatcher
  /// maps null → `ToolUnknown`, FR-022).
  static ToolSpec? byName(String name) {
    for (final spec in specs) {
      if (spec.name == name) return spec;
    }
    return null;
  }

  /// The R6 tool-use system instruction (004): a short, lowercase context-setting line passed to
  /// the chat ONLY when `capabilities.functionCalling` is on — the reliability lever over the
  /// spike's 83.3% no-instruction floor. ~40 tokens, accounted in the context assembler. Exact
  /// wording tuned on-device (quickstart V6, task T049).
  static const String systemInstruction =
      'you run on the user\'s phone. use a tool when the user asks about this device, the '
      'clipboard, timers, or the app\'s theme; otherwise just answer.';
}
