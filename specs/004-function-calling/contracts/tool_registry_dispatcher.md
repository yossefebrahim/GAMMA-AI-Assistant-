# Contract — ToolRegistry, SchemaValidator, ToolDispatcher (004)

All three are plugin-free (Principle VII): registry and validator in `lib/core/tools/`,
dispatcher in `lib/domain/services/`. Handlers live behind infrastructure services.

## ToolRegistry (`lib/core/tools/tool_registry.dart` — const data)

```dart
abstract final class ToolRegistry {
  static const List<ToolSpec> specs; // exactly 4 entries in v1
  static ToolSpec? byName(String name);
}
```

Guarantees (unit-tested as registry sanity):
1. Names unique, `snake_case`, stable (they are persisted in DB rows and replayed to the model).
2. Every `parameters` map is valid against the validator's own subset (the registry can never
   ship a schema the validator can't enforce).
3. Descriptions non-empty and carry user-visible constraints (clipboard foregrounding, timer
   bounds) so the model can explain its own tools honestly.
4. `kind` set on every spec (`readOnly`: get_device_info, summarize_clipboard;
   `stateChanging`: set_theme, set_timer) — inert in v1 (all auto-execute, spec Q1) but required
   data (FR-016).

### v1 specs (summary — exact schemas live in the registry source)

| Tool | Args schema (subset) | Handler service |
|---|---|---|
| `get_device_info` | `{section?: enum[hardware,memory,battery,storage,all]}` | `DeviceInfoToolService` |
| `summarize_clipboard` | `{}` (no args) | `ClipboardToolService` (read + bound); summarization happens in the resumed generation |
| `set_theme` | `{theme: enum[dark,light]}` (required) | existing theme/settings mechanism |
| `set_timer` | `{seconds: integer 1..86400, label?: string}` (seconds required) | `TimerIntentService` |

## SchemaValidator (`lib/core/tools/schema_validator.dart` — pure)

```dart
ValidationResult validate(Map<String, Object?> schema, Map<String, Object?> args);
// ValidationResult: valid | invalid(String reason — first failure, human-readable)
```

Supported subset (research R3): `type: object` root; `properties`; `required`; `enum`;
primitive types `string | integer | number | boolean`; integer `minimum`/`maximum`.
**Strict mode**: unknown keys are rejected (a hallucinated argument surfaces in the chip, never
silently dropped). Anything outside the subset in a schema is a registry-sanity test failure,
not a runtime surprise.

## ToolDispatcher (`lib/domain/services/tool_dispatcher.dart`)

```dart
class ToolDispatcher {
  ToolDispatcher({required Map<String, ToolHandler> handlers}); // injected, fakeable
  Future<ToolOutcome> dispatch(String name, Map<String, Object?> args);
}
typedef ToolHandler = Future<Map<String, Object?>> Function(Map<String, Object?> validArgs);
```

Guarantees:
1. **Validation precedes execution, always**: `name ∉ registry` → `ToolUnknown` (handler map
   never consulted); schema failure → `ToolInvalidArgs(reason)` (handler never invoked).
2. **Typed outcomes only**: handler exceptions are caught and mapped to `ToolFailure(reason)` —
   `dispatch` NEVER throws (the controller's state machine consumes outcomes, not exceptions).
3. **Result bound (per-tool)**: success payloads exceeding the spec's `resultCharBound`
   (default 2,000 chars of JSON; `summarize_clipboard` 4,400 — R3) are truncated with
   `truncated: true` before they reach the seam or the DB. Absolute ceiling 4,400.
4. **No policy**: the dispatcher executes valid calls unconditionally — confirmation policy
   (none in v1, spec Q1) and the one-call-per-turn rule are controller concerns; capability
   gating is a seam concern. The dispatcher stays a pure mapping.
5. **Registry/handler congruence** (sanity test): the injected handler map covers exactly the
   registry's names.

## Handler services (`lib/infrastructure/tools/` — the new plugin confinement zone)

| Service | Wraps | Failure → `ToolFailure` reason |
|---|---|---|
| `DeviceInfoToolService` | `device_info_plus` + `battery_plus` + StatFs `MethodChannel` (R4) | individual probe failures degrade per-field (`unknown`), service never throws |
| `ClipboardToolService` | Flutter `Clipboard.getData` | `clipboard empty or not text`; clipboard text capped at 4,000 chars with `truncated: true` (fits the tool's 4,400 `resultCharBound`) |
| `TimerIntentService` | `android_intent_plus` ACTION_SET_TIMER + EXTRA_SKIP_UI (R4) | `no clock app available` (ActivityNotFoundException); bounds enforced by schema before the handler |
| theme handler | existing persisted theme controller | none expected; same-theme → success with `alreadyActive: true` |

Each service has a fake; `tool/check_plugin_seam.sh` gains `battery_plus` and
`android_intent_plus` confinement rules (imports allowed ONLY under `lib/infrastructure/`).
