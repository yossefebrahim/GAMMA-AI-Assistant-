# Implementation Plan: On-Device Memory — Durable Facts About the User

**Branch**: `005-memory` | **Date**: 2026-06-11 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `/specs/005-memory/spec.md` (clarified 2026-06-11) and the Phase
0 spike ([spike-findings.md](spike-findings.md), GATE PASSED — 80% capture, 0 false positives, native
system-message injection confirmed).

## Summary

Give the assistant durable, app-global memory of the user: a `remember_fact` tool auto-captures
durable facts the user shares (deduped/superseded so the store stays coherent), a `forget_fact` tool
removes them, and the active facts are injected as a compact id-bearing system message at each session
boundary so new conversations are grounded in them. A settings screen lists facts by category with
edit / delete / clear-all and a global on/off toggle (on by default) for full transparency. Everything
is on-device SQLite — **no embeddings, no RAG, no network** (a v1 constitution boundary). Capture is
gated on the active model's `functionCalling` capability (built on the 004 tool registry); injection
and management are not.

Technical approach — extend 004 rather than reshape it; the tool registry, dispatcher + validator,
`GenerationEvent` seam, LeakFilter, seam-side capability `StateError` gate, `role='tool'` chip, and
`systemInstruction` plumbing are all reused:

- **Persistence.** New `memories` table (drift **v4 → v5**, additive `m.createTable`) + a
  `memoryEnabled` flag on `app_settings` (`m.addColumn`, default true). `MemoryRepository` (interface
  + `DriftMemoryRepository`) owns the table with **dedupe/supersede** on `upsert` (normalized exact
  match → no-op; same-category token-Jaccard ≥ ~0.5 → supersede in place; else insert; cap at 20),
  `softDeleteById` (id validated against active rows — never fuzzy-delete), `editFact`, `clearAll`,
  `watchActive`. Soft-delete throughout; `sourceConversationId` is `ON DELETE SET NULL` so facts
  outlive their source conversation (data-model §2/§3).
- **Tools (plugin-free domain).** `ToolRegistry` gains `memoryTools` (`remember_fact{fact:string
  maxLength 80, category:enum}`, `forget_fact{id:integer}`) alongside `deviceTools`. The
  `SchemaValidator` gains one keyword (`maxLength`). The `ToolDispatcher` is unchanged (validate →
  handler → typed `ToolOutcome`, never throws); two new handlers bind the `MemoryRepository`. The
  `remember_fact` outcome distinguishes created/superseded (chip says "remembered" vs "updated");
  `forget_fact` on an unknown id → `ToolFailure('no such fact')` (contracts/tool_registry_dispatcher.md).
- **Injection (pure composition).** `FactsBlockComposer` builds the capped, id-bearing,
  category-ordered block (≤20 facts / ≤900 chars, oldest-first drop). `SystemInstructionComposer`
  joins [facts block?] + [memory capture instruction?] + [device tool-use instruction?] by flag
  (`memoryEnabled`, `functionCalling`), returning `null` when empty (byte-parity). Both pure,
  unit-tested. The seam's `loadModel` now takes the composed `systemInstruction` (it no longer
  hardcodes `ToolRegistry.systemInstruction`).
- **Seam.** `GemmaService.loadModel` gains `systemInstruction:`; a new `startSession({systemInstruction})`
  recreates the chat (close session → `createChat`) on the SAME loaded model — cheap (~ms
  `createConversation`, no re-mmap) — for the "next session" boundary (R1/R2). The FFI cached-session
  caveat (close before recreate) is handled inside the seam. `generate` is unchanged and takes no
  per-call instruction, so facts can't change mid-conversation (FR-008).
- **Controller / providers.** The session provider composes `declaredTools` (`deviceTools` if
  `functionCalling`; `+ memoryTools` if also `memoryEnabled`) and the system instruction, passing both
  to `loadModel`. The chat controller calls `startSession` (recomposed block) on conversation open and
  on memory-toggle. `remember_fact`/`forget_fact` calls flow through the EXISTING 004 tool-turn state
  machine → chips for free. `ContextAssembler` reserves the memory tokens (~311 when both active) off
  the 1536 budget.
- **UI.** A `MemoryScreen` in settings (list grouped by category, edit/delete/clear-all behind a
  destructive confirm, a global toggle) reusing the settings list/section + design-system §8 patterns;
  memory chips reuse the 004 `ToolChip` verbatim.

Decisions and the no-new-dependency stance in [research.md](research.md) (R1–R9); entities, the v4→v5
migration, dedupe/supersede, and session lifecycle in [data-model.md](data-model.md); seam / repo /
registry contracts in [contracts/](contracts/); device validation in [quickstart.md](quickstart.md).

## Technical Context

**Language/Version**: Dart 3.12.x on Flutter stable — unchanged from 001–004.

**Primary Dependencies**: **NO new package** (Principle IX). Memory persists via the existing drift /
sqlite3 stack; tools via the 004 registry/dispatcher; injection via the existing `systemInstruction`
plumbing; dedupe via plain string-token overlap (explicitly NOT embeddings/vectors — Principle I/IX).
`flutter_gemma ^0.15.0` (0.15.3 installed) UNCHANGED — spike findings are 0.15.3-specific; 0.16.x
remains a model-load regression on the A34.

**Storage**: drift over app-private SQLite. Schema bumps to **v5**: new `memories` table (`id`, `fact`,
`category`, `createdAt`, `updatedAt`, `active`, `sourceConversationId` FK `ON DELETE SET NULL`) + index
`(active, category, updatedAt)`; `app_settings.memoryEnabled` (bool, default true). Additive only — v4
rows untouched (data-model §2).

**Testing**: `flutter_test` unit + widget against fakes — `MemoryRepository` dedupe/supersede/cap/
soft-delete (in-memory drift), `FactsBlockComposer` (ordering, id prefix, cap/oldest-drop, empty→empty),
`SystemInstructionComposer` (all flag combos incl. null byte-parity), `SchemaValidator` `maxLength`,
dispatcher with the two new handlers (success/created vs superseded, unknown forget id, invalid args),
`FakeGemmaService` recording `systemInstruction`/`startSession`, controller (capture chip, forget chip,
toggle→startSession, facts-apply-next-session), a seeded **v4 file DB** v4→v5 migration test, the
memory screen widget + a11y. No device/plugin/network in tests (Principle VII). Device verification via
[quickstart.md](quickstart.md) — **`flutter run`/`flutter drive` only**.

**Target Platform**: Android, arm64-v8a, API 29+ (unchanged). No new permissions. No runtime prompts.

**Performance Goals**: `startSession` adds only a ~ms `createConversation` (no re-mmap); facts block ≤
~225 tokens + capture instruction ~86 ≈ ≤ ~20% of the 1536 budget (spike §2); capture/forget round
trips ride the existing 004 latency envelope (< 20 s send→grounded answer); streaming/stop unchanged.

**Constraints**: on-device only — facts never leave the device; **no new network call** (Principle I;
`check_network_seam.sh` stays green); **no embeddings/vector store/RAG** (Principle I/IX boundary);
fully offline (II; quickstart V11); capture declared to the model ONLY when `functionCalling` &&
`memoryEnabled`, structurally coupled at the seam (the 004 silent-trap `StateError`); injection +
management NOT gated on capability (FR-009/FR-016); facts apply from the next session, never
mid-conversation (FR-008); raw tool-call JSON never rendered (004 LeakFilter); exactly one model
active, no new sessions/models beyond the cheap chat recreation (VIII); monochrome chips + settings
rows, red reserved for destructive/error (VI/X); 48dp/AA on the new screen (VI).

**Scale/Scope**: single local user; two new tools; one new table + repository; two pure composers; one
validator keyword; one additive migration; one new settings screen; one seam method + one `loadModel`
param; provider + controller wiring. No new layers, no new plugin.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.* Constitution **1.2.0**.
Legend: ✅ satisfied by design · ⚠ implementation caution (carried into tasks/quickstart).

| # | Principle | Gate — how this plan satisfies it | Status |
|---|-----------|-----------------------------------|--------|
| I | Privacy Is the Product | All memory is local SQLite; facts never leave the device; **no embeddings/vectors/RAG/network** introduced (dedupe is plain string-token overlap). `check_network_seam.sh` still covers the codebase; quickstart V11 is the airplane-mode pass. | ✅ |
| II | Offline-First | Capture, inject, forget, manage all work with zero connectivity (V11). | ✅ |
| III | Capability-Driven UX | Auto-capture is declared to the model strictly via `functionCalling` (catalog→seam→provider data, the 004 structural coupling + `StateError`); injection + management are deliberately capability-independent (FR-009/FR-016) — data-driven, no per-model `if`. Flag-off chat is byte-parity (SC-010). | ✅ |
| IV | Responsive & Cancellable | Memory tool turns reuse the 004 streamed round trip + stop; `startSession` is a ~ms chat recreation off the model-load path; composition is pure/synchronous. | ⚠ verify `startSession` adds no perceptible hitch on conversation open — quickstart V8/V12 |
| V | Graceful Degradation | Invalid args, unknown forget id, cap exceeded, capture-while-disabled, handler failure all map to typed outcomes → visible error chip + honest text (FR-020); dedupe is conservative + user-correctable; nothing can crash the turn. | ⚠ implement the full outcome matrix incl. the toggle-window guard (contract) |
| VI | Dark-First & Accessible | Memory screen + chips use tokens only; destructive (delete/clear-all) uses the sanctioned red; AA + 48dp on the new interactive surfaces. | ⚠ Accessibility Scanner pass — quickstart V13 |
| VII | Testable Through a Plugin Seam | flutter_gemma stays in the seam; `MemoryRepository` is behind an interface with a fake; composers/validator/dispatcher/controller test plugin-free; no new plugin to confine. | ✅ |
| VIII | Resource Hygiene | No new model/session beyond a cheap chat recreation (close-before-recreate, no re-mmap); facts bounded by the cap; soft-delete keeps the table small and queryable; no new files on disk. | ✅ |
| IX | Lean Scope | Exactly the spec slice: two tools, one table, app-global memory (no per-conversation profiles), auto-save (no confirm flows), exact-text injection (no embeddings/RAG/summarization), no sync/export. **No new dependency.** | ✅ |
| X | Design Identity | Memory chips are the 004 §8 treatment; the settings screen reuses the existing list/section pattern; red only on destructive/error; lowercase microcopy; centralized tokens. | ✅ |
| — | Technology & Platform Constraints | Stack unchanged; SQLite-only is exactly the constitution's persistence choice; the spike converted "memory is feasible on E2B" into verified fact. | ✅ |

**Gate result**: PASS. No principle is violated; three ⚠ items are device-verification cautions
carried into quickstart/tasks. **Complexity Tracking is therefore empty.**

## Project Structure

### Documentation (this feature)

```text
specs/005-memory/
├── spike-findings.md    # Phase 0 spike (committed; gate PASSED)
├── plan.md              # This file
├── research.md          # R1–R9 (no-new-dependency decisions)
├── data-model.md        # memories table, v4→v5 migration, dedupe/supersede, session lifecycle
├── quickstart.md        # device validation V1–V13
├── contracts/
│   ├── memory_repository.md
│   ├── gemma_service.md            # startSession + systemInstruction forwarding
│   └── tool_registry_dispatcher.md # remember_fact/forget_fact + maxLength + handlers
├── checklists/requirements.md
└── tasks.md             # Phase 2 (/speckit-tasks)
```

### Source Code (repository root) — changes layered on the existing tree

```text
lib/
├── core/
│   ├── tools/
│   │   ├── tool_registry.dart          # CHANGED — deviceTools/memoryTools/specs + 2 memory specs
│   │   └── schema_validator.dart       # CHANGED — + maxLength keyword (string)
│   └── memory/
│       ├── facts_block_composer.dart   # NEW — capped, id-bearing, category-ordered block (pure)
│       └── system_instruction_composer.dart # NEW — facts + capture + tool-use → systemInstruction (pure)
├── domain/
│   ├── entities/
│   │   ├── memory.dart                 # NEW — Memory + MemoryCategory + UpsertResult
│   │   └── app_settings.dart           # CHANGED — + memoryEnabled (default true)
│   ├── repositories/
│   │   └── memory_repository.dart      # NEW — interface (contract)
│   └── services/
│       └── gemma_service.dart          # CHANGED — loadModel(systemInstruction:), startSession()
├── data/
│   ├── db/
│   │   ├── tables.dart                 # CHANGED — Memories table + memoryEnabled column
│   │   └── app_database.dart           # CHANGED — schemaVersion 5, v4→v5 migration
│   └── repositories/
│       ├── drift_memory_repository.dart # NEW — dedupe/supersede/cap/soft-delete
│       └── settings_repository.dart     # CHANGED — read/write memoryEnabled
├── infrastructure/gemma/
│   └── flutter_gemma_service.dart      # CHANGED — forward systemInstruction; startSession (close→createChat)
├── features/
│   ├── chat/
│   │   ├── chat_providers.dart         # CHANGED — declaredTools + composed systemInstruction → loadModel
│   │   ├── chat_controller.dart        # CHANGED — startSession on open/toggle; inject sourceConversationId
│   │   ├── context_assembler.dart      # CHANGED — reserve memory tokens off the budget
│   │   └── tool_handler_providers.dart # CHANGED — remember_fact/forget_fact handlers → MemoryRepository
│   └── settings/
│       ├── memory_screen.dart          # NEW — list by category, edit/delete/clear-all, global toggle
│       ├── memory_controller.dart      # NEW — add/edit/delete/clear/toggle actions
│       └── settings_screen.dart        # CHANGED — entry row → memory screen
├── app/router.dart                     # CHANGED — route to the memory screen
test/
├── unit/  (memory repo dedupe/supersede/cap, facts-block composer, system-instruction composer +
│          byte-parity, schema_validator maxLength, dispatcher memory handlers, assembler reserve)
├── widget/ (memory screen list/edit/delete/clear/toggle + a11y, capture/forget chip flow,
│          capability-off + memory-off regression)
└── data/  (v4→v5 seeded-file migration test, memories soft-delete + ON DELETE SET NULL)
integration_test/  (shipped reliability harness — the 30-prompt suite, flutter drive; quickstart V9)
```

**Structure Decision**: same layered single-app structure as 001–004. The only structural novelty is
`lib/core/memory/` (pure composers) and `lib/data` gaining the `memories` table + repository — both
inside existing layers. No new plugin confinement zone (memory is drift, already behind a seam).

## Complexity Tracking

> No constitutional violations — table intentionally empty (see Constitution Check). The one judgment
> call (heuristic dedupe/supersede via token-Jaccard rather than NLP) is explicitly a non-semantic,
> on-device, user-correctable string method chosen to stay inside the no-embeddings boundary (R8).

## Post-Design Constitution Re-Check

Re-evaluated after Phase 1 artifacts (research.md, data-model.md, contracts/, quickstart.md):

- **I/II/IX (privacy/offline/lean)**: confirmed — no contract introduces egress, embeddings, or a new
  dependency; dedupe is plain token overlap; quickstart V11 is the airplane-mode pass; SQLite only.
- **III (capability as data)**: `gemma_service.md` keeps capture coupled to `functionCalling` via the
  guarantee-18 gate while making injection capability-independent (guarantee 28) — both data-driven;
  byte-parity preserved (guarantee 29, SC-010 test).
- **IV/V (responsive/graceful)**: `startSession` is a no-reload chat recreation (guarantee 27); the
  dispatcher/repository outcome matrix (unknown id, cap, toggle-window, invalid args) is pinned in the
  contracts and terminates in a visible chip + honest text.
- **VI/X (accessible/identity)**: chips reuse the 004 §8 treatment; the memory screen reuses the
  settings pattern with tokens only and red confined to destructive/error.
- **VII/VIII (seam/hygiene)**: `MemoryRepository` behind an interface with a fake; the seam stays the
  only plugin importer; no new resource to leak; soft-delete + cap keep the table bounded.

**Re-check result**: PASS — unchanged from the pre-research gate; the three ⚠ device cautions remain
tracked in quickstart V8/V12/V13.
