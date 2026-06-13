# Clean-Code Audit — GAMMA AI Assistant

**Scope:** all 109 non-generated Dart files under `lib/` (~13,120 LOC)
**Standard:** `clean-code-guard` skill (Clean Code · SOLID · DRY/KISS/YAGNI · 14 LLM failure modes) in **review mode**
**Method:** 13 parallel review agents (one per partition) → adversarial per-finding verification (refute-by-default) → cross-cutting synthesis
**Date:** 2026-06-13 · **Branch:** `clean-code`

> This is an **audit** (report only). No production code was modified. Generated files (`*.g.dart`, `*.drift.dart`) and tests were out of scope.

---

## Verdict: `minor-cleanup`

The GAMMA codebase is in fundamentally healthy shape. Across the whole-codebase audit, **zero Critical findings** and **zero correctness, security, or data-integrity bugs** were confirmed. Verified issues cluster into two well-understood, low-risk maintainability categories:

1. **Three core hot-path methods have grown long and multi-concern** — `send()` in `chat_controller.dart` (~170 lines, 5+ concerns, 4 catch arms), `generate()` in `flutter_gemma_service.dart` (~134 lines, 8 concerns), and `download()` in `background_model_downloader.dart` (~166 lines, depth-5 switch-in-switch). None are buggy; each is a readability burden that pure behavior-preserving extraction would relieve.
2. **The same knowledge is copy-pasted across files** — six distinct DRY violations (byte-formatting, section-header widget, map equality/hash helpers, display-order comparators, plugin-response→event mapping). The most consequential is the duplicated `ToolCallRequested` decoding in `flutter_gemma_service.dart`, where a future FR-024 change must touch both branches or they silently diverge.

The remaining confirmed items are Nit-tier documentation-accuracy and dead-code cleanups — including two docstrings that overstate behavior and contradict the codebase's own documented session-vs-instruction rule. One latent robustness gap sits above the cosmetic tier: `drift_memory_repository.dart`'s `upsert()` is a non-atomic multi-statement read-modify-write with no transaction. With 29 further lower-priority nits, the codebase needs only **minor cleanup, not structural rework**.

### Tally

| Severity | Count | Notes |
|---|---:|---|
| **Critical** | **0** | No security/correctness/data-loss/swallowed-exception/mock-fixture defects |
| **Important** | **5** | 3 long-function + 1 DRY (divergence risk) + 1 non-atomic upsert |
| **Nit (verified)** | **9** | Findings the verifier confirmed but downgraded from Important |
| **Nit (triaged)** | **29** | Lower-priority items surfaced in review |
| **Refuted on verification** | **0** | — |
| **Downgraded on verification** | **9** | Verifiers actively re-rated, not rubber-stamped |

All 13 partitions completed; every Important finding survived an independent refute-default verification pass that re-opened the file.

---

## Cross-cutting themes

1. **Long, multi-concern functions on core hot paths** *(Important)* — `chat_controller.dart`, `flutter_gemma_service.dart`, `background_model_downloader.dart`. Apply behavior-preserving extraction so each parent method reads as wire-up + delegation at one abstraction level.
2. **Duplicated knowledge across files (DRY)** *(Important)* — `flutter_gemma_service.dart`, `download_screen.dart`, `settings_screen.dart`, `memory_screen.dart`, `web_research_screen.dart`, `message.dart`, `chat_turn.dart`, `generation_event.dart`, `facts_block_composer.dart`. Consolidate each rule to a single home.
3. **Docstrings overstate behavior the code does not uphold** *(Nit)* — `web_toggle_button.dart`, `web_research_controller.dart`. Two contradict the codebase's own documented invariants (the triple gate; the session-vs-instruction rule).
4. **Dead / discarded code** *(Nit)* — `tavily_network_research_service.dart` (a socket-error classifier whose result is thrown away), `memory_controller.dart` (`add` has no production caller — but **is** test-pinned; keep, don't delete).
5. **Code/contract drift** *(Nit)* — `FetchResult.url` returns the *requested* URL while `fetch_result.dart` documents it as the *post-redirect final* URL. The obvious fix is a trap (`http 1.x` `get()` can't recover the post-redirect URL); fix the doc or rewrite with `Request/send`.

---

## Prioritized actions

| # | Effort | Action |
|---|:--:|---|
| 1 | **S** | Extract the duplicated plugin-response→`ToolCallRequested` decoding in `flutter_gemma_service.dart` into one `_toToolCallEvent(InferenceResponse)` mapper used by both `generate()` and `resumeWithToolResult()`. *Highest-value DRY fix — the one duplication with real divergence risk (FR-024).* |
| 2 | **M** | Refactor the three long hot-path methods (`send()`, `generate()`, `download()`) by hoisting cohesive blocks into named private helpers. No observable-behavior change; rely on the existing test suite for parity. |
| 3 | **S** | Wrap `drift_memory_repository.dart` `upsert()` (dedupe/supersede decision + insert + `_enforceCap` loop) in a single `_db.transaction(() async { … })`. *Removes the only confirmed latent robustness gap: partial-state-on-throw.* |
| 4 | **M** | Consolidate the small cross-file duplications: `formatBytes(int)` in `lib/core/`, a shared `SettingsSectionHeader` widget, a pure-Dart `mapEquals`/`mapHash` util (keep domain-pure), and a private `_displayOrder` comparator in `facts_block_composer.dart`. |
| 5 | **S** | Fix three doc/contract-accuracy items: the `web_toggle_button.dart` and `web_research_controller.dart` `saveKey` docstrings, and reconcile `FetchResult.url` with its entity doc (prefer re-documenting as "requested URL"; avoid the `response.request?.url` no-op trap). |
| 6 | **S** | Collapse the dead socket-error classifier in `tavily_network_research_service.dart` to a direct `on SocketException { throw const OfflineError(); }`. Leave `MemoryController.add` in place as a tested, documented manual-add seam. |

---

## Critical findings

**None.** No security, correctness, data-loss, swallowed-exception, or hardcoded-success/mock-fixture defects were confirmed anywhere in `lib/`.

---

## Important findings

### P01-1 — `send()` is a ~170-line multi-concern function
`lib/features/chat/chat_controller.dart:154-325` · *Functions small / one thing (imp. 2); long multi-concern function (E8)*

`send()` interleaves: empty-input guard; image persist+read+reject (175-200); audio persist+read+reject (203-222); lazy conversation create (224-231); `appendUserMessage`; sliding-window history assembly (242-248); `beginAssistantMessage` + state mutation + composer clears (250-262); generate/pump/tool-turn dispatch (266-297); and four distinct catch arms with per-arm finalize logic (298-324).
**Fix:** Extract the two near-identical attachment branches into `_persistImage` / `_persistAudio` helpers and lift the lazy-create + `appendUserMessage` prelude into `_beginUserTurn`. Behavior-preserving; no contract change.
*Verifier (confirmed): every cited sub-range is accurate; the catch arms here are NOT the blessed `tool_dispatcher` pattern and are in-scope; no project exception covers function length.*

### P05-2 — Duplicated plugin-response → `ToolCallRequested` mapping
`lib/infrastructure/gemma/flutter_gemma_service.dart:335-357 & 436-453` · *DRY duplicated knowledge (imp. 11); duplicate-instead-of-reuse (E5)*

The decoding of `FunctionCallResponse` / `ParallelFunctionCallResponse` into a domain `ToolCallRequested` (including the parallel-call collapse to `first` + `extraCallCount: calls.length - 1`) is written twice — in `generate()` and near-verbatim in `resumeWithToolResult()`. One rule, two homes; a future FR-024 change must edit both or they silently diverge.
**Fix:** Extract `ToolCallRequested _toToolCallEvent(InferenceResponse)` (handle both response types, return null for text) and call it from both loops. The `generate()`-only side effects (`sawToolCall = true; _awaitingToolResult = true;`) stay at the call sites.
*Verifier (confirmed): code verbatim at both locations; the only differing parts are side effects, which the fix correctly leaves in place.*

### P05-3 — `generate()` is a ~134-line multi-concern function across several abstraction levels
`lib/infrastructure/gemma/flutter_gemma_service.dart:271-404` · *Functions small / one level of abstraction (imp. 2); E8*

One body performs: four argument-contract gates (280-298); image-involvement detection (300-301); warm-session fingerprint compute+match (303-312); replay-vs-warm-append decision (317-324); the streaming loop with leak-filter dispatch and three response branches (328-358); false-positive flush (360-367); warm-fingerprint commit (371-387); media-specific error remap (388-402).
**Fix:** Lift cohesive blocks into `_assertGenerateContract(image, audio)` and `_commitWarmFingerprints(...)`, and reuse the P05-2 mapper for the response branches. Pure refactor — preserve observable streaming behavior.
*Verifier (confirmed): all eight sub-concerns exist as described; central method of the core inference seam, so Important (not downgraded). Correct, tested, well-commented — a structure issue, not a bug.*

### P07-1 — `upsert()` performs a non-atomic read-modify-write with no transaction
`lib/data/repositories/drift_memory_repository.dart:92-162, 166-184` · *Partial-state risk (E11) + correctness*

`upsert()` runs as independent auto-committed statements: read active same-category rows → UPDATE or INSERT → `_enforceCap()` (which re-reads all actives and issues one UPDATE per over-cap row in a loop) → re-read the inserted row. If any statement after the INSERT throws (e.g. mid-loop in `_enforceCap`), the table is left partially mutated — fact inserted but cap unenforced, or some-but-not-all over-cap rows deactivated. (Verified: no `_db.transaction`/`batch` anywhere in `lib/`.)
**Fix:** Wrap the whole `upsert` body in a single `_db.transaction(() async { … })` so the read-decide-write sequence is atomic.
*Verifier (confirmed): single-user/serial usage blunts the stale-snapshot race, but partial-state-on-throw is a genuine latent defect; cheap fix → Important.*

### P08-1 — `download()` is a ~166-line function nesting 5 closures and a switch-in-switch
`lib/data/model/background_model_downloader.dart:86-252` · *Functions small / one level of abstraction (imp. 2, 13); E8*

`download(String url)` declares four nested closures (`emit`, `armStallTimer`, `finish`, `start`) and inside `start()` a listen callback wraps an outer `switch (update)` around an inner `switch (update.status)` — depth 5 (the stated ceiling) at `case TaskStatus.complete:`. The method mixes stream-controller plumbing, stall-timer arming, task construction, status mapping, and install finalization.
**Fix:** Hoist `_progressFromUpdate(TaskProgressUpdate)` and `_handleStatus(TaskStatusUpdate, finish, emit)` so `download()` reads as wire-up + delegation, lowering nesting below the depth-5 edge.
*Verifier (confirmed): every cited line accurate; the file's only project exception concerns network-egress confinement, not function length.*

---

## Verified findings downgraded to Nit

These passed verification (the code exists and the principle applies) but were re-rated below Important.

| ID | File:line | Issue | Fix |
|---|---|---|---|
| P03-1 | `web_toggle_button.dart:19-21` | Docstring claims a "Tavily key is stored" visibility precondition never enforced (visibility is gated on `functionCalling` only) | Gate on a key-presence provider **or** correct the docstring to match the triple gate |
| P06-1 | `tavily_network_research_service.dart:200-214` | Dead branching: `_isNoRouteErrno` result discarded — both branches throw the same `OfflineError()` | Replace with a direct `on SocketException { throw const OfflineError(); }` (matching `fetchPage`) |
| P06-3 | `tavily_network_research_service.dart:121-167` | `FetchResult.url` set to the *original* request URL, contradicting the entity's "final URL after redirects" doc | Re-document as "requested URL" **or** rewrite with `Request/send` to read `BaseResponseWithUrl.url` |
| P09-1 | `memory_controller.dart:39-46` | `MemoryController.add` has no production caller | **Keep** — it is exercised by ~14 tests pinning a real contract (documented manual-add seam awaiting UI) |
| P09-2 | `web_research_controller.dart:36-38` | `saveKey` doc claims web tools "become available" via `_refreshSession`, but a bare `startSession` cannot re-declare tools | Mirror `clearKey`'s correct caveat: real re-declaration happens at next conversation open via `modelSessionProvider` |
| P09-3 | `settings_screen.dart:185-209` | `_SectionHeader` duplicated byte-for-byte across 3 settings screens | Extract a shared `SettingsSectionHeader` under `lib/features/settings/widgets/` |
| P10-1 | `download_screen.dart:34-45` | `_formatBytes` duplicated verbatim with `settings_screen.dart` | Extract one `formatBytes(int)` into `lib/core/` |
| P11-1 | `facts_block_composer.dart:43-47, 81-85` | Display-order comparator (category asc, updatedAt desc) duplicated verbatim | Extract `static int _displayOrder(Memory a, Memory b)` and `..sort(_displayOrder)` at both sites |
| P12-2 | `message.dart:170-186` (+ `chat_turn.dart`, `generation_event.dart`) | `_mapEquals`/`_mapHash` byte-identical across 3 entity files | Hoist a single pure-Dart `mapEquals`/`mapHash` util; keep domain-pure |

---

## Lower-priority nits (29)

**Chat (P01–P04)**
- `chat_controller.dart:173-222` — image/audio attachment branches duplicate the persist/read/reject shape (borderline; types differ).
- `chat_controller.dart:464-468` — resume tool args persisted un-normalized vs first-call (display-only).
- `chat_controller.dart:664-724` — `_assembleHistory` mixes byte-loading with reserve-flag computation.
- `attachment_controller.dart:107,183` & `chat_screen.dart:48-49` — fire-and-forget Futures not marked `unawaited(...)` (inconsistent with file convention).
- `recording_controller.dart:257-329` — repeated stop/delete/reset cleanup across five methods (honest duplication; extract only the identical body, if any).
- `web_toggle_button.dart:71-75` — comment says "Disabled until thread exists" but `onPressed` is unconditional.
- `tool_chip.dart:158-161` — args summary stringifies values with no length cap (oversized line for `fetch_page` URLs).
- `tool_handler_providers.dart:160-163,199-202` — valid-key guard duplicated across both web handlers.
- `tool_registry.dart:184,211` — `additionalProperties:false` declared on 2 of 8 schemas but the validator is unconditionally strict (inert).

**Infrastructure (P05–P06, P08)**
- `flutter_gemma_service.dart:457-460` — dead `try/catch` in `resumeWithToolResult` (both branches rethrow).
- `tavily_network_research_service.dart:70-78` — `search()` SocketException shape inconsistent with `fetchPage` (inline the throw).
- `html_extractor.dart:278-290` — truncation marker reports an inaccurate, mislabeled count.
- `html_extractor.dart:121-133` — script/style/noscript stripped twice ("belt + suspenders").
- `html_extractor.dart:70-92` — misleading `final copy = mwContent;` alias (not a copy; mutates DOM in place).
- `device_info_tool_service.dart:78-87` — three identical catch bodies for the StatFs probe.
- `background_model_downloader.dart:150-178` — completed progress can report `downloadedBytes: 0` when server omits Content-Length.

**Data / Persistence (P07)**
- `drift_memory_repository.dart:198-208` — `editFact` returns void and silently no-ops on a missing/inactive id (cf. `softDeleteById`'s bool).

**Settings / Onboarding / History (P09–P10)**
- `memory_screen.dart:286-405` — `_showEditDialog` is a ~120-line multi-concern function (extract `_EditFactDialog`).
- `download_controller.dart:53-62` — `copyWith` silently drops `error` instead of preserving it (use the `clearError` idiom).
- `history_controller.dart:29-31` — `newConversation()` drops a Future without `unawaited()` (siblings wrap it).
- `license_screen.dart:75` — pointless self-interpolation duplicating `ModelCatalog.displayName`.

**App shell / Core / Domain (P11–P13)**
- `facts_block_composer.dart:55-62` — O(n²) string builds in the char-cap loop (acceptable; n≤20, no change required).
- `facts_block_composer.dart:51` — redundant explicit type annotation (use `var`).
- `conversation.dart:37` — misplaced/dead `// ignore: avoid_positional_boolean_parameters` on a named param.
- `audio_input.dart:13-22` (+ `image_input.dart`) — `@immutable` value types omit `==`/`hashCode` (intentional? add a one-line note).
- `tool_spec.dart:5` — doc says "all four tools" but the registry is now eight.
- `model_capabilities.dart:5-7,26` — doc describes an obsolete "text-only slice" scope.
- `audio_recorder_service.dart:32-47` — `RecordedAudio` DTO missing `@immutable` that sibling `PickedImage` carries.

---

## What's good (highlights)

- **Seam discipline is exemplary throughout.** Every plugin (`flutter_gemma`, `http`/`html`/`flutter_secure_storage`, media, device tools) is confined to its one adapter behind a domain interface, with headers naming the confining guard script. Domain interfaces are plugin-free `abstract interface class` declarations.
- **Error handling follows the contract, not catch-all reflexes.** `send()` catches specific recoverable types first; `tool_dispatcher.dispatch` is an exemplary never-throws pipeline with one documented catch fulfilling its contract; seams throw typed errors and callers map them to distinct UI chips.
- **Privacy contract is honored in code.** The Tavily key never escapes: `write()` re-throws sanitized, the UI keeps only a `_hasKey` bool, `clearKey` forces `webAccessEnabled=false`, and `LeakFilter` guarantees byte-parity when tools are off.
- **Performance subtleties are deliberate and commented (the WHY).** `cacheWidth`/`cacheHeight` from device pixel ratio, `MediaQuery.sizeOf` over `.of` to avoid keyboard-inset rebuilds, `jumpTo` over `animateTo`, warm-session fingerprinting.
- **Migration discipline matches the documented rules** — non-exclusive `if (from < N)` guards, additive-only, explicit `m.createIndex` for `@TableIndex`, deterministic ordering with id tiebreaks everywhere a stream is produced.
- **Domain modeling is strong** — sealed hierarchies (`ToolOutcome`, `GenerationEvent`, `UpsertResult`) give compiler-checked exhaustive `switch`; field docs capture invariants (the XOR media rule on `Message`, the `content`-not-`snippet` note, null-IS-inherit on `WebAccessOverride`).

---

## Methodology

Each of the 13 review agents carried the **full embedded `clean-code-guard` standard** (23 imperatives + 14 LLM failure modes + the A–E review walk) plus a **project-context block** of intentional patterns so deliberate architecture was not flagged: the single composition-root seam break (`tool_handler_providers.dart`), `tool_dispatcher` never-throwing by design, the `clearXxx` `copyWith` idiom, hand-rolled entity equality, snake_case persisted tool names, `withValues(alpha:)`, etc.

Every Critical/Important finding then went through an **independent, refute-by-default verifier** that re-opened the file to confirm the quoted code exists and the principle genuinely applies (and could downgrade severity). Result: **0 refuted, 9 downgraded** — evidence the verification pass did real filtering rather than rubber-stamping. A final synthesis agent derived the cross-cutting themes and prioritized actions over the confirmed set.

### Partition map

| P | Area | Files | Confirmed | Nits |
|---|---|---:|---:|---:|
| P01 | Chat: core controller & providers | 4 | 1 | 3 |
| P02 | Chat: screen, attachments, recording | 3 | 0 | 3 |
| P03 | Chat: widgets | 8 | 1 | 2 |
| P04 | Tooling: registry, dispatch, handlers, schema | 4 | 0 | 2 |
| P05 | Gemma seam | 4 | 2 | 1 |
| P06 | Network / web-research seam | 7 | 2 | 4 |
| P07 | Data: persistence (drift, repos, db) | 9 | 1 | 1 |
| P08 | Data stores, model download, infra media/tools | 11 | 1 | 2 |
| P09 | Settings & web-research UI | 6 | 3 | 1 |
| P10 | Onboarding, download, history | 8 | 1 | 3 |
| P11 | App shell, theme, core utilities, memory composers | 16 | 1 | 2 |
| P12 | Domain entities (value types) | 19 | 1 | 4 |
| P13 | Domain service interfaces (seams) | 10 | 0 | 1 |
| | **Total** | **109** | **14** | **29** |
