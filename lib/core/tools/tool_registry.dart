import 'package:ai_assistant/domain/entities/tool_spec.dart';

/// The const, static six-tool registry (005 memory + 004 device tools; contract:
/// tool_registry_dispatcher.md). Pure data — no plugin imports, no logic beyond [byName]. The seam
/// maps these to the plugin's `Tool` type when `capabilities.functionCalling` is on; the dispatcher
/// validates args against the schemas.
///
/// Invariants (proven by the registry-sanity test): names unique + `snake_case`, every
/// `parameters` map self-validates against the [SchemaValidator] subset, descriptions non-empty,
/// `kind` set on all six. Tools are split into three views:
///  * [deviceTools] — the original four device/UI tools (004).
///  * [memoryTools] — the two memory capture tools (005); declared only when memoryEnabled.
///  * [specs] — [deviceTools] + [memoryTools] — the full combined list (used by [byName]).
abstract final class ToolRegistry {
  /// The four device/UI tools from 004. Declared whenever `capabilities.functionCalling` is on.
  static const List<ToolSpec> deviceTools = <ToolSpec>[
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
            'description':
                'which group to emphasize; defaults to the full snapshot',
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
            'description':
                'timer duration in whole seconds (1 second to 24 hours)',
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

  /// The two memory tools (005). Declared when `capabilities.functionCalling` is on AND
  /// `memoryEnabled` is true (R6 — gated, never declared to a text-only model). The dispatcher
  /// calls the [MemoryRepository] handlers; the session provider composes the declared list as
  /// `deviceTools + memoryTools` when both flags are on.
  static const List<ToolSpec> memoryTools = <ToolSpec>[
    ToolSpec(
      name: 'remember_fact',
      description:
          'capture a durable fact about the user so it can be recalled in future conversations. '
          'call this when the user shares their name, where they live, their job, or a lasting '
          'preference about how you should respond (tone, units, formatting). write the fact as a '
          'short third-person statement, e.g. "prefers dark mode" or "lives in cairo, egypt". '
          'keep it under 80 characters. do not save one-off tasks, questions, weather, math, or '
          'trivia.',
      kind: ToolKind.stateChanging,
      parameters: <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'fact': <String, Object?>{
            'type': 'string',
            'maxLength': 80,
            'description':
                'the fact as a short third-person statement, e.g. "prefers dark mode" — max 80 chars',
          },
          'category': <String, Object?>{
            'type': 'string',
            'enum': <String>['identity', 'work', 'preferences', 'other'],
            'description': 'the semantic category of the fact',
          },
        },
        'required': <String>['fact', 'category'],
      },
    ),
    ToolSpec(
      name: 'forget_fact',
      description:
          'permanently remove a fact the user no longer wants remembered. the id must come from '
          'the known-facts list injected at the start of this conversation — do not guess an id '
          'that was not listed. if the user asks to forget something not in the list, explain that '
          'you can only delete facts you can see.',
      kind: ToolKind.stateChanging,
      parameters: <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'id': <String, Object?>{
            'type': 'integer',
            'minimum': 1,
            'description':
                'the numeric id of the fact to remove, from the injected facts list',
          },
        },
        'required': <String>['id'],
      },
    ),
  ];

  /// Full combined list: [deviceTools] + [memoryTools]. Used by [byName] for lookups across all
  /// declared tools. The session provider composes the subset that is actually declared to the
  /// model (gated by capability flags — R6).
  static const List<ToolSpec> specs = <ToolSpec>[
    ...deviceTools,
    ...memoryTools,
  ];

  /// Resolve a (possibly hallucinated) tool name to its spec, or null if unknown (the dispatcher
  /// maps null → `ToolUnknown`, FR-022). Scans [specs] — the full combined list.
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
