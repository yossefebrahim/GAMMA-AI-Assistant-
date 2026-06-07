# Phase 0 Research: Model Download & Chat

**Feature**: `001-model-download-chat` | **Date**: 2026-06-07

This document resolves the technology unknowns for the plan. The stack is fixed by the
constitution (Flutter/Dart, Riverpod, SQLite, flutter_gemma, Gemma 4 E2B); research pinned the
exact packages, APIs, and patterns. Findings were verified against pub.dev, package changelogs,
official docs, and source as of June 2026.

## Pinned dependencies

| Concern | Package | Version | Notes |
|---------|---------|---------|-------|
| Model runtime | `flutter_gemma` | `0.16.4` | LiteRT-LM/MediaPipe; `ModelType.gemma4` + `.litertlm` added 0.13–0.14.1 |
| Model download | `background_downloader` | `^9.5.5` | Native foreground service; requires Kotlin 2.1.0+ |
| Persistence | `drift` + `drift_flutter` + `drift_dev` | `2.33.0` / `0.3.0` / `2.33.0` | Reactive SQLite; `sqlite3_flutter_libs` |
| Device preflight | `device_info_plus` | `>= 11.4.0` (latest `13.1.0`) | RAM fields added 11.4.0; pin highest SDK-compatible |
| State | `flutter_riverpod` | `3.3.1` | Code-gen optional (no build_runner required) |
| Paths | `path_provider` | `2.1.5` | App-private documents dir |
| Fonts | `google_fonts` (offline mode) | latest | `allowRuntimeFetching = false`; or bundle TTFs directly |
| Dot-matrix font | MatrixSans (asset) | — | SIL OFL 1.1; ship `OFL.txt`, register via `LicenseRegistry` |

---

## R1 — flutter_gemma model & chat API

**Decision**: Use `flutter_gemma 0.16.4`, committing to the **modern `FlutterGemma` builder
API** (`installModel(...).fromFile(path).install()` + `getActiveModel(...)`), isolated entirely
behind one `GemmaService` interface that exposes `Stream<String>` token deltas and `Future`
lifecycle calls. Use the higher-level **`InferenceChat`** (not the low-level
`InferenceModelSession`) because it manages multi-turn history and chat templating.

**Rationale**: The plugin ships two co-existing surfaces (legacy `FlutterGemmaPlugin.instance` +
`ModelFileManager`, and the modern `FlutterGemma` facade). Both produce an `InferenceModel`; the
modern facade adds first-class single-active-model management (`getActiveModel`, `hasActiveModel`,
`reset`). `InferenceChat` keeps turn history and emits a `Stream<ModelResponse>` whose subtypes
(`TextResponse.token`, `ThinkingResponse.content`, `FunctionCallResponse`) let us map to a clean
text-delta stream and ignore non-text modalities in this slice. Confining all of this to
`infrastructure/gemma/` keeps domain/presentation free of every plugin symbol (Principle VII).

**Key API surface** (wrapped, never leaked):
- Load: `FlutterGemma.installModel(modelType: ModelType.gemma4, fileType: ModelFileType.litertlm).fromFile(absPath).install()` → `FlutterGemma.getActiveModel(maxTokens: 2048, preferredBackend: PreferredBackend.gpu)`.
- Chat: `model.createChat(systemInstruction: ...)` → `InferenceChat`.
- Turn: `chat.addQueryChunk(Message.text(text:.., isUser:true))` then `chat.generateChatResponseAsync()` (`Stream<ModelResponse>`).
- Stop: `chat.stopGeneration()` — already-emitted text remains; the stream completes. Also cancel the Dart `StreamSubscription`.
- Release: `chat.close()` then `model.close()` (frees ~2.4 GB). Close the old model before loading a new one.
- Capabilities (data): `supportImage`, `supportAudio`, `supportsFunctionCalls`, `isThinking`, `modelType` — read as a value object.
- History restore: replay persisted turns via `clearHistory(replayHistory: [...])` / re-adding chunks.

**Alternatives rejected**: legacy `ModelFileManager`/`createModel` path (works but maintainer
favors the modern facade — do not mix); low-level `InferenceModelSession` (no turn history —
would hand-roll templating); calling the plugin from notifiers/widgets (breaks testability);
bundling the 2.4 GB model as an asset (bloats the APK, violates one-time-download).

**Risks carried forward**:
- `InferenceModel` generated class page 404'd during research; verify exact member names
  (`supportImage` vs `supportsImage`, `getResponseAsync` vs `generateChatResponseAsync`) against
  the locked `0.16.4` via `dart doc`/IDE before coding.
- **`ModelFileType.litertlm` discrepancy**: R1/R2 report a dedicated `ModelFileType.litertlm`
  enum value (added with Gemma 4 support in 0.13.0); R6 saw only `.task`/`.binary` and suspects
  `.litertlm` routes through `.task`. **Verify the enum on the installed `0.16.4` before wiring.**
- GPU backend may OOM/be unavailable on some 8 GB devices — provide a CPU fallback and handle
  backend-init failure.
- Single-active-model is the caller's responsibility on the legacy path; forgetting
  `model.close()` leaks ~2.4 GB. Confirm with `hasActiveModel()`.

---

## R2 — Model download (~2.4 GB, cancellable, foreground, resumable)

**Decision**: **Hybrid** — download with `background_downloader 9.5.5`, then hand the finished
absolute file path to flutter_gemma's `.fromFile(path)`. Do **not** use flutter_gemma's built-in
`.fromNetwork()` for this 2.4 GB case (coarse int-percent progress, weak resume, no explicit
foreground-service control). Both download and load sit behind interfaces (`ModelDownloader`,
`GemmaService`).

**Rationale**: `background_downloader` is purpose-built for large transfers: native
`DownloadWorker` + Android **foreground service** (non-blocking, survives app use/background),
a persistent SQLite task DB (`trackTasks()` → survives process death), rich progress (`double`
0–1 **plus** `expectedFileSize`/`networkSpeed`/`timeRemaining` for the required percent+bytes
UI), first-class cancel (`cancelTaskWithId`), and pause/resume. It writes into
`BaseDirectory.applicationDocuments` = `getApplicationDocumentsDirectory()` (app-private,
no storage permission, OS-encrypted), the same dir flutter_gemma reads.

**Mechanics**:
- `DownloadTask(url, filename:'gemma4-e2b.litertlm.part', baseDirectory: applicationDocuments, directory:'models', updates: Updates.statusAndProgress, allowPause:true, retries:5)` → `FileDownloader().enqueue(task)` (not the awaitable `download()`).
- Subscribe to `FileDownloader().updates` for status + progress.
- Foreground: `FileDownloader().configure(globalConfig: [(Config.runInForegroundIfFileLargerThan, 256)])`; runtime `POST_NOTIFICATIONS` via `FileDownloader().permissions`; `configureNotification(progressBar:true, ...)`.
- Cancel: `FileDownloader().cancelTaskWithId(taskId)` → status `canceled`.
- Resume: `allowPause:true` + `trackTasks()` + `resumeFromBackground()` — **best-effort** (needs HTTP Range + strong ETag; HF CDN doesn't guarantee it → fall back to restart-from-zero).
- **Integrity (FR-008/FR-011)**: download to `*.part`; only on `TaskStatus.complete` (+ optional SHA-256) **atomic-rename** to `gemma4-e2b.litertlm`. A partial file can never be loaded as a model. Check free space first (`Config.checkAvailableSpace`).

**Alternatives rejected**: flutter_gemma `.fromNetwork()` (no bytes progress, weak resume, no FGS
control); `dio` (Dart-isolate only → dies on app kill, no FGS); `flutter_downloader` (older
WorkManager flow, weaker resume); native `DownloadManager` channel (custom Kotlin, less UX
control, Android 15 dataSync limits).

**Risks**: resume is best-effort (host-dependent); Android 15+ caps `dataSync` FGS at ~6 h
(a 2.4 GB download finishes well within); partial-file safety is our responsibility (the
`.part`→rename pattern handles it); `background_downloader` needs Kotlin 2.1.0+ and a Play
Console FGS-type declaration.

---

## R3 — Local persistence (conversations & messages)

**Decision**: Use **`drift`** (`drift` 2.33.0 + `drift_flutter` 0.3.0 + `drift_dev`) over SQLite,
behind a `ConversationRepository` interface. Plain `drift` with `sqlite3_flutter_libs` — **not**
SQLCipher.

**Rationale**: drift uniquely satisfies all four needs with the least code: (1) **reactive**
`.watch()`/`.watchSingle()` streams auto-update the conversation list on any insert/update/delete
(wire to a Riverpod `StreamProvider`); (2) **type-safe** compile-checked queries via code-gen;
(3) **simple migrations** via `schemaVersion` + `MigrationStrategy`; (4) **off-device unit tests**
via `NativeDatabase.memory()` (real sqlite3, pure Dart, no emulator). `drift_flutter`'s
`driftDatabase(name:)` stores the DB in app-private storage (`/data/data/<pkg>/...`), sandboxed by
UID and **Credential-Encrypted (CE) by default on FBE devices** — so the OS provides at-rest
encryption and no app-level crypto is needed (satisfies **FR-032** / clarification Q3). SQLCipher
would add key-management complexity for no gain on non-shared on-device data.

**Alternatives rejected**: raw `sqflite` (no reactive queries — would hand-roll invalidation;
untyped SQL); drift-over-sqflite executor (extra layer, no benefit); drift + SQLCipher
(over-engineered; OS already encrypts); Hive/Isar (NoSQL — wrong fit for the relational schema).

**Risks**: drift needs `build_runner` codegen (commit generated `*.g.dart`); native in-memory
tests need loadable `sqlite3` on CI; `drift_flutter` is 0.x — pin it. CE protects at-rest only
(decrypted while unlocked) — acceptable per the chosen threat model.

---

## R4 — Device capability preflight (RAM + ABI)

**Decision**: Use **`device_info_plus >= 11.4.0`** as the sole preflight source — **no custom
platform channel needed**. Read `AndroidDeviceInfo.physicalRamSize` (total RAM in **MB**) and
`AndroidDeviceInfo.supportedAbis`. Gate, before the download:
- **RAM**: require `physicalRamSize >= 7000` (MB). Real 8 GB devices report ~7400–7700 MB
  because `totalMem` excludes kernel/DMA/baseband-reserved memory; testing against 8192 or 8000
  would falsely reject genuine 8 GB phones. 6 GB devices report ~5600–5900 MB → rejected.
- **ABI**: require `supportedAbis.contains('arm64-v8a')`.
- Expose a `DeviceCapability` value object behind a `DevicePreflightService`; **soft-warn**
  (not hard-block) in the ~6500–7000 MB band (OEM reservation variance).

**Rationale**: Verified in `device_info_plus` native source: `physicalRamSize =
ActivityManager.MemoryInfo.totalMem / 1048576`, `supportedAbis = Build.SUPPORTED_ABIS`. A custom
channel would just re-implement this. RAM fields were added in 11.4.0 (PR #3535) — must pin
`>= 11.4.0`. (13.x needs Flutter 3.38.1/Dart 3.10 — pin the highest SDK-compatible version.)

**Alternatives rejected**: custom MethodChannel (duplicates the package); `ram_info` package
(redundant); `isLowRamDevice` (only flags <1 GB OEM configs); threshold at 8192/8000 (false
rejects); skip preflight (wastes the 2.4 GB download + late failure).

**Risks**: `totalMem` varies by OEM — 7000 MB is conservative, verify against a real device
matrix; emulators (x86) correctly fail the ABI gate; guard with `Platform.isAndroid`.

---

## R5 — Riverpod streaming, cancellation & the test seam

**Decision**: `flutter_riverpod 3.3.1`, **manual (non-codegen) `Notifier`** that owns a
`StreamSubscription` — **not** `StreamProvider` — so partial tokens are retained on stop. All
flutter_gemma access goes through the `GemmaService` provider, overridden with a
`FakeGemmaService` via `ProviderContainer` in tests.

**Rationale**: A `Notifier` holding plain mutable state keeps already-streamed text when
generation stops (FR-014); a `StreamProvider` re-derives its `AsyncValue` and cannot express
"stop but retain." Cancellation = `chat.stopGeneration()` **and** `subscription.cancel()`, both
wired into `ref.onDispose`. The heavy model provider is **kept alive** (`ref.keepAlive`, or a
non-autoDispose `NotifierProvider`) and released explicitly — never auto-disposed, or the 2.4 GB
model would thrash on rebuilds. App-background release needs an `AppLifecycleListener` bridged to
a provider (`ref.onDispose` does not fire on backgrounding). Code-gen is optional in Riverpod 3,
so no `build_runner` is required for state.

**Alternatives rejected**: `StreamProvider` (can't retain partial on stop); `@riverpod` codegen
(optional; defaults to autoDispose — wrong for the model); direct plugin calls (untestable);
autoDispose model provider (memory thrash).

**Risks**: only one generation at a time — guard with an `isGenerating` flag; both stop calls are
required; separate the model provider from the chat notifier so only the session/subscription
auto-dispose.

---

## R6 — Theming, offline fonts & accessibility

**Decision**:
- **Fonts (offline)**: bundle Space Grotesk + Space Mono as TTF assets; use `google_fonts` with
  `GoogleFonts.config.allowRuntimeFetching = false` (bundled assets prioritized — no HTTP), or
  declare them as plain `pubspec` `fonts:` entries. Both SIL OFL. Dot-matrix face: bundle
  **MatrixSans** (SIL OFL 1.1) as an asset, exposed only via `AppText.dotMatrix(...)` for
  display/numerals. Ship each font's `OFL.txt` and register via `LicenseRegistry`.
- **Theme**: `ColorScheme.dark` with explicit token hex; `useMaterial3: true`,
  `scaffoldBackgroundColor: #000000`; kill elevation/tint —
  `surfaceTintColor: Colors.transparent`, `elevation: 0`, `shadowColor: Colors.transparent` on
  Card/Dialog/AppBar/BottomSheet themes; hairline `BorderSide(color: outline)`;
  `DividerThemeData(color: outline, thickness: 1)`.
- **Touch targets**: keep default `materialTapTargetSize: padded` (48×48); never apply global
  compact/negative `VisualDensity`; wrap small custom dot controls in `SizedBox(48,48)`.

**Accessibility — measured contrast on `#000000`** (WCAG 2.x relative-luminance):
| Token | Hex | Ratio on #000000 | Verdict |
|-------|-----|------------------|---------|
| textPrimary | `#FFFFFF` | 21.0:1 | PASS AAA |
| textSecondary | `#A0A0A0` | 8.03:1 (≥6.08:1 on #222222) | PASS AA on all surfaces |
| **textMuted** | `#5C5C5C` | **3.14:1** | **FAIL** normal AA (large/disabled only) |
| **accent** | `#D71921` | **4.05:1** | **FAIL** normal AA (large/icon only) |
| onAccent on accent | `#FFFFFF`/`#D71921` | 5.18:1 | PASS AA |

**Concrete rule (satisfies FR-025 "accessibility floor prevails over tokens" + FR-031)**: the
design system assigns `textMuted #5C5C5C` to timestamps/placeholders, but **FR-021 conversation-
list timestamps are essential normal-size text and MUST NOT use `#5C5C5C`** — use `textSecondary
#A0A0A0` (8.03:1) instead, or render the timestamp as large text. Reserve `#5C5C5C` for genuinely
disabled/inactive elements (WCAG-exempt). Use accent red only as large/bold text, as an icon
(3:1), or as a fill under white text — never as small body text or links (the design system
already forbids red for non-active states; accessibility reinforces it).

**Alternatives rejected**: google_fonts runtime fetch (violates offline-first); `shrinkWrap`/
compact density (sub-48dp targets); red for small text/links (4.05:1 fails); FontStruct/1001fonts
dot-matrix (inconsistent licenses vs MatrixSans OFL).

**Risks**: muted text worsens on raised surfaces (`#5C5C5C` on `#222222` = 2.38:1 — never place
it there); bundle every used weight (400/500/600) or google_fonts silently tries the disabled
fetch (test in airplane mode); ship MatrixSans `OFL.txt` (OFL requires it; RFN clause forbids
renaming); light-theme `textMuted #9A9A9A` on white = 2.81:1 also fails — same restriction.

---

## Resolved unknowns (Technical Context)

| Unknown | Resolution |
|---------|-----------|
| flutter_gemma load/stream/cancel/release API | R1 — modern `FlutterGemma` facade + `InferenceChat`, behind `GemmaService` |
| How to download a 2.4 GB model (progress/cancel/resume/FGS) | R2 — `background_downloader` + atomic `.part`→rename, then `.fromFile` |
| Persistence library & schema host | R3 — `drift` over app-private SQLite (OS-encrypted), reactive `.watch()` |
| Device preflight (RAM ≥ 8 GB, arm64-v8a) | R4 — `device_info_plus` `physicalRamSize >= 7000` MB + `supportedAbis` |
| Riverpod streaming + cancellation + test seam | R5 — manual `Notifier` + `StreamSubscription`, `FakeGemmaService` override |
| Dark M3 theming, offline fonts, AA contrast, 48dp | R6 — bundled fonts, flat M3, muted-text/accent contrast rule |
| Minimum Android version | API 29 (Android 10) — FBE-enforced baseline for at-rest encryption |

All Technical Context unknowns are resolved. No `NEEDS CLARIFICATION` remains for Phase 1.
