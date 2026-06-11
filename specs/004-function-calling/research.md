# Research — 004 Function Calling (decisions & pinned versions)

All plugin-behavior claims below are grounded in the Phase 0 spike
([spike-findings.md](spike-findings.md)) — source-inspected on the installed
`flutter_gemma-0.15.3` and adversarially verified, then confirmed empirically on the A34.

## R1 — flutter_gemma 0.15.3 function-calling API (the seam's plugin mapping)

**Decision**: stay on `flutter_gemma ^0.15.0` (0.15.3 installed); use the native Gemma-4 SDK
tool path exactly as the spike verified it.

The seam maps:

| Seam concept | Plugin API | Notes |
|---|---|---|
| `ToolSpec` declaration | `Tool(name, description, parameters: <JSON-schema map>)` passed to `createChat(tools:)` | declarations fixed per chat; serialized natively into the LiteRT-LM conversation config (`tools_json`) |
| capability flag | `createChat(supportsFunctionCalls: capabilities.functionCalling, toolChoice: ToolChoice.auto)` | **structural coupling rule**: `tools` is non-empty iff the flag is true — the plugin's FFI path injects declarations on `tools.isNotEmpty` ALONE and the read side gates on the flag, so a mismatch is a silent no-op / raw-JSON spill (spike §1.3) |
| tool-use guidance | `createChat(systemInstruction: …)` | R6 — the reliability lever; rides the same conversation config |
| call event | final stream element `FunctionCallResponse{name, args}` (or `ParallelFunctionCallResponse{calls}`) from `generateChatResponseAsync()` | end-of-stream only on the gemma4 path — never mid-stream; args arrive escape-token-stripped and schema-shaped (spike: 10/10 valid) |
| tool result return | `chat.addQuery(Message.toolResponse(toolName:, response:))` then a fresh `generateChatResponseAsync()` | manual loop; no auto-resume; on Android/.litertlm the result reaches the model as a user-role `<tool_response>` text block |
| history replay | `Message.toolCall(text: <raw SDK JSON>)` + `Message.toolResponse(...)` in `clearHistory(replayHistory:)` | the plugin's own streamed history OMITS tool-call turns — the app DB is the source of truth; the seam reconstructs the raw JSON shape `{"role":"assistant","tool_calls":[{"type":"function","function":{"name":…,"arguments":…}}]}` — captured verbatim from the device run (spike §3 "Captured leak payload"). The `Message.toolCall(text:)` factory exists at message.dart:153-162 (spike §1.4). **Replay fidelity — whether the model treats the reconstruction as its own prior turn — is device-verified in quickstart V6** |

**Leak suppression**: `extractTextFromResponse` passes chunks without a `content` key through
verbatim, so on **every** call turn the raw SDK JSON streams through the text channel before the
typed event (spike: 10/10, payload captured verbatim in spike §3). Decision: an extracted pure
`LeakFilter` in the seam operating at **chunk granularity** (the leak is a chunk-level,
position-independent phenomenon — it can follow legitimate prose deltas in the same turn): while
tools are active, from the first chunk whose trimmed text starts with `{`, all subsequent text is
withheld; prose emitted before that chunk flows normally. If the turn ends in a
`ToolCallRequested`, withheld text is discarded; if the turn ends without a call, it is flushed
verbatim (fidelity-preserving). Unit-tested with the spike's captured shapes, including the
prose-then-leak-then-call case.

**Alternatives considered**: regex-scrubbing rendered text in the UI (cosmetic, violates FR-004's
"structural" requirement); upgrading to 0.16.4 for a cleaner SDK path (rejected — known model-load
regression on the A34, 003 R1, and the spike's findings are 0.15.3-specific).

## R2 — Seam event model: sealed `GenerationEvent` over `Stream<String>`

**Decision**: change `GemmaService.generate` to `Stream<GenerationEvent>` —
`TextDelta(String token)` | `ToolCallRequested(String name, Map<String, Object?> args)` — and add
`resumeWithToolResult({required String toolName, required Map<String, Object?> result})`
returning the same event stream for the turn's completion. With `functionCalling` off, the
stream is `TextDelta`-only and the controller path is behaviorally identical to today.

**Rationale**: the tool call is a first-class semantic event the controller must persist and act
on; encoding it in-band (sentinel strings) or out-of-band (callbacks) hides control flow and
breaks the one-direction streaming model the app already has. A sealed type makes the
exhaustive-handling compiler-checked. `ParallelFunctionCallResponse` maps to the FIRST call as
`ToolCallRequested` + the remainder reported in the same event (`extraCallCount`) so FR-006/FR-024
can chip-and-skip without a second seam concept.

**Alternatives considered**: a separate `generateWithTools` method (duplicates the streaming
path, two code paths to keep stop-safe); keeping `Stream<String>` + a `Future<ToolCall?>` side
channel (ordering between channels is unspecifiable); seam-internal auto-execution of tools
(violates the layering — persistence and policy belong to the controller; the seam stays a
plugin adapter).

## R3 — Strict argument validation: in-house JSON-schema-subset validator

**Decision**: a pure `SchemaValidator` in `lib/core/tools/` (~100 lines) covering exactly the
subset the four tools use: `type: object`, `properties`, `required`, `enum`, `type: string |
integer | number | boolean`, integer `minimum`/`maximum`, plus **unknown-key rejection** (strict
mode — the dispatcher's contract). Validation failures produce `ToolOutcome.invalidArgs(reason)`
before any handler runs (FR-023).

**Rationale**: pub's JSON-schema packages are heavyweight general validators (drafts, remote
refs, formats) for what is here four small static schemas; Principle IX says don't ship a
dependency to validate ~6 fields. Strict unknown-key rejection exceeds standard JSON-schema
defaults deliberately — a hallucinated argument is a model error the chip should surface, not
silently drop.

**Bounds as data constants** (the app owns them; the plugin enforces nothing). The result bound
is **per-tool, declared on `ToolSpec`** (`resultCharBound`): default **2,000 chars** of result
JSON; `summarize_clipboard` **4,400 chars** (its clipboard text is capped at **4,000 chars** at
the tool layer, leaving ~400 for the JSON envelope — so the 4,000-char input cap is actually
reachable). Oversize results truncate with a `truncated: true` marker. Worst-case token cost of
a tool turn ≈ 1,100 tokens (4,400 chars at the 4-chars/token heuristic) of the 1,536 budget —
the assembler's oldest-first dropping absorbs it, and only the clipboard tool can reach it.
`set_timer` duration bounds **1 s – 24 h** (1..86400 s).

## R4 — Per-tool implementation choices

| Tool | Mechanism | New dependency | Notes |
|---|---|---|---|
| `get_device_info` | `device_info_plus` (pinned ^13.1.0, already a dep) for model/OS/RAM; **`battery_plus ^7.0.0`** for battery level; **~10-line StatFs `MethodChannel`** in MainActivity for free storage | battery_plus | superset result (spike trial 10 lesson): always return the full map; the optional `section` arg only orders/labels. Read-only, zero runtime permissions |
| `summarize_clipboard` | Flutter built-in `Clipboard.getData('text/plain')` | none | foreground-only on Android 10+ (executes during an active turn — the app necessarily holds focus); empty/non-text → `ToolOutcome.failure('clipboard empty or not text')`; 4,000-char bound (R3); the OS's Android-12+ clipboard-read toast is expected behavior, documented in the tool description |
| `set_theme` | the existing persisted theme mechanism (settings controller) | none | auto-execute (spec Q1); same-theme request → idempotent success result (`alreadyActive: true`) |
| `set_timer` | **`android_intent_plus ^6.0.0`**: `AlarmClock.ACTION_SET_TIMER` + `EXTRA_LENGTH` (seconds) + `EXTRA_MESSAGE` + `EXTRA_SKIP_UI: true` | android_intent_plus | spec Q2: silent hand-off — user stays in conversation; timer survives app death, rings on lock screen. Manifest: `com.android.alarm.permission.SET_ALARM` (normal permission) **+ a `<queries>` entry for the intent** (Android 11+ package-visibility — without it the resolve fails). `ActivityNotFoundException` → structured error (FR-015). Duration bounds validated pre-intent (R3) |

**Free-storage alternative considered**: `disk_space_plus 0.2.6` — rejected: a 0.x single-purpose
package of unknown maintenance for one synchronous `StatFs` call; the in-repo channel is ~10
lines of Kotlin in an Android-only app (Principle IX, and the seam guard can't audit a third-party
package's insides anyway). Battery alternative considered: a sysfs read (fragile across OEMs) —
`battery_plus` is the maintained Plus-family standard.

## R5 — Capability flag and gating flow

**Decision**: `ModelCatalog.supportsFunctionCalling = true` (spike-verified for Gemma 4 E2B on
0.15.3) composed into the existing `ModelCapabilities(functionCalling:)` slot (already present,
never set until now) and threaded through the established 002/003 path: catalog →
`loadModel(capabilities:)` → seam → `modelCapabilitiesProvider`.

Seam-side `StateError` gates (the 002/003 pattern, spike §1.3 hazard):
1. `loadModel(tools: nonEmpty)` while `capabilities.functionCalling == false` → synchronous
   `StateError` (programmer error — the silent-trap combination must be unrepresentable).
2. `resumeWithToolResult` outside an in-flight tool turn → `StateError`.
3. The structural coupling: `FlutterGemmaService` derives `supportsFunctionCalls`, `tools`, and
   `systemInstruction` from ONE source (`capabilities.functionCalling` + the registry passed at
   load) — there is no code path that sets one without the others.

**Flag-off parity**: with `functionCalling: false` the seam passes `tools: const []`,
`supportsFunctionCalls: false`, no tool system instruction — byte-identical plugin inputs to
today; the event stream degenerates to `TextDelta`s. SC-007's regression pass + a dedicated
parity unit test pin this.

## R6 — Tool-use system instruction (the reliability lever)

**Decision**: when (and only when) tools are active, pass a short system instruction at chat
creation: lowercase, ~40 tokens, naming the device-assistant context and the four tools' domains
("you run on the user's phone. use a tool when the user asks about this device, the clipboard,
timers, or the app's theme; otherwise just answer."). Exact wording tuned during implementation
against the quickstart suite.

**Rationale**: the spike's 83.3% correct-call rate is the **no-instruction floor**; both misses
were the model failing to connect "this phone" to the tool (it asked for an image instead). A
context-setting instruction is the cheapest, fully-local lever to clear SC-001's 80% bar with
margin. Cost: ~40 tokens of the 1,536 budget, accounted in the context assembler.

**Alternatives considered**: per-prompt instruction injection (re-prefixing every turn — token
waste, and the plugin already supports a per-conversation system instruction natively);
`ToolChoice.required` (wrong — forces calls on prompts that need none; the spike shows `auto`
yields zero spurious calls).

## R7 — Persistence: tool columns + drift v3 → v4

**Decision**: one message row per tool invocation — `role='tool'` with four new nullable columns
(`toolName`, `toolArgs` JSON, `toolStatus`, `toolResult` JSON) — additive `m.addColumn`
migration, house style (001→2 images, 2→3 audio, now 3→4 tools). One row carries call AND result:
the chip renders from one row, and replay expands it into the plugin's two messages
(`Message.toolCall` + `Message.toolResponse`). Status lifecycle `running → success | error |
skipped` with a startup stale-row sweep (`running` → `error('interrupted')`) mirroring the
streaming-message finalization pattern. Details in [data-model.md](data-model.md).

**Alternatives considered**: two rows (call + result) — doubles the rendering/replay bookkeeping
and lets the pair split across deletes; a separate `tool_invocations` table — a join for every
history read and a second cascade path, for data that is structurally a message; storing results
as files — results are ≤2,000 chars by contract, nowhere near file territory.

## R8 — Test & verification strategy

- **Unit (plugin-free)**: `SchemaValidator` (valid / wrong type / unknown key / enum violation /
  missing required / bounds); `ToolDispatcher` (success, unknownTool, invalidArgs, handler
  failure, per-tool result-bound truncation); `LeakFilter` (spike-captured raw shapes: pure-JSON
  turn, JSON-then-call, **prose-then-leak-then-call**, prose-only turn flushes, prefix
  false-positive `{` prose, chunk-split JSON); `ToolRegistry`
  sanity (names unique, schemas validate themselves, descriptions non-empty); context-assembler
  replay (tool turns included, token accounting, oldest-drop).
- **Seam-contract tests**: extended `FakeGemmaService` models the gates (StateError on ungated
  tools, resume-outside-turn) so controller tests exercise them; `FlutterGemmaService` mapping
  logic (ToolSpec→Tool, event mapping, structural coupling) factored to be testable without the
  plugin where possible.
- **Controller loop**: widget/unit tests over the full matrix — call→dispatch→resume happy path;
  unknown tool; invalid args; handler failure; second-call error chip; stop before dispatch; stop
  before resume; bubble-ordering rule (user → chip → answer); flag-off parity stream.
- **Migration**: seeded **v3 file DB** (with index, house pattern) → open at v4 → old rows
  intact, new columns NULL, tool insert round-trips.
- **Widget**: `ToolChip` all four states (running/success/error/skipped) + semantics labels +
  AA-token usage; chat flow rendering role=tool rows; gating regression (no chip surfaces, no
  affordance changes with flag off).
- **Device (quickstart, `flutter run`/`flutter drive` ONLY)**: V1–V11 covering all four tools,
  hallucinated-tool probe, invalid-args probe, restart persistence + replay fidelity, airplane
  mode, responsiveness, accessibility scanner, and the capability-off scratch-build regression
  (V11: prose only, zero declarations, history chips still render).

## Pinned versions (this feature's additions)

| Package | Version | Why pinned |
|---|---|---|
| `battery_plus` | `^7.0.0` | battery level for get_device_info; flutter-community Plus family (same as device_info_plus already in the stack) |
| `android_intent_plus` | `^6.0.0` | ACTION_SET_TIMER skip-UI hand-off (spec Q2); Plus family |
| `flutter_gemma` | `^0.15.0` (0.15.3 installed) | UNCHANGED — spike findings are 0.15.3-specific; 0.16.4 regresses model load on the A34 |
| (none) | — | clipboard = Flutter built-in; schema validation = in-house (R3); free storage = in-repo MethodChannel (R4) |
