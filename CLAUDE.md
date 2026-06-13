<!-- SPECKIT START -->
## Active feature: 006-web-research

Read the plan and its design artifacts before working on this feature:

- Plan: `specs/006-web-research/plan.md`
- Spec: `specs/006-web-research/spec.md`
- Spike (verified runtime behavior): `specs/006-web-research/spike-findings.md`
- Research (pinned versions/APIs): `specs/006-web-research/research.md`
- Data model: `specs/006-web-research/data-model.md`
- Contracts (seams): `specs/006-web-research/contracts/`
- Quickstart/validation: `specs/006-web-research/quickstart.md`

This feature adds opt-in web research: two new tools `web_search` (Tavily BYOK, top-3 results,
`content` field — never renamed to `snippet`) + `fetch_page` (direct GET to target site +
`HtmlExtractor`, hard-truncated to 2,000 chars tool-result bound) added to the `ToolRegistry` (now
eight tools total: four device + two memory + two web). A **triple gate** controls declaration:
`functionCalling && effectiveWebEnabled && hasValidKey` — tools are structurally absent if any
condition is false, never refused at runtime. The per-conversation `WebAccessOverride` is three-state
(`inherit-global` / `explicitly-on` / `explicitly-off`, stored as nullable TEXT in the conversation
row); the `effectiveWebEnabled` resolver applies it bidirectionally over the global `webAccessEnabled`
flag (default false). Toggling web access mid-session recreates the chat via the 005 `startSession`
pattern (close session first). The BYOK Tavily key is stored in `flutter_secure_storage` (Android
Keystore-backed AES/GCM), is **never** written to SQLite, logs, or model context, and is masked
after initial entry. Drift schemaVersion 5→6 adds two additive columns: `conversations.webAccessOverride`
(nullable TEXT, default NULL) + `app_settings.webAccessEnabled` (BOOL, default false). ALL HTTP and
extraction logic is confined to `lib/infrastructure/network/` behind the `NetworkResearchService`
and `SecureKeyStore` seams; `check_network_seam.sh` + `check_plugin_seam.sh` both stay green.
The full typed error taxonomy (`OfflineError` / `ProviderError` / `KeyInvalidError` /
`RateLimitError` / `FetchDomainError` / `ParseError` / `TimeoutError`) maps to distinct red error
chips; `web_search` chips show `WEB_SEARCH · Tavily`, `fetch_page` chips show `FETCH_PAGE · [domain]`
(names the target website, not Tavily). Tappable source URL chips appear beneath the model's answer.
Web off ⇒ byte-identical pre-006 behavior, zero network. Device validation (A34 reliability
harness, SC-001/SC-002/SC-003/SC-004/SC-013) and the A34 20-prompt harness run (T060–T062) are the
remaining open items.

Prior features: `specs/001-model-download-chat/` (model download + streaming chat, foundation);
`specs/002-image-input-vision/` (single-image input; known issue: image grounding fails at the
native layer on 0.15.3 — vision-specific, tools/audio unaffected); `specs/003-audio-input/`
(voice clips — its capability-gating/seam/migration patterns are the template for 004);
`specs/004-function-calling/` (four-tool static registry, `GemmaService` stream seam, tool chips,
drift v3→v4 — the direct foundation for 005);
`specs/005-memory/` (six-tool registry, `remember_fact`/`forget_fact`, `FactsBlockComposer` as
native `systemInstruction`, drift v4→v5 — the direct foundation for 006).

Stack: Flutter/Dart, Android-first (arm64-v8a, 8 GB baseline). Riverpod 3 (manual Notifier),
drift over app-private SQLite, **flutter_gemma 0.15.3** (LiteRT-LM, Gemma 4 E2B — the
installed/verified version; 0.16.4 is a known model-load regression on the A34, see 003 research
R1; 005/006 spike findings are 0.15.3-specific) behind a single `GemmaService` seam,
background_downloader for the one-time model download, device_info_plus preflight, image_picker +
permission_handler for image input, record + audioplayers for audio input, gpt_markdown for
assistant-reply rendering, battery_plus + android_intent_plus for local tools, http + html +
flutter_secure_storage (all seam-isolated in `lib/infrastructure/network/`) for web research.
Dark-first Material 3 per `.specify/memory/design-system.md`. Governed by `.specify/memory/constitution.md`
(v2.0.0): on-device only, offline-first, plugin-seam testability, opt-in egress with named recipient.
<!-- SPECKIT END -->

## Working in this codebase (durable guide)

This section is hand-authored and feature-independent. The block above (between the SpecKit markers) is auto-regenerated each feature and documents the *current* feature + stack — read it for "what we're building now"; read this for "how this codebase works, always."

GAMMA AI Assistant (`ai_assistant`) is an on-device Gemma 4 E2B chat app: Flutter/Dart, Android-first, offline-first, opt-in network egress. Governed by `.specify/memory/constitution.md` (visual rules in `.specify/memory/design-system.md`).

### Architecture & the dependency rule

Six layers under `lib/`. Dependencies point **inward**; nothing inward imports outward, and **only one file breaks the seam on purpose** (see below). The entrypoint `lib/main.dart` sits at the top level (single `ProviderScope`, `installGemmaLogFilter()` before `runApp`, fonts locked offline via `GoogleFonts.config.allowRuntimeFetching = false`).

- `lib/app/` — shell: `app.dart` (MaterialApp — `GemmaAssistantApp`), `root_gate.dart` (boot decision), `router.dart` (Navigator 1.0 named routes — no go_router), `theme/` (tokens), `widgets/`.
- `lib/core/` — pure data/algorithms, zero plugins: `tools/tool_registry.dart` (the static tool list), `tools/schema_validator.dart` (in-house JSON-schema subset), `model_catalog.dart`, `memory/*_composer.dart`. Exception: `core/platform/device_info_preflight_service.dart` is the one concrete service that lives outside `infrastructure/` (the preflight `device_info_plus` reader; the device-info *tool* reader lives in `infrastructure/tools/`).
- `lib/domain/` — the vocabulary and the seams. `entities/` are pure `@immutable` value types (hand-rolled `==`/`Object.hash`, no freezed/equatable; no Flutter/Drift/plugin imports — ever). `services/` + `repositories/` are `abstract interface class` declarations only.
- `lib/data/` — Drift/SQLite persistence: `db/` (tables, generated code, DAOs), `repositories/` (map `*Row` ↔ domain entities), `model/` (model downloader), `images/` + `audio/` (file stores). Implements the repository seams.
- `lib/infrastructure/` — concrete plugin-touching adapters, one subsystem per dir: `gemma/`, `media/`, `tools/`, `network/`. Each implements a `lib/domain/services/` interface.
- `lib/features/` — Riverpod controllers + widgets per surface: `chat/` (the thick one), `settings/`, `onboarding/`, `download/`, `history/`. Depends on `domain` interfaces, never on `infrastructure` concretes…

…**except `lib/features/chat/tool_handler_providers.dart`**, the single composition root. It is the *only* feature file allowed to import `lib/infrastructure/` and instantiate concretes into providers. If you wire a new seam anywhere else, the guard scripts fail. (`gemmaServiceProvider` is *declared* in `infrastructure/gemma/flutter_gemma_service.dart` and imported directly by chat code — but only the provider, never the plugin types.)

Seam pairing to remember:
- `GemmaService` → `infrastructure/gemma/flutter_gemma_service.dart`
- `NetworkResearchService` → `infrastructure/network/tavily_network_research_service.dart`
- `SecureKeyStore` → `infrastructure/network/flutter_secure_key_store.dart`
- `ConversationRepository` / `MemoryRepository` → `data/repositories/drift_*.dart`
- media/device-tool seams → `infrastructure/media/` and `infrastructure/tools/`

### Seam discipline (Constitution I & VII)

Domain defines abstractions; infrastructure implements; **plugins never leak past infrastructure**. The seam THROWS typed errors; the caller (handler/controller) CATCHES and maps to UI. Two grep-based CI guards enforce this and **must stay green**:

```
bash tool/check_plugin_seam.sh      # plugins confined to their seam dir
bash tool/check_network_seam.sh     # network/privacy isolation
```

Confinement map (from `check_plugin_seam.sh`):
- `flutter_gemma` → `lib/infrastructure/gemma/` only
- `image_picker` / `permission_handler` / `record` / `audioplayers` → `lib/infrastructure/media/` only
- `battery_plus` / `android_intent_plus` → `lib/infrastructure/tools/` only
- `http` / `flutter_secure_storage` / `html` → `lib/infrastructure/network/` only

`check_network_seam.sh` additionally forbids raw socket/HTTP primitives (and `dio`/`grpc`/`web_socket_channel`/etc.) anywhere outside `lib/data/model/background_model_downloader.dart` + `lib/infrastructure/network/`. The two only allowed egress paths in the whole app are the model download and the network research seam. (`google_fonts` is permitted because runtime fetching is disabled in `lib/main.dart`.) When you add a new plugin, add its seam rule to `check_plugin_seam.sh` in the same change.

### Essential commands

```
flutter pub get
dart run build_runner build          # codegen for Drift — do NOT pass --delete-conflicting-outputs (removed in this build_runner)
flutter analyze --fatal-infos --fatal-warnings
dart format .                        # advisory only — never blocks CI
flutter test                         # all host-side unit + widget tests
flutter test --coverage
bash tool/verify.sh                  # full local CI mirror (see gates below)
SKIP_BUILD=1 bash tool/verify.sh     # same, minus the slow APK build
```

`tool/verify.sh` is the authoritative local CI mirror and runs, in order: (1) `flutter pub get`; (2) `pubspec.lock` clean (`git diff --exit-code pubspec.lock`); (3) `flutter analyze --fatal-infos --fatal-warnings`; (4) `check_plugin_seam.sh`; (5) `check_network_seam.sh`; (6) `build_runner` codegen up-to-date (scoped to `*.g.dart`/`*.drift.dart`/`*.freezed.dart`); (7) `flutter test --coverage`; (8) `dart format` (advisory, non-blocking); (9) debug arm64 APK build unless `SKIP_BUILD=1`. Always commit `pubspec.lock` alongside any `pubspec.yaml` change or CI fails at gate 2.

### Drift / database discipline

- Schema lives only in `lib/data/db/tables.dart`. `schemaVersion` (currently **6**) is the getter in `lib/data/db/app_database.dart`. Generated `app_database.g.dart` is a `part` file — never hand-edit; regenerate with `build_runner` and commit it.
- Bumps are **additive only** — `m.addColumn` (nullable or `withDefault(...)`) or new tables; no DROP/RENAME. `onUpgrade` uses non-exclusive `if (from < N)` guards so a multi-version upgrade runs every block in sequence.
- Every bump needs (a) a migration step, (b) a new `test/data/migration_v(N-1)_to_vN_test.dart`, and (c) the **test-seed gotcha** fix: any migration that touches a table already present in earlier schemas (notably `app_settings_table` or `conversations`) means **all older `migration_v*_test.dart` seeds** must add the new column to their raw-SQL `CREATE`, **and every migration test's `expect(db.schemaVersion, N)` must be bumped to the new current version** (the asserts read the *current* max, not that test's target). Miss this and untouched older tests break.
- A `@TableIndex` is NOT created by `createTable()` during migration — call `m.createIndex(idxMemoriesActive)` explicitly when the table is first introduced via a migration.
- Non-default options that are load-bearing: `storeDateTimeAsText: true` (timestamps are ISO-8601 UTC TEXT, not Unix ints — always persist `DateTime.now().toUtc()`), and `PRAGMA foreign_keys = ON` in `beforeOpen` (FK cascades silently fail without it). DB name is `gemma_assistant`. Tests use `NativeDatabase.memory()` (fresh schema) or `NativeDatabase(File(...))` (migration proofs).

### Device / integration testing rule

**NEVER run `flutter test integration_test/...`** — it uninstalls the app and wipes the ~2.4 GB on-device model and the SQLite DB. For on-device runs use:

```
flutter drive --driver=test_driver/integration_test.dart --target=integration_test/<harness>.dart -d <device-id>
flutter run -d <device-id>          # manual walkthroughs
```

The verified baseline device is a Samsung Galaxy A34 (Mali-G68; Impeller is disabled in `AndroidManifest.xml` because of it). It can appear **twice** in `adb devices`, so pass `-d` explicitly. For long drives, raise the screen timeout first (`adb shell svc power stayon true`). The model lives in public storage (`/storage/emulated/0/AiAssistant/models/`, survives reinstall, needs `MANAGE_EXTERNAL_STORAGE` re-granted each install) — you can `adb push` it there to skip the download.

### Riverpod 3 conventions

- **Manual `Notifier<T>`** subclasses only — never `StateNotifier`/`ChangeNotifier`. Provider declared at the bottom of the file: `final fooProvider = NotifierProvider<FooController, FooState>(FooController.new);`.
- **Controller-per-feature**, and most controllers are `Notifier<void>` holding no data — UI reads state from other providers (repositories, settings streams); the controller only exposes async mutating methods.
- State classes are `@immutable` with `copyWith`; for nullable fields that need explicit null-setting, use a `clearXxx: bool` flag (plain `copyWith(field: null)` is ignored by the `??` pattern — see `attachment_controller.dart` / `recording_controller.dart` / `chat_controller.dart`).
- Infrastructure seams are `Provider<Interface>` returning concretes; override them in tests. The `gemmaServiceProvider` is intentionally non-autoDispose (don't thrash a 2.4 GB model on rebuilds).
- The Riverpod 3 `Override` type lives in `package:flutter_riverpod/misc.dart` (`import 'package:flutter_riverpod/misc.dart' show Override;`), not the main export.

### flutter_gemma pin

- Stay on **0.15.3** (`^0.15.0`). **0.16.4 is a known model-LOAD regression on the A34** (capabilities flip to text-only) — do not bump without a full on-device verification session. `flutter_riverpod` is pinned to exact `3.3.1` (not a caret) on purpose.
- All plugin contact happens behind the single `GemmaService` seam (`lib/infrastructure/gemma/flutter_gemma_service.dart`). Known device quirks live there: image grounding is broken at the native layer on 0.15.3 (vision-specific; the Dart plumbing is correct — don't "fix" the seam); audio + function-calling work. `installGemmaLogFilter()` must run from `main()` or 0.15.3 floods logs per token.

### Testing conventions

- Layout: `test/unit/{core,data,domain,features,infrastructure}/` (plus a number of top-level `test/unit/*_test.dart` files), `test/widget/`, migration proofs in `test/data/migration_v*_test.dart`, shared fakes + harness in `test/helpers/`. **No test imports a real plugin** — everything goes through fakes.
- `makeContainer()` in `test/helpers/container_harness.dart` is the universal `ProviderContainer` factory (in-memory Drift + `FakeSecureKeyStore` + `FakeNetworkResearchService` by default). Inject configured fakes via its **named params** (e.g. `secureKeyStore:`, `networkResearch:`), NOT by also adding them to the `overrides:` list — doing both triggers Riverpod's duplicate-override assertion. Every domain interface has a `test/helpers/fake_*.dart`.
- Fakes enforce real seam contracts, not passthrough: e.g. `FakeGemmaService` throws `StateError` for `loadModel(tools: nonEmpty)` when `functionCalling == false`, for `resumeWithToolResult()` outside an in-flight tool turn, and for `startSession()` before `loadModel`. It defaults `capabilitiesData` to image+audio with **no** functionCalling — pass `capabilitiesData: const ModelCapabilities(functionCalling: true)` for tool tests. Use `scriptedDeltas` (text) / `scriptedEvents` + `resumeEvents` (tool turns) to drive streams.
- **Widget-test async pattern** (hang-avoidance): wrap in `UncontrolledProviderScope(container: makeContainer(), child: MaterialApp(...))` — never `ProviderScope(overrides:)`. Drive controller calls with `unawaited(controller.send(...))` then explicit `tester.pump()` steps; **never** bare-`await` a controller call and **never** `pumpAndSettle()` over fake streams or real file I/O (10-minute hang). Dialogs that must be testable use `animationStyle: AnimationStyle.noAnimation`. Teardown order matters: dispose the `ProviderContainer` BEFORE closing any `StreamController` a provider subscribes to. For file deletes in controllers use the injectable `tempFileDeleterProvider`, not `File(...).delete()`.

### Spec-driven workflow

Features follow Spec-Kit: **specify → plan → tasks → implement**, each producing canonical artifacts under `specs/NNN-feature-name/`: `spec.md`, `plan.md` (with a Constitution Check gate that must pass before Phase 0 and after Phase 1), `spike-findings.md` (verified on-device behavior), `research.md` (pinned versions), `data-model.md`, `contracts/`, `quickstart.md`, `tasks.md`, `checklists/`, and (if used) `fixtures/`. **Before coding on the active feature, read its `plan.md`, `spike-findings.md`, and `research.md`** (the SpecKit block above links them). Branches are `NNN-feature-name` (zero-padded). A `spike-harness/` is `DO NOT SHIP` and removed before merge; the shipped reliability harness lives in `integration_test/`. Specs 001–006 reuse the same layer structure — new features extend existing files; add an `infrastructure/` subdir only for a genuinely new seam category.

### Where things live / common gotchas

- **Tool system**: registry = `lib/core/tools/tool_registry.dart` (static lists — **eight tools**: four device + two memory + two web; names are snake_case, stable, persisted + replayed — renaming breaks replay). Handlers + all seam wiring = `lib/features/chat/tool_handler_providers.dart`. Dispatcher = `lib/domain/services/tool_dispatcher.dart` (concrete, **never throws** — catches any handler exception and always returns a sealed `ToolOutcome`). Adding a tool means updating the registry, the handler map (must stay congruent — tested), and `tool_registry_test.dart` counts.
- **Settings & reactive booleans** (`themeMode`, `memoryEnabled`, `webAccessEnabled`) live in `lib/data/repositories/settings_repository.dart`, not under `lib/app/`. Single-row table (`id=1`), lazy `_ensureRow()`.
- **System instruction** is composed in one place: `lib/features/chat/session_instruction.dart` (`composeSessionInstruction` pure; `refreshSessionInstruction` reads live state → `GemmaService.startSession`). Don't duplicate gating in controllers.
- **Session vs. instruction refresh**: changing the *system instruction* (e.g. memory toggle) → `refreshSessionInstruction` (calls `startSession`, no-op if model not loaded). Changing the *declared tool list* → you must `ref.invalidate(modelSessionProvider)` and await it, because tools are baked at `loadModel` time and `startSession` reuses them. `startSession()` must close the prior native session first or the plugin returns a stale cached session.
- **Design tokens**: never hardcode hex/spacing/font strings. Read colors via `Theme.of(context).extension<AppColors>()!`; use `AppSpacing.*` and `AppText.*` (`AppText.spec()` uppercases mono labels; `AppText.dotMatrix()` is the only path to the dot-matrix face). Accent red `#D71921` is for active/destructive/recording/error states ONLY — never body text or primary buttons (white-on-black / black-on-white). 48dp min touch targets. Use `withValues(alpha:)` not the deprecated `withOpacity`.
- **Microcopy** is lowercase throughout (the all-caps look comes from `AppText.spec()` styling, not the source string).
- **Routing** is Navigator 1.0: add a `const` to `AppRoutes` and a `case` in `AppRouter.onGenerateRoute`. An unregistered/typo'd route silently renders a "coming soon" skeleton — no runtime error.
- **Lint** requires `always_use_package_imports` (no relative imports), single quotes, trailing commas, const-preference, `unawaited_futures`, `avoid_print`.
