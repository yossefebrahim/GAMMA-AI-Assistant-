export const meta = {
  name: 'implement-005-memory',
  description: 'Implement remaining 005-memory tasks T012-T043 + T050 across dependency-ordered waves',
  phases: [
    { title: 'Leaf', detail: 'Isolated new files & leaf changes: validator, composers, context reserve, settings repo' },
    { title: 'Seam & Registry', detail: 'Gemma seam (loadModel/startSession), tool registry, memory controller' },
    { title: 'Wiring', detail: 'tool handlers, chat_providers, chat_controller, memory screen' },
    { title: 'Routing & Tests', detail: 'route entry, widget/unit/gating tests, reliability harness, audits/docs' },
    { title: 'Verify', detail: 'analyze + format + run host test suite, fix breakages, check off tasks.md' },
  ],
}

const ROOT = '/Users/yossefebrahim/Work/ai_assistant'

const SHARED = `
You are implementing part of feature 005-memory (durable user facts / memory) in a Flutter/Dart app.
Working dir: ${ROOT}. Branch: 005-memory.

REQUIRED READING before you touch code (read what is relevant to YOUR task):
- specs/005-memory/tasks.md           (the task list; your task id is named below)
- specs/005-memory/data-model.md      (entities, facts-block format, dedupe/supersede, session lifecycle)
- specs/005-memory/contracts/gemma_service.md
- specs/005-memory/contracts/tool_registry_dispatcher.md
- specs/005-memory/contracts/memory_repository.md
- specs/005-memory/research.md        (R3/R4/R5/R8/R9 — validator keyword, cap, capture instruction wording, jaccard, schemas)
- specs/005-memory/spike-findings.md  (§3 remember_fact, §4 forget_fact hazards)

ALREADY DONE (T001-T011) — do NOT recreate, just USE:
- lib/domain/entities/memory.dart : Memory, enum MemoryCategory { identity, work, preferences, other },
  sealed UpsertResult = UpsertCreated | UpsertSuperseded | UpsertUnchanged (each carries .memory).
- lib/domain/repositories/memory_repository.dart : MemoryRepository interface
  (watchActive, listActive, upsert, softDeleteById, editFact, clearAll, activeCount).
- lib/data/repositories/drift_memory_repository.dart : DriftMemoryRepository + memoryRepositoryProvider
  + activeMemoriesProvider (StreamProvider<List<Memory>>). Constants: maxActiveFacts=20, supersedeThreshold=0.5.
- test/helpers/fake_memory_repository.dart : FakeMemoryRepository (has .seed(List<Memory>) and .dispose()).
- drift schema is already at v5 (memories table + app_settings.memoryEnabled column, default true). Codegen DONE.
- lib/domain/entities/app_settings.dart already has memoryEnabled (default true).

PATTERN SOURCES — mirror the existing 004/003 code; study the analogous file before writing:
- 004 function-calling is the template: tool registry (lib/core/tools/tool_registry.dart),
  schema validator (lib/core/tools/schema_validator.dart), dispatcher (lib/domain/services/tool_dispatcher.dart),
  the gemma seam (lib/infrastructure/gemma/flutter_gemma_service.dart + lib/domain/services/gemma_service.dart),
  tool handlers (lib/features/chat/tool_handler_providers.dart), chat wiring
  (lib/features/chat/chat_providers.dart, chat_controller.dart, context_assembler.dart),
  FakeGemmaService (test/helpers/fake_gemma_service.dart).
- Settings/theme pattern: lib/features/settings/settings_controller.dart, settings_screen.dart,
  lib/data/repositories/settings_repository.dart (themeMode read/write + themeModeProvider is the template
  for memoryEnabled), lib/app/router.dart, design system .specify/memory/design-system.md (§8 chips/tokens).

HARD RULES:
- On-device only. NO network, NO embeddings, NO vector search. Dedupe is plain string-token jaccard (already built).
- Match the surrounding code's style, naming, comment density, lowercase microcopy, monochrome design-system tokens.
- House TDD: write the test alongside the implementation it covers (your task says which test dir).
- Device-only commands are FORBIDDEN here: never run \`flutter run\`, \`flutter drive\`, or
  \`flutter test integration_test/...\` (the last wipes the device's model+DB).
- CRITICAL: do NOT run \`flutter analyze\`, \`flutter test\`, \`dart run build_runner\`, \`dart format\`, or
  any flutter/dart build/test command. Other agents are editing the same worktree in parallel; concurrent
  tool runs corrupt .dart_tool. A dedicated final agent compiles, formats, and runs the host test suite.
  Your job is to write correct code + tests per the contracts and STOP. Read freely; just don't invoke the toolchain.
- Only create/edit the file(s) your task names. Do not edit shared files owned by other tasks.
- No new pub dependency (flutter_gemma stays ^0.15.0 / 0.15.3).

Return a terse report: files created/edited and any assumption or symbol name a downstream agent must know.
`

const M = 'sonnet'
const mk = (prompt, label, phase) => agent(SHARED + '\n\nYOUR TASK:\n' + prompt, { label, phase, model: M })

// ───────────────────────── Wave 1: Leaf (disjoint new/isolated files) ─────────────────────────
phase('Leaf')
await parallel([
  () => mk(
    `T012 — Add a \`maxLength\` keyword to SchemaValidator for type:string properties.
FILE: lib/core/tools/schema_validator.dart (edit) + test/unit/ (new or extend schema_validator_test.dart).
- For a property with {"type":"string","maxLength":N}, reject a string longer than N with a first-failure,
  human-readable reason e.g. Invalid('fact exceeds 80 characters') (use the schema's maxLength in the message).
- Keep the existing 004 subset (object/properties/required/enum/string/integer/number/boolean/min/max + strict
  unknown-key rejection) unchanged. maxLength is additive; degrade-safe like the rest.
- Tests: over-length string -> Invalid with the char count; exactly-N is valid; non-string ignores maxLength.`,
    'T012:validator', 'Leaf'),

  () => mk(
    `T019 — FactsBlockComposer: pure function (active facts -> injected block text). data-model "Facts block" section.
FILE: lib/core/memory/facts_block_composer.dart (NEW) + test/unit/facts_block_composer_test.dart (NEW).
- Format EXACTLY (see data-model example): a header line "known facts about the user (saved across chats):"
  then ONE line per category PRESENT, in enum declaration order (identity, work, preferences, other), shaped
  "<category> — #<id> <fact>; #<id> <fact>" (facts within a category ordered updatedAt desc; the input list is
  already category->updatedAt-desc ordered by the repo, but don't assume — order defensively).
- Cap: at most 20 facts AND at most 900 chars; when over, DROP oldest-first (lowest updatedAt) until within both bounds.
- Empty store / empty input -> return '' (empty string => no block, no token cost).
- Make it a top-level function or a class with a static compose(List<Memory>) -> String. Pick whichever matches
  the codebase's composer idiom; document the chosen signature in your report for downstream agents.
- Tests: id-prefixed lines; category ordering; updatedAt-desc within category; 20-fact and 900-char drop (oldest-first);
  empty -> ''.`,
    'T019:facts-composer', 'Leaf'),

  () => mk(
    `T020 — SystemInstructionComposer: joins up to three parts into the model's system instruction.
FILE: lib/core/memory/system_instruction_composer.dart (NEW) + test/unit/system_instruction_composer_test.dart (NEW).
- compose({ String? factsBlock, bool memoryCapture, bool deviceTools }) -> String?
  parts, in this order, joined by blank lines:
    1. factsBlock (if non-null and non-empty)
    2. a short memory-capture instruction (only when memoryCapture == true) — wording per research R5
       (instruct the model to call remember_fact for durable user facts as short third-person statements,
        and forget_fact with an id from the known-facts list; keep it short — the spike reliability lever).
    3. the device tool-use instruction = ToolRegistry.systemInstruction (only when deviceTools == true).
- Return null when ALL parts are empty/false (byte-parity guarantee 29 — null => no system instruction at all).
- Read the EXACT R5 wording from research.md; read ToolRegistry.systemInstruction's current text. Do NOT hardcode
  a duplicate of the device instruction — reference ToolRegistry.systemInstruction.
- Tests: each subset combination; null when everything off; capture wording present only when memoryCapture;
  ordering facts->capture->device.`,
    'T020:sysinstr-composer', 'Leaf'),

  () => mk(
    `T025 — ContextAssembler memory token reserve.
FILE: lib/features/chat/context_assembler.dart (edit) + test/unit/ (extend context_assembler test).
- Reserve memoryReserveTokens off the existing budget alongside the current 40-token device-tool reserve:
  ~225 tokens for the facts block + ~86 for the capture instruction WHEN BOTH active (read data-model §4 / research
  for the exact numbers and conditions). Reserve nothing for memory when memory is off/empty.
- Mirror exactly how the existing 40-token tool reserve is parameterized/threaded. Add tests for the reserve math
  across the on/off combinations.
- In your report, state how the assembler learns whether facts/capture are active (param name) so the chat wiring
  agent threads the right flags.`,
    'T025:context-reserve', 'Leaf'),

  () => mk(
    `T027 — Persist & expose memoryEnabled (mirror themeMode exactly).
FILES: lib/data/repositories/settings_repository.dart (edit: add readMemoryEnabled/setMemoryEnabled over
app_settings.memoryEnabled, mirroring the themeMode read/write) AND a memoryEnabledProvider (a manual Notifier over
app_settings.memoryEnabled, mirroring themeModeProvider — put it wherever themeModeProvider lives). + test/unit/ or
test/data/ coverage mirroring the themeMode tests.
- Default true. Persisted in the single-row app_settings table (column already exists at schema v5).
- In your report: the exact provider name (memoryEnabledProvider) and its type, and the repo method names, so the
  memory controller + chat wiring agents can depend on them.`,
    'T027:settings-memoryEnabled', 'Leaf'),
])

// ───────────────────────── Wave 2: Seam, Registry, Memory Controller ─────────────────────────
phase('Seam & Registry')
await parallel([
  () => mk(
    `T013 — Add memoryTools to ToolRegistry and split into three views.
FILE: lib/core/tools/tool_registry.dart (edit) + test/unit/ (update the registry-sanity test).
- Expose: static const List<ToolSpec> deviceTools (the existing four), static const List<ToolSpec> memoryTools
  (remember_fact, forget_fact), static const List<ToolSpec> specs = deviceTools + memoryTools (byName scans specs).
  Keep static const String systemInstruction (the device tool-use instruction) as-is.
- remember_fact: kind stateChanging; schema {type:object, properties:{ fact:{type:string, maxLength:80}, category:
  {type:string, enum:[identity,work,preferences,other]} }, required:[fact,category]}. Description carries model-facing
  guidance (capture durable user facts as short third-person statements) per spike §3.
- forget_fact: kind stateChanging; schema {type:object, properties:{ id:{type:integer, minimum:1} }, required:[id]}.
  Description: ids come from the injected known-facts list; per spike §4.
- Update the registry-sanity test: now SIX tools; names unique + snake_case; every schema self-validates against
  SchemaValidator (incl. the new maxLength keyword from T012); descriptions non-empty; kind set; the two memory tools
  are stateChanging. Keep deviceTools/memoryTools/specs groupings asserted.
NOTE: T012 added maxLength to the validator in this same run — your remember_fact schema relies on it.`,
    'T013:registry', 'Seam & Registry'),

  () => mk(
    `T021 + T022 — GemmaService seam: composed systemInstruction on load + cheap startSession. (BOTH tasks, same files.)
FILES: lib/domain/services/gemma_service.dart (interface), lib/infrastructure/gemma/flutter_gemma_service.dart (seam impl,
the ONLY flutter_gemma importer), test/helpers/fake_gemma_service.dart (test double). Read contracts/gemma_service.md
(guarantees 26-30) carefully first.
- loadModel gains a named param: String? systemInstruction. Forward it to createChat(systemInstruction: ...).
  REMOVE the seam's internal hardcoded use of ToolRegistry.systemInstruction (that literal is now composed OUTSIDE the
  seam by SystemInstructionComposer and passed in). null => no system instruction.
- ADD: Future<void> startSession({String? systemInstruction}) — recreate the chat WITHOUT reloading the model:
  await the current chat session.close() FIRST (FFI cached-session caveat), then createChat on the SAME loaded _model
  with the SAME tools/capabilities and the given systemInstruction. Reset warm fingerprints / _sessionTurns, bump the
  session epoch. Throw StateError if no model is loaded (guarantee 27).
- generate / resumeWithToolResult stay UNCHANGED (no per-call instruction).
- FakeGemmaService: record the systemInstruction passed to loadModel AND startSession (expose for assertions); model
  startSession-before-load -> StateError; keep the guarantee-18 tools<->functionCalling gate; preserve the parity mode
  (null instruction + no tools => TextDelta-only).
- In your report: the exact new method signatures and the FakeGemmaService getter names for the recorded instruction,
  so the chat wiring + test agents use them correctly.`,
    'T021+T022:seam', 'Seam & Registry'),

  () => mk(
    `T028 — MemoryController for the settings screen.
FILE: lib/features/settings/memory_controller.dart (NEW) + (optional small unit test). Mirror settings_controller.dart.
- Methods: add (manual capture via MemoryRepository.upsert), edit (editFact), delete (softDeleteById), clearAll,
  setEnabled(bool). setEnabled writes via the memoryEnabled persistence from T027 AND triggers a session refresh by
  calling GemmaService.startSession(...) with a freshly composed instruction so the toggle applies promptly (FR-014).
- Depends on: memoryRepositoryProvider, the memoryEnabledProvider + repo methods from T027 (assume name
  memoryEnabledProvider / setMemoryEnabled), SystemInstructionComposer (T020) + FactsBlockComposer (T019), and the
  gemmaService provider used by the chat layer. Compose the instruction the SAME way the chat wiring will (read
  data-model §4): factsBlock = memoryEnabled ? FactsBlockComposer(activeFacts) : null; memoryCapture =
  functionCalling && memoryEnabled; deviceTools = functionCalling.
- If a symbol you need (e.g. the gemmaService provider name, or how to read current capabilities) is uncertain, read
  chat_providers.dart to find it; do not invent. State assumptions in your report.`,
    'T028:memory-controller', 'Seam & Registry'),
])

// ───────────────────────── Wave 3: Wiring + Screen (disjoint files) ─────────────────────────
phase('Wiring')
await parallel([
  () => mk(
    `T015 — Bind remember_fact / forget_fact handlers in toolHandlersProvider.
FILE: lib/features/chat/tool_handler_providers.dart (edit). Follow the existing set_theme/device-tool handler closure pattern.
- remember_fact handler: call memoryRepositoryProvider.upsert(fact, category, sourceConversationId: <active conversation id>).
  The sourceConversationId is injected by the controller/provider (NOT a tool argument) — read how the active conversation
  id is available in this provider; if it must be threaded in, expose a way (match how other per-conversation context is
  passed). Map UpsertResult -> ToolSuccess: created/superseded -> {remembered|updated: fact, category};
  unchanged -> success {noted: fact}.
- remember_fact MUST guard memoryEnabled (the rare toggle-off window): if memory is off -> ToolFailure('memory is off').
- forget_fact handler: softDeleteById(id) -> true => ToolSuccess({forgot: id}); false => throw so dispatcher yields
  ToolFailure('no such fact: <id>'). Integer-double coercion is already handled by the dispatcher.
- Do NOT edit the dispatcher itself (unchanged pipeline). Read contracts/tool_registry_dispatcher.md handler table.`,
    'T015:tool-handlers', 'Wiring'),

  () => mk(
    `T016 + T023 — chat_providers.dart: declaredTools + composed systemInstruction. (BOTH tasks, same file.)
FILE: lib/features/chat/chat_providers.dart (edit).
- declaredTools (passed to loadModel): deviceTools (when capabilities.functionCalling) + memoryTools (when
  functionCalling && memoryEnabled). Use ToolRegistry.deviceTools / .memoryTools (T013).
- Compose the system instruction via SystemInstructionComposer.compose (T020) reading the active facts
  (activeMemoriesProvider / listActive) + flags: factsBlock = memoryEnabled ? FactsBlockComposer(activeFacts) : null;
  memoryCapture = functionCalling && memoryEnabled; deviceTools = functionCalling. Pass it into loadModel(systemInstruction:).
- Thread the facts-active / capture-active flags into ContextAssembler per T025's reported param names.
- Depends on T013 (registry views), T019/T020 (composers), T021 (loadModel systemInstruction param), T027
  (memoryEnabledProvider). Reference those exact symbols.`,
    'T016+T023:chat-providers', 'Wiring'),

  () => mk(
    `T017 + T024 — chat_controller.dart: memory chip summaries + startSession on conversation open. (BOTH tasks, same file.)
FILE: lib/features/chat/chat_controller.dart (edit). REUSE the existing 004 _runToolTurn state machine unchanged.
- Chip summary mapping (the controller's tool-summary switch): remember_fact success -> 'remembered: <fact>'
  (created) / 'updated: <fact>' (superseded) / 'noted: <fact>' (unchanged); forget_fact success -> 'forgot #<id>'.
  Match the existing summary-string idiom for the four device tools. Read data-model §5 chip table.
- On openConversation (a session boundary), call gemma startSession(systemInstruction:) with a FRESHLY composed
  instruction (same composition as chat_providers / data-model §4) so a NEW conversation is grounded in facts saved
  earlier. generate() stays per-call-instruction-free (facts fixed for the conversation, FR-008). Make sure
  sourceConversationId for captures = the active conversation.
- Depends on T021/T022 (startSession), T019/T020 (composers), T015 (handlers). Reference reported symbols; read the
  file to match existing conventions before editing.`,
    'T017+T024:chat-controller', 'Wiring'),

  () => mk(
    `T029 — MemoryScreen (settings UI). FILE: lib/features/settings/memory_screen.dart (NEW). Mirror settings_screen.dart
+ design-system §8.
- Facts grouped by category in the SAME order/set as the injected block (FR-015) — drive off activeMemoriesProvider.
- Per-row edit + delete; clear-all behind a destructive confirm dialog (red is the ONLY color, on destructive actions
  only); a global memory on/off toggle bound to MemoryController.setEnabled / memoryEnabledProvider.
- Use design-system tokens, lowercase microcopy, monochrome. 48dp touch targets, AA contrast. Wire actions to
  MemoryController (T028). Management works even under a text-only model (NOT capability-gated).
- Do NOT edit settings_screen.dart or router.dart (that's T030, a later agent).`,
    'T029:memory-screen', 'Wiring'),
])

// ───────────────────────── Wave 4: Routing, Tests, Harness, Audits/Docs ─────────────────────────
phase('Routing & Tests')
await parallel([
  () => mk(
    `T030 — Add the settings entry row -> memory screen + the route.
FILES: lib/features/settings/settings_screen.dart (edit: a "memory" list row that navigates to MemoryScreen) and
lib/app/router.dart (edit: register the route). Mirror how existing settings rows/routes are declared. Use the
MemoryScreen from T029.`,
    'T030:route', 'Routing & Tests'),

  () => mk(
    `T014 + T032 — Dispatcher/handler unit tests for memory tools (tests only).
FILES: test/unit/ (new/extended). Use FakeMemoryRepository + the dispatcher.
- T014: remember_fact created vs superseded vs unchanged -> correct ToolSuccess payloads; invalid args (bad category,
  >80-char fact) -> ToolInvalidArgs; handler-throws -> ToolFailure; congruence over the <=6 declared tools;
  forget_fact int-as-double coercion.
- T032: forget_fact(valid active id) -> success + soft-delete (activeCount drops); unknown/stale/guessed id ->
  ToolFailure('no such fact: <id>') with NO deletion (spike §4 guessed-id hazard).
Read contracts/tool_registry_dispatcher.md for exact outcome strings. These are test-only — touch no lib/ code.`,
    'T014+T032:dispatcher-tests', 'Routing & Tests'),

  () => mk(
    `T018 + T034 — Widget tests for capture & forget chips (tests only). FILES: test/widget/.
Use FakeGemmaService + FakeMemoryRepository; follow the existing 004 tool-chip widget tests AND the house widget-test
async pattern (drive sends via UI + pump; never bare await/runAsync over fake streams).
- T018 (US1 AS1-AS3): a remember_fact chip renders on capture; a no-fact prompt produces NO chip; an invalid capture
  renders an error chip + a reply.
- T034 (US5 AS1-AS3): forget chip on success; an honest error chip + NO deletion on unknown id.`,
    'T018+T034:capture-forget-widget', 'Routing & Tests'),

  () => mk(
    `T026 + T035 + T036 + T037 + T038 — Injection/controller + gating/parity/transparency tests (tests only).
FILES: test/unit/ and test/widget/. Use FakeGemmaService (it records the systemInstruction per load/startSession) +
FakeMemoryRepository.seed.
- T026: a fact captured mid-conversation does NOT change the CURRENT chat's recorded instruction, but the NEXT
  openConversation composes an instruction whose facts block contains it (US2 AS1/AS3).
- T035: byte-parity (extends SC-010/guarantee 29) — functionCalling off + memory empty/off => composed instruction
  null, no tools declared, generate emits only TextDeltas; existing text/image/audio chat unchanged.
- T036: injection works with functionCalling OFF (a text-only model still gets the facts block) while capture tools
  are NOT declared (FR-009/FR-018).
- T037: memory chips render in reopened history regardless of active capability (FR-019); cap-exceeded capture +
  capture-while-disabled degrade to visible chips, never crash (FR-020).
- T038: assert the 004 LeakFilter suppresses raw remember_fact/forget_fact call JSON (regression assertion; no new lib code).
Read the FakeGemmaService getters reported by the seam agent for the recorded instruction.`,
    'T026+gating-tests', 'Routing & Tests'),

  () => mk(
    `T031 — MemoryScreen widget + a11y tests (tests only). FILE: test/widget/.
- List grouping matches the active facts set; edit persists; delete removes; clear-all empties after the confirm;
  toggle off -> the provider reflects off; 48dp touch targets + AA contrast; the screen works under a text-only model
  (management is NOT capability-gated, US3 AS5). Use FakeMemoryRepository; follow the house widget-test async pattern.`,
    'T031:settings-widget', 'Routing & Tests'),

  () => mk(
    `T033 — Verify forget_fact end-to-end wiring (verification + minimal glue only).
Confirm forget_fact flows through the existing _runToolTurn (chip + reply) and that the injected facts block carries
ids (#<id>) so the model can reference a real fact. This depends on T019 (block format) + T024 (startSession on open).
Read chat_controller.dart + facts_block_composer.dart to CONFIRM the path is complete; add only minimal glue if a gap
exists (do not duplicate other agents' edits). Report whether any code change was needed or it was already wired.`,
    'T033:forget-e2e', 'Routing & Tests'),

  () => mk(
    `T050 — AUTHOR the shipped reliability harness (do NOT run it — device only).
FILE: integration_test/ (new memory reliability harness) — a ~30-prompt capture / false-positive suite + a token-budget
assertion, runnable later via \`flutter drive\` (quickstart V9). test_driver/ already exists. Tune the R5 capture
instruction's intent toward clearing SC-001 (>=75% capture, 0 false positives). Model it on the 004 spike harness
shape if one exists in git history; otherwise structure it as an integration_test that drives prompts and tallies
captures. WRITE the file only; never execute flutter drive / flutter test integration_test (wipes the device).`,
    'T050:reliability-harness', 'Routing & Tests'),

  () => mk(
    `T039 + T040 + T043 — Audits + spec checklist (docs/verification; no lib code).
- T039: review tool/check_plugin_seam.sh — confirm MemoryRepository stays behind its interface and the gemma seam
  stays the only flutter_gemma importer; no new confinement rule needed. Report findings.
- T040: review tool/check_network_seam.sh + grep the 005 changes to confirm NO embeddings/vector/network path was
  added (SC-014). Report findings.
- T043: write specs/005-memory/checklists/requirements.md — a spec-quality checklist for 005 (mirror an existing
  feature's checklists/requirements.md format).
Do not run the .sh scripts if they invoke flutter; a static read + grep is enough here.`,
    'T039+T040+T043:audit-checklist', 'Routing & Tests'),

  () => mk(
    `T042 — Update the managed Spec-Kit / agent-context section to 005.
FILE: AGENTS.md (and CLAUDE.md if it carries the same managed block) — refresh the "Active feature" / managed Spec-Kit
section from 004 to 005-memory, pointing at specs/005-memory/* artifacts, mirroring how 004 was described. Keep the
prior-features summary. Edit only the managed/active-feature section; do not rewrite unrelated content.`,
    'T042:agent-context', 'Routing & Tests'),
])

// ───────────────────────── Wave 5: Verify, fix, check off ─────────────────────────
phase('Verify')
const verifyReport = await agent(
  SHARED + `

YOU ARE THE FINAL VERIFICATION AGENT. You run serially — you MAY use the toolchain now.
Do all of this, fixing issues as you go:
1. \`dart run build_runner build --delete-conflicting-outputs\` ONLY if any agent changed a drift table / .g.dart
   source (the schema was already generated in T004, so likely NOT needed — skip if no codegen source changed).
2. \`flutter analyze\` — fix EVERY error and warning introduced by this run. Common issues to expect: mismatched
   symbol names between the parallel wiring agents (chat_providers vs chat_controller vs tool_handlers vs
   memory_controller referencing composer/provider/seam names), missing imports, unused imports, signature drift on
   loadModel/startSession, ContextAssembler param threading. Reconcile them to ONE consistent set of names.
3. \`dart format lib test\`.
4. Run the HOST test suite ONLY: \`flutter test test/unit test/widget test/data\`. NEVER run
   \`flutter test integration_test\` (it needs/wipes the device). Fix failing tests — but if a test encodes a
   genuine contract from the specs and the impl is wrong, fix the impl, not the test.
5. Re-run analyze + the host suite until BOTH are green. Iterate as needed.
6. In specs/005-memory/tasks.md, mark every task you can confirm complete with [X] (T012-T043, and T050 if the
   harness file was authored). LEAVE T051 and T052 UNCHECKED — they are on-device walkthroughs/gates that require the
   physical A34 and cannot be run here; note that in your final report.
7. Final report: the analyze result, the test pass/fail counts, any task left incomplete and why, and any follow-up
   the user must do on-device (T051/T052 + running T050 via flutter drive).

If something is fundamentally blocked (e.g. an agent failed to produce a required file), report it clearly rather than
faking green.`,
  { label: 'verify+fix+checkoff', phase: 'Verify', model: M })

return { verify: verifyReport }
