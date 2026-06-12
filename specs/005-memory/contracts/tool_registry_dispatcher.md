# Contract — ToolRegistry / SchemaValidator / ToolDispatcher deltas (005)

Extends the 004 contract (`specs/004-function-calling/contracts/tool_registry_dispatcher.md`). All
three stay plugin-free. This feature ADDS two tools, one validator keyword, and two handlers — it does
NOT change the dispatcher's pipeline (validate → handler → typed `ToolOutcome`, never throws).

## ToolRegistry (`lib/core/tools/tool_registry.dart`) — now six tools, three views

```dart
abstract final class ToolRegistry {
  static const List<ToolSpec> deviceTools;   // 004: get_device_info, summarize_clipboard, set_theme, set_timer
  static const List<ToolSpec> memoryTools;   // 005: remember_fact, forget_fact
  static const List<ToolSpec> specs;         // deviceTools + memoryTools (byName scans this)
  static ToolSpec? byName(String name);
  static const String systemInstruction;     // 004 device tool-use instruction (now ONE input to SystemInstructionComposer)
}
```

Registry-sanity test updated: names unique across all six, every `parameters` self-validates against
the (extended) validator subset, descriptions non-empty, `kind` set. `remember_fact`/`forget_fact` are
`stateChanging`. The session provider composes the DECLARED list from `deviceTools`/`memoryTools` by
flag (R6); the registry itself stays pure data.

### New specs (R9)

| Tool | Args schema (subset) | Handler service |
|---|---|---|
| `remember_fact` | `{fact: string (required, maxLength 80), category: enum[identity,work,preferences,other] (required)}` | `MemoryRepository.upsert` (dedupe/supersede) |
| `forget_fact` | `{id: integer (required, minimum 1)}` | `MemoryRepository.softDeleteById` (id validated against active rows) |

Descriptions carry the model-facing guidance (capture durable facts as short third-person statements;
`forget_fact` ids come from the injected facts list) — see spike §3/§4.

## SchemaValidator (`lib/core/tools/schema_validator.dart`) — one keyword added

Add **`maxLength`** for `type: string` (reject strings longer than the bound — first-failure,
human-readable reason). Everything else (object/properties/required/enum/string/integer/number/
boolean/min/max + strict unknown-key rejection) is the 004 subset, unchanged. Unit-tested: over-length
fact → `Invalid('fact exceeds 80 characters')`; the new keyword is exercised by the registry-sanity
self-validation too.

## ToolDispatcher (`lib/domain/services/tool_dispatcher.dart`) — unchanged pipeline, two new handlers

The dispatcher is untouched (guarantee 1: validate before execute; guarantee 2: never throws —
handler exceptions → `ToolFailure`; integer-double coercion already covers `forget_fact.id`). New
handler bindings in `toolHandlersProvider`:

| Name | Handler | Outcome mapping |
|---|---|---|
| `remember_fact` | `upsert(fact, category, sourceConversationId)` | `ToolSuccess({remembered/updated: fact, category})` (created/superseded), `unchanged` → success with `{noted: fact}` |
| `forget_fact` | `softDeleteById(id)` | `true` → `ToolSuccess({forgot: id})`; `false` → throw → `ToolFailure('no such fact: <id>')` |

Guarantees (extend 004):

1. **Congruence (extended)**: when memory tools are declared, the handler map covers exactly the
   declared names (sanity test now spans ≤ 6). When `functionCalling`/memory is off, the memory tools
   are NOT declared and NOT in the handler map.
2. **Capture honors the toggle**: the `remember_fact` handler guards `memoryEnabled` (defense for the
   rare mid-session toggle-off window before `startSession` reapplies) → returns a `ToolFailure
   ('memory is off')` rather than a silent or dishonest success.
3. **No fuzzy delete (FR-010)**: `forget_fact` only ever soft-deletes an id that is currently active;
   a guessed/stale id (spike hazard) maps to `ToolFailure`, never a wrong deletion.
4. **`sourceConversationId`** is injected by the controller (the active conversation), not by the
   model — it is not a tool argument.

## Handler services (`lib/features/chat/tool_handler_providers.dart`)

`remember_fact`/`forget_fact` bind to `memoryRepositoryProvider`; `set_theme` already binds an
existing mechanism, so the memory handlers follow the same in-provider closure pattern. Each is
fakeable via `FakeMemoryRepository`. No new infrastructure plugin (the repo is drift, already behind a
seam) — `check_plugin_seam.sh` needs no new confinement rule.
