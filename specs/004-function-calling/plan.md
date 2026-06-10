# Implementation Plan: Function Calling — Local Device Tools

**Branch**: `004-function-calling` | **Date**: 2026-06-10 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `/specs/004-function-calling/spec.md` (clarified 2026-06-10)
and the Phase 0 spike ([spike-findings.md](spike-findings.md), GATE PASSED).

## Summary

Give the assistant a four-tool local registry — `get_device_info`, `summarize_clipboard`
(read-only), `set_theme`, `set_timer` (state-changing) — invoked by natural language, with every
call rendered as an inline monochrome tool chip (design-system §8), auto-executed (spec Q1),
persisted in conversation history (drift v3→v4) and replayed into model context, degrading to
visible error chips on any bad call. Tool capability flows as data
(`ModelCatalog.supportsFunctionCalling` → `ModelCapabilities.functionCalling`); with the flag off
the app is byte-for-byte today's behavior.

Technical approach — extend the existing 001/002/003 architecture rather than reshape it:

- **Seam (Principle VII).** `GemmaService.generate` changes from `Stream<String>` to a stream of
  sealed **`GenerationEvent`s** (`TextDelta` | `ToolCallRequested(name, args)`), and the seam
  gains `resumeWithToolResult(...)` to complete the one-allowed round trip. `FlutterGemmaService`
  threads `tools:` + `supportsFunctionCalls: capabilities.functionCalling` + a short tool-use
  `systemInstruction` into `createChat` (the spike's silent-trap rule: tools and the flag are
  **structurally coupled** — never one without the other), maps `ToolSpec` → plugin `Tool`,
  surfaces the end-of-stream `FunctionCallResponse` as `ToolCallRequested`, and **suppresses the
  raw-JSON leak** (100% of calls, spike §3) with an extracted, unit-testable `LeakFilter`.
  Seam-side `StateError` gates mirror 002/003: tools requested while `!capabilities.functionCalling`
  is a programmer error, thrown synchronously.
- **Registry + dispatcher (plugin-free domain).** `ToolRegistry` is const data: four `ToolSpec`s
  (name, description, JSON-schema args map, read-only/state-changing class). `ToolDispatcher`
  validates args **strictly against the schema before execution** (in-house ~100-line validator —
  no new dependency) and maps to injected handlers, returning a typed `ToolOutcome`
  (success / unknownTool / invalidArgs / failure). Hallucinated names and malformed args
  short-circuit to error outcomes without touching a handler.
- **Handlers (infrastructure).** `get_device_info`: `device_info_plus` (already pinned) +
  `battery_plus ^7.0.0` + a ~10-line StatFs `MethodChannel` for free storage (research R4).
  `set_timer`: `android_intent_plus ^6.0.0` firing ACTION_SET_TIMER with skip-UI (spec Q2);
  missing clock app → structured error. `summarize_clipboard`: Flutter's built-in clipboard API,
  4,000-char bound with truncation recorded (R4). `set_theme`: the existing persisted theme
  mechanism; idempotent success. New plugins confined to `lib/infrastructure/tools/`;
  `tool/check_plugin_seam.sh` extended to cover them.
- **Controller loop.** `ChatController.send` consumes events: on `ToolCallRequested` it persists
  the invocation row, dispatches, finalizes the row (success/error/skipped), then
  `resumeWithToolResult` streams the final reply. One round trip per turn (FR-006): a second call
  event is skipped with an error chip. The bubble-ordering rule: an empty streaming assistant row
  is replaced after the chip so history reads user → chip → answer (data-model §4).
- **Persistence.** `messages` gains `role='tool'` plus nullable `toolName` / `toolArgs` /
  `toolStatus` / `toolResult` columns via **drift schemaVersion 3 → 4** (additive, house style);
  context assembly replays tool turns as plugin `Message.toolCall` + `Message.toolResponse` (the
  app DB is the source of truth — the plugin's own history omits streamed tool calls, spike §1.3).
- **UI.** `ToolChip` per design-system §8: mono uppercase `TOOL · SET_THEME` tag, quiet result
  line, monochrome; dot-pulse while running; error state is the sanctioned red use. Chips are
  non-interactive in v1 and render from history regardless of the active model's capabilities.

Decisions and pinned versions in [research.md](research.md) (R1–R8); entities, migration, and the
tool-turn state machine in [data-model.md](data-model.md); seam contracts and fakes in
[contracts/](contracts/); the on-device validation script in [quickstart.md](quickstart.md).

## Technical Context

**Language/Version**: Dart 3.12.x on Flutter stable — unchanged from 001–003.

**Primary Dependencies** (added by this feature, on top of the existing stack):
- `battery_plus ^7.0.0` — battery level for `get_device_info`, behind `DeviceInfoToolService`
  (research R4; flutter-community Plus package, same family as the pinned `device_info_plus`).
- `android_intent_plus ^6.0.0` — ACTION_SET_TIMER hand-off for `set_timer` (spec Q2), behind
  `TimerIntentService` (R4). Manifest gains `com.android.alarm.permission.SET_ALARM` (a normal,
  auto-granted permission).
- `flutter_gemma ^0.15.0` (already pinned, 0.15.3 installed) — function-calling API now
  exercised: `createChat(tools:, supportsFunctionCalls:, toolChoice:, systemInstruction:)`,
  `FunctionCallResponse`/`ParallelFunctionCallResponse`, `Message.toolResponse`/`toolCall`.
  Confinement unchanged. **No version bump** (R1; 0.16.4 remains a load regression on the A34).
- NO new dependency for: clipboard (Flutter built-in), schema validation (in-house validator,
  R3), free-storage stat (minimal MethodChannel in MainActivity, R4 — rejected the unmaintained
  0.x `disk_space_plus`).

**Storage**: unchanged backbone — drift over app-private SQLite. Schema bumps to **v4**:
`messages.toolName TEXT?`, `messages.toolArgs TEXT?` (JSON), `messages.toolStatus TEXT?`,
`messages.toolResult TEXT?` (JSON, bounded); `role` gains the `'tool'` value (domain-enforced,
additive only — v3 rows untouched). No new files on disk; tool results are small structured text.

**Testing**: `flutter_test` unit + widget against fakes (extended `FakeGemmaService` emitting
`GenerationEvent`s and modeling the ungated-tools `StateError`; `FakeToolHandlers` for dispatcher
and controller tests); `LeakFilter` unit-tested as a pure class; in-memory drift for repository
tests; a real seeded **v3 file DB** for the v3→v4 migration test (house pattern from 002/003);
schema-validator property-style unit tests (valid / wrong-type / unknown-key / enum-violation /
missing-required). No device, plugin, or network in tests (Principle VII). Device verification via
[quickstart.md](quickstart.md) — **`flutter run`/`flutter drive` only; `flutter test
integration_test/...` is forbidden on this project** (uninstalls the app, wipes model + DB).

**Target Platform**: Android, arm64-v8a, API 29+ baseline (unchanged). Manifest adds exactly
`com.android.alarm.permission.SET_ALARM`. No runtime-permission prompts: all four tools run on
normal permissions (clipboard is foreground-access, not permission-gated).

**Performance Goals**: tool call parsed ≤ ~3 s from send (spike: 1.8–2.7 s); full round trip —
send → chip → grounded final answer — under 20 s on the A34 (SC-005; spike worst case 15.4 s
resume + 2.7 s call); chip state transitions render within one frame of the controller state
change; streaming/stop responsiveness unchanged (existing SC floors).

**Constraints**: on-device only — tool execution, results, and clipboard content never leave the
device; no new network call (Principle I; `check_network_seam.sh` stays green); fully offline
(II; quickstart verifies all four tools in airplane mode); tools declared to the model ONLY when
`capabilities.functionCalling` (III) with the seam coupling tools+flag structurally (the spike's
silent-trap, R1); raw-JSON leak suppressed at the seam — never rendered (FR-004, spike §3);
ONE tool round trip per user turn (FR-006); tool results bounded per-tool (default 2,000 chars
of result JSON; clipboard 4,400 carrying its 4,000-char text cap — R3) so a tool turn can't blow
the 1536-token context budget; exactly one model
active, no new sessions or models (VIII); monochrome chip with red reserved for error states
(VI, X); 48dp/AA floors apply to any interactive surface (the v1 chip is non-interactive).

**Scale/Scope**: single local user; four tools, registry-static; one seam signature change
(`generate` events + `resumeWithToolResult`), one dispatcher + validator, three small
infrastructure services + one ~10-line platform-channel method, one additive migration, one new
widget (`ToolChip`), controller loop extension, context-assembler extension. No new layers.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

Constitution version **1.2.0**. Status legend: ✅ satisfied by design · ⚠ implementation caution
(carried into research/tasks, not a deviation).

| # | Principle | Gate — how this plan satisfies it | Status |
|---|-----------|-----------------------------------|--------|
| I | Privacy Is the Product | All four tools are local: device stats, app theme, a system-clock intent (an OS hand-off, not an egress), and a foreground clipboard read whose content is processed on-device and stored only in the local conversation DB. No new network call; `check_network_seam.sh` still covers the codebase. | ✅ |
| II | Offline-First | Every tool executes with zero connectivity; quickstart V8 verifies all four plus a round trip under airplane mode. | ✅ |
| III | Capability-Driven UX | Tool declaration to the model is driven by `ModelCapabilities.functionCalling` (catalog→seam→provider data, never a per-model `if`); flag-off is byte-for-byte today's behavior (SC-007 regression pass); persisted chips render regardless of current capability (the 002/003 history-outlives-capability rule). | ✅ (realizes III for tools) |
| IV | Responsive & Cancellable | Streaming + stop reuse the existing path; handlers are fast local calls run off the hot path; the round trip stays inside the streamed turn with stop honored before dispatch and before resume (FR-026); leak suppression is O(token) buffering, no per-token regression. | ⚠ verify gesture responsiveness during a tool turn on device — quickstart V9 |
| V | Graceful Degradation | Unknown tool, invalid args, handler failure, missing clock app, empty/non-text clipboard, stop-mid-turn, and the second-call error all have typed outcomes that terminate in a visible chip state + honest model-informed text (FR-022..026); nothing can crash the turn. | ⚠ implement the full outcome matrix; contracts pin it |
| VI | Dark-First & Accessible | Chip text uses AA-passing tokens (`textSecondary` floor — chips are essential content); the v1 chip is non-interactive so no new touch-target surface; error states use the sanctioned red. | ⚠ device Accessibility Scanner pass over chip states — quickstart V10 |
| VII | Testable Through a Plugin Seam | flutter_gemma stays in `infrastructure/gemma/`; `battery_plus`/`android_intent_plus` confined to `infrastructure/tools/` behind services with fakes; the registry, dispatcher, validator, controller loop, and chip all test plugin-free; seam-guard script extended. | ✅ |
| VIII | Resource Hygiene | No new sessions/models/files; tool turns ride the existing chat session; result strings bounded; the StatFs channel is a synchronous read; intent fires and releases. | ✅ |
| IX | Lean Scope | Exactly the spec slice: four static tools, one round trip per turn, no confirmation flows (spec Q1), no in-app timer infrastructure (spec Q2), no switch_backend (spec Q3), no user-defined tools. The in-house validator covers only the schema subset the four tools use. | ✅ |
| X | Design Identity | The chip is the design system's own §8 treatment (mono uppercase tag, quiet system line, no colored banner); red only on error states; dot-pulse for running; lowercase microcopy; tokens centralized. | ✅ |
| — | Technology & Platform Constraints | Stack unchanged. The constitution's model table already declares Gemma 4 E2B function-calling capable — the spike converted that claim to verified fact (83.3% correct-call, clean failure profile). New plugins are additive local-capability accessors, not a stack deviation. | ✅ |

**Gate result**: PASS. No principle is violated; three ⚠ items are device-verification cautions
carried into quickstart/tasks. **Complexity Tracking is therefore empty.**

## Project Structure

### Documentation (this feature)

```text
specs/004-function-calling/
├── spike-findings.md    # Phase 0 spike (committed; gate PASSED)
├── plan.md              # This file
├── research.md          # Phase 0 output (R1–R8, pinned decisions)
├── data-model.md        # Phase 1 output (entities, v3→v4 migration, state machine)
├── quickstart.md        # Phase 1 output (device validation script V1–V11)
├── contracts/           # Phase 1 output (seam + registry + repo contracts)
│   ├── gemma_service.md
│   ├── tool_registry_dispatcher.md
│   └── conversation_repository.md
├── checklists/requirements.md
└── tasks.md             # Phase 2 output (/speckit-tasks — NOT created by /speckit-plan)
```

### Source Code (repository root) — changes layered on the existing tree

```text
lib/
├── core/
│   ├── model_catalog.dart                  # + supportsFunctionCalling → capabilities
│   └── tools/
│       ├── tool_registry.dart              # NEW — const four-ToolSpec registry (data only) +
│       │                                   #   the ~40-token tool-use system instruction const (R6)
│       └── schema_validator.dart           # NEW — in-house JSON-schema-subset validator (pure)
├── domain/
│   ├── entities/
│   │   ├── generation_event.dart           # NEW — sealed TextDelta | ToolCallRequested
│   │   ├── tool_spec.dart                  # NEW — name/description/schema/kind
│   │   ├── tool_outcome.dart               # NEW — success | unknownTool | invalidArgs | failure
│   │   ├── message.dart                    # + MessageRole.tool, tool fields
│   │   └── model_capabilities.dart         # (exists — functionCalling flag already present)
│   ├── repositories/
│   │   └── conversation_repository.dart    # CHANGED — appendToolInvocation/finalizeToolInvocation
│   └── services/
│       ├── gemma_service.dart              # CHANGED — Stream<GenerationEvent>, resumeWithToolResult,
│       │                                   #   tools param + StateError gates (contract)
│       └── tool_dispatcher.dart            # NEW — validate → handler → ToolOutcome (plugin-free)
├── infrastructure/
│   ├── gemma/flutter_gemma_service.dart    # CHANGED — tools/flag/systemInstruction threading,
│   │                                       #   event mapping, LeakFilter, resume loop, tool-turn
│   │                                       #   REPLAY reconstruction (data-model §3)
│   ├── gemma/leak_filter.dart              # NEW — pure, unit-testable raw-JSON suppression
│   └── tools/
│       ├── device_info_tool_service.dart   # NEW — device_info_plus + battery_plus + StatFs channel
│       ├── timer_intent_service.dart       # NEW — android_intent_plus ACTION_SET_TIMER (skip-UI)
│       └── clipboard_tool_service.dart     # NEW — Flutter Clipboard.getData, bounds + truncation
├── data/
│   ├── db/app_database.dart                # CHANGED — schemaVersion 4, v3→v4 migration
│   ├── db/tables.dart                      # CHANGED — tool columns on messages
│   └── repositories/drift_conversation_repository.dart  # CHANGED — tool rows (replay
│                                           #   reconstruction itself lives in the seam)
├── features/chat/
│   ├── chat_controller.dart                # CHANGED — event loop, dispatch, ordering rule, stop
│   ├── context_assembler.dart              # CHANGED — tool turns in replay, token accounting
│   ├── tool_handler_providers.dart         # NEW — registry+handlers wiring (theme handler binds
│   │                                       #   the existing settings/theme mechanism)
│   └── widgets/
│       ├── tool_chip.dart                  # NEW — §8 treatment: tag, args, quiet result, states
│       └── message_bubble.dart / chat list # CHANGED — render role=tool rows as chips
android/app/src/main/
│   ├── AndroidManifest.xml                 # + SET_ALARM permission, ACTION_SET_TIMER <queries>
│   └── kotlin/.../MainActivity.kt          # + ~10-line StatFs free-storage MethodChannel
tool/check_plugin_seam.sh                   # CHANGED — battery_plus/android_intent_plus confinement
test/
├── unit/  (validator, dispatcher, registry sanity, leak filter, assembler replay, controller loop)
├── widget/ (tool chip states + a11y, chat flow with tool events, gating regression)
└── data/  (migration v3→v4 seeded-file test, repository tool rows + cascade)
```

**Structure Decision**: same layered single-app structure as 001–003 — pure data/logic in
`core/`+`domain/`, plugin touchpoints behind `infrastructure/` seams, Riverpod wiring + UI in
`features/`. The only structural novelty is `lib/core/tools/` (registry/validator as pure data +
logic) and `lib/infrastructure/tools/` (the new plugin confinement zone, added to the seam guard).

## Complexity Tracking

> No constitutional violations — table intentionally empty (see Constitution Check).

## Post-Design Constitution Re-Check

Re-evaluated after Phase 1 artifacts (research.md, data-model.md, contracts/, quickstart.md):

- **I/II (privacy/offline)**: confirmed — no contract introduces egress; the timer intent is an
  on-device OS hand-off; quickstart V8 is the airplane-mode pass over all four tools.
- **III (capability as data)**: contract `gemma_service.md` makes tools+flag a single coupled
  input; `tool_registry_dispatcher.md` keeps the registry pure data; the flag-off byte-parity is
  a contract guarantee with a dedicated regression test.
- **IV/V (responsive/graceful)**: the controller loop's outcome matrix is pinned in
  `conversation_repository.md` (terminal chip states) and data-model §4 (state machine including
  stop transitions and the stale-row sweep); leak suppression is O(buffered-prefix) only.
- **VI/X (accessible/identity)**: chip spec in contracts uses tokens only; AA floor stated;
  red confined to error.
- **VII (seam)**: all three new plugin touchpoints (battery, intent, channel) live behind
  `infrastructure/tools/` services with fakes; the dispatcher and controller test against fakes;
  seam-guard extension is a task.
- **VIII/IX (hygiene/lean)**: no new resources to leak; validator scope deliberately minimal.

**Re-check result**: PASS — unchanged from the pre-research gate; the three ⚠ device cautions
remain tracked in quickstart V8–V10.
