# Data Model — 004 Function Calling

## 1. Domain entities

### ToolSpec (new, immutable — `lib/domain/entities/tool_spec.dart`)

| Field | Type | Rules |
|---|---|---|
| `name` | `String` | unique in the registry; `snake_case`; the model-facing identifier |
| `description` | `String` | non-empty; the model's when-to-use guidance (includes constraints the model should explain, e.g. clipboard foregrounding) |
| `parameters` | `Map<String, Object?>` | JSON-schema object (the subset in research R3); `const`-able |
| `kind` | `ToolKind` enum: `readOnly` \| `stateChanging` | drives nothing in v1 (all auto-execute, spec Q1) but is REQUIRED data so a future confirmation policy is a data change (FR-016) |

### ToolRegistry (new, const data — `lib/core/tools/tool_registry.dart`)

`static const List<ToolSpec> specs` — exactly four entries (`get_device_info`,
`summarize_clipboard`, `set_theme`, `set_timer`). Invariants (unit-tested): unique names, every
`parameters` map is itself schema-valid, every description non-empty.

### GenerationEvent (new, sealed — `lib/domain/entities/generation_event.dart`)

- `TextDelta(String token)`
- `ToolCallRequested(String name, Map<String, Object?> args, {int extraCallCount = 0})` —
  `extraCallCount > 0` records discarded parallel calls (FR-024); always the FINAL event of its
  stream (the plugin yields it at end-of-stream — spike §1.3).

### ToolOutcome (new, sealed — `lib/domain/entities/tool_outcome.dart`)

- `ToolSuccess(Map<String, Object?> result, {bool truncated})`
- `ToolUnknown(String attemptedName)` — hallucinated tool (FR-022)
- `ToolInvalidArgs(String reason)` — schema rejection, handler never ran (FR-023)
- `ToolFailure(String reason)` — handler executed and failed (FR-025: empty clipboard, no clock
  app, out-of-bounds duration…)

### Message (existing — extended)

| Field | Change |
|---|---|
| `role` | gains `MessageRole.tool` (today: user/assistant) |
| `toolName` | NEW `String?` — non-null iff role == tool |
| `toolArgs` | NEW `Map<String, Object?>?` — the model's arguments as validated/attempted |
| `toolStatus` | NEW `ToolCallStatus?` enum: `running` \| `success` \| `error` \| `skipped` |
| `toolResult` | NEW `Map<String, Object?>?` — result on success, `{error: reason}` otherwise; ≤2,000 chars JSON (R3 bound) |
| `content` | for tool rows: the chip's quiet one-line summary (lowercase microcopy, e.g. `battery 83% · 7.4 gb ram`) — display text only, never fed to the model |

Invariant (repo-enforced, mirrors the 003 XOR pattern): tool fields are all-null for
user/assistant rows and `toolName`/`toolStatus` non-null for tool rows; a tool row never carries
attachments (`imagePath`/`audioPath` stay null).

### ModelCapabilities / ModelCatalog (existing)

`ModelCapabilities.functionCalling` (already present, default false) is now SET from
`ModelCatalog.supportsFunctionCalling = true` (spike-verified for Gemma 4 E2B + 0.15.3),
composed exactly like `supportsImage`/`supportsAudio`.

## 2. Database schema — drift v3 → v4 (additive only, house style)

`messages` table gains four nullable columns; `role` (TEXT) gains the value `'tool'`
(domain-enforced — no SQL CHECK, consistent with existing role handling):

```sql
ALTER TABLE messages ADD COLUMN tool_name TEXT NULL;
ALTER TABLE messages ADD COLUMN tool_args TEXT NULL;     -- JSON
ALTER TABLE messages ADD COLUMN tool_status TEXT NULL;   -- running|success|error|skipped
ALTER TABLE messages ADD COLUMN tool_result TEXT NULL;   -- JSON, ≤2000 chars (app-enforced)
```

- v3 rows untouched (all four columns NULL); fresh installs get v4 via onCreate.
- `status` (the existing streaming lifecycle column) stays `'complete'` for tool rows — the tool
  lifecycle lives in `tool_status`, not in the streaming status machine.
- Existing index `idx_messages_conversation (conversationId, sequence)` unchanged — tool rows are
  ordinary sequenced messages.
- **Deletion cascade**: tool rows are messages; `deleteConversation`'s existing cascade covers
  them (FR-020). No files to clean (results are inline text).
- **Migration test** (house pattern): seed a real v3 file DB (with the index), open at v4, assert
  old rows intact + NULL tool columns + a tool-row insert/readback round-trips.

## 3. Persistence & replay mapping

One row per invocation. The seam expands each tool row into the plugin's two replay messages:

| App DB (one `role='tool'` row) | Plugin replay (in `clearHistory(replayHistory:)`) |
|---|---|
| `toolName` + `toolArgs` | `Message.toolCall(text: '{"role":"assistant","tool_calls":[{"type":"function","function":{"name":<toolName>,"arguments":<toolArgs>}}]}')` — the raw SDK shape observed verbatim in the spike |
| `toolStatus` + `toolResult` | `Message.toolResponse(toolName: <toolName>, response: <toolResult>)` — errors replay too (`{error: …}`), so the model remembers failures honestly |

`skipped` rows (stop before dispatch, or extra-call discards) replay the call with
`{error: 'skipped'}` — context fidelity over prettiness. **Replay fidelity is device-verified in
quickstart V6** (the reconstructed raw-JSON shape is the one unverified-by-unit-test seam input).

`ContextAssembler` treats a tool row as one turn for token accounting (name + args + result JSON
at the 4-chars/token heuristic) and drops oldest-first exactly as today; the system instruction's
~40 tokens (R6) are reserved off the top of the budget.

## 4. Tool-turn state machine (controller-owned)

```
send(text)
  └─ persist user row → open streaming assistant row (dot-pulse) → gemma.generate(events)
       ├─ TextDelta*            → buffer/flush into assistant row (today's path)
       └─ ToolCallRequested     → [leak already suppressed at seam]
            ├─ assistant row EMPTY  → delete it          ┐  ordering rule:
            ├─ assistant row has text → finalize it       ├─ history always reads
            ├─ persist tool row (toolStatus: running)     ┘  user → (text) → chip → answer
            ├─ stop requested already?       → finalize tool row: skipped → END turn
            ├─ name ∉ registry               → finalize: error(unknown tool)   ─┐
            ├─ args fail schema              → finalize: error(invalid args)   ─┤
            ├─ dispatch handler:                                                │
            │     success → finalize: success(result)                           │
            │     failure → finalize: error(reason)                             │
            ├─ extraCallCount > 0 → record in the SAME chip (… +n calls skipped)│
            ├─ stop requested now?           → END turn (no resume)            ─┤
            └─ open NEW streaming assistant row                                ←┘
                 └─ gemma.resumeWithToolResult(name, result-or-error)
                      ├─ TextDelta* → stream into the new assistant row → finalize complete/stoppedPartial
                      └─ ToolCallRequested (2nd) → finalize tool row #2 as skipped-with-error chip
                                                   (FR-006/FR-024), turn ends as text
```

- **Terminal-state guarantee** (spec edge case): `running` is transient. A startup sweep
  finalizes any stale `running` tool row to `error('interrupted')` — mirroring the existing
  stale-`streaming` message finalization.
- **Stop semantics (FR-026)**: stop before dispatch → `skipped`, nothing executed; stop after
  dispatch → the (fast, local) handler completes, the row finalizes truthfully, but no resume —
  the turn ends; never a half-recorded execution.
- **Errors inform the model**: error outcomes still resume generation (with `{error: …}` as the
  tool result) so the assistant's text acknowledges the failure (FR-022/023/025) — EXCEPT when
  stop ended the turn.

## 5. Chip rendering model (from one tool row)

| Row state | Chip (design-system §8) |
|---|---|
| `running` | `TOOL · GET_DEVICE_INFO` mono tag + dot-pulse (in-flight turns only — never in reopened history, per the sweep) |
| `success` | tag + args summary + quiet `content` line (`textSecondary`) |
| `error` | tag + quiet error line; the error glyph/text is the sanctioned red use (design-system accent discipline) |
| `skipped` | tag + `skipped` spec-line (mono, `textSecondary`) |

Chips render for any conversation regardless of the active model's capabilities (FR-010), are
non-interactive in v1, and carry `Semantics` labels (`tool get_device_info: success — battery
83%…`) for screen readers.
