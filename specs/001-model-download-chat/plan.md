# Implementation Plan: First Working Slice — Model Download & Chat

**Branch**: `001-model-download-chat` | **Date**: 2026-06-07 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `/specs/001-model-download-chat/spec.md`

## Summary

Deliver the foundational end-to-end experience of the On-Device Gemma Assistant: a first-run
dark onboarding screen → device preflight → cancellable, progress-reporting download of the
default Gemma 4 E2B model from an open redistributable URL → a chat screen with token-by-token
streaming, an always-available stop control, sliding-window conversational memory, and
persistent, browsable conversation history — all fully offline after install.

Technical approach: a single Flutter/Android module organized in layers
(`domain` → `data`/`infrastructure` → `features`), with **all `flutter_gemma` usage isolated
behind one `GemmaService` interface** (the constitution's plugin seam). State is managed with
Riverpod; conversations persist in app-private SQLite (OS file-based encryption, no app-level
crypto). The model download runs under an Android **foreground service** so it survives the app
being used and is cancellable. Model capabilities are read as **data** from the service; this
slice gates input to text-only via scope configuration, not hardcoded model branches. The UI
implements the project design system (`.specify/memory/design-system.md`) with centralized
tokens (`AppColors`/`AppText`/`AppSpacing`), dot-matrix pulse loaders, and a WCAG-AA / 48dp
accessibility floor that prevails over any token. Library-specific decisions (exact
`flutter_gemma` APIs, download package, persistence library, preflight channel) are resolved in
[research.md](research.md).

## Technical Context

**Language/Version**: Dart 3.x on Flutter (stable channel, 3.2x+).

**Primary Dependencies**: `flutter_gemma` (LiteRT-LM/MediaPipe model runtime — isolated behind
`GemmaService`); `flutter_riverpod` + `riverpod_generator` (state); `drift` over SQLite
(persistence); a cancellable/resumable downloader with foreground-service support; a device
preflight path (`device_info_plus` + a custom Android platform channel for total RAM and
supported ABIs); bundled fonts (Space Grotesk, Space Mono, an openly-licensed dot-matrix face).
Exact packages/versions are pinned in [research.md](research.md).

**Storage**: SQLite via `drift`, in app-private storage (inherits Android file-based
encryption per FR-032). Two core tables: `conversations`, `messages`. Model file stored as an
app-private file managed by the model/download layer.

**Testing**: `flutter_test` for unit + widget tests; the `GemmaService` seam is replaced by a
`FakeGemmaService` so domain/presentation logic is testable without the native plugin; `drift`
in-memory database for repository tests.

**Target Platform**: Android, `arm64-v8a` only, minimum Android 10 (API 29, FBE-enforced
baseline — confirmed in research), 8 GB RAM hard floor (Principle V / FR-003).

**Project Type**: Mobile application — single Flutter module, Android-first (iOS/desktop are
explicit non-goals).

**Performance Goals**: token-by-token streaming; first reply text within 5 s on the reference
baseline device (SC-004); download progress refresh ≥ 1/s (SC-002); UI gesture response within
100 ms while streaming (SC-011); inference never on the UI isolate (Principle IV).

**Constraints**: offline after install (Principle II); the only network call is the one-time
model download (Principle I); no user content leaves the device; exactly one active model with
explicit release (Principle VIII); download and generation both user-cancellable (Principle IV);
dark-first Material 3 (Principle VI); single in-flight generation (clarification Q4).

**Scale/Scope**: single local user; modest local data (hundreds–thousands of messages across
tens of conversations); ~6 primary screens (welcome/license, preflight gate, download, chat,
history, settings: model-storage + theme).

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

Constitution version **1.2.0**. Every principle maps to a design gate below. Status legend:
✅ satisfied by design · ⚠ needs care during implementation.

| # | Principle | Gate — how this plan satisfies it | Status |
|---|-----------|-----------------------------------|--------|
| I | Privacy Is the Product | Only network call is the model download (one downloader call site, audited). No telemetry of content. `GemmaService` runs fully on-device. | ✅ |
| II | Offline-First | After install, onboarding gate is passed and all features (chat, history) operate with no network; connectivity loss cannot interrupt generation (local inference). | ✅ |
| III | Capability-Driven UX | `GemmaService.capabilities` exposes modality support as data; UI renders affordances from it. This slice restricts to text via scope config (FR-016), not a hardcoded per-model branch. | ✅ |
| IV | Responsive & Cancellable | Streaming token API; cancellable download (foreground service) and generation (cancel the in-flight stream); inference off the UI isolate. | ⚠ verify no main-isolate blocking on model load |
| V | Graceful Degradation | Preflight RAM (≥8 GB) + ABI (arm64-v8a) before download; honest blocking message; no OOM path. | ✅ |
| VI | Dark-First & Accessible | M3 dark default + persisted theme; 48dp targets + WCAG AA (FR-031); accessibility floor prevails over design tokens (FR-025). | ⚠ audit muted-text tokens for AA (see research) |
| VII | Testable Through a Plugin Seam | All `flutter_gemma` imports confined to `infrastructure/gemma/`; everything else depends on the `GemmaService` interface; `FakeGemmaService` in tests. | ✅ |
| VIII | Resource Hygiene | Exactly one model active; `GemmaService.close()` on dispose/background; model storage shown + user-deletable (FR-030); download under foreground-service rules. | ✅ |
| IX | Lean Scope | Implements only the slice; out-of-scope modalities/multi-model excluded; theme toggle + single-model delete justified against binding principles VI/VIII. | ✅ |
| X | Design Identity | Centralized tokens (`AppColors`/`AppText`/`AppSpacing`) from design-system.md; dot-matrix pulse loaders (no spinners); no gradients/shadows (elevation 0, surfaceTint transparent). | ✅ |

**Gate result**: PASS. No principle is violated; two ⚠ items are implementation cautions
(carried into research/tasks), not deviations. **Complexity Tracking is therefore empty.**

## Project Structure

### Documentation (this feature)

```text
specs/001-model-download-chat/
├── plan.md              # This file (/speckit-plan output)
├── research.md          # Phase 0 output — resolved technology decisions
├── data-model.md        # Phase 1 output — entities, schema, state transitions
├── quickstart.md        # Phase 1 output — runnable validation guide
├── contracts/           # Phase 1 output — service + repository interface contracts
│   ├── gemma_service.md
│   ├── model_download.md
│   ├── conversation_repository.md
│   └── device_preflight.md
└── tasks.md             # Phase 2 output (/speckit-tasks — NOT created here)
```

### Source Code (repository root)

```text
lib/
├── main.dart
├── app/                          # app shell, routing, theme
│   ├── app.dart
│   ├── router.dart
│   └── theme/                    # AppColors · AppText · AppSpacing · app_theme.dart (design tokens)
├── core/                         # cross-cutting utilities
│   ├── result.dart               # Result/failure types
│   └── platform/
│       └── device_capability_channel.dart   # MethodChannel: total RAM + supported ABIs
├── domain/                       # pure Dart — no Flutter, no flutter_gemma (fully unit-testable)
│   ├── entities/                 # Conversation · Message · InstalledModel · DeviceCapability
│   ├── services/
│   │   └── gemma_service.dart     # THE plugin seam (abstract interface + capability model)
│   └── repositories/
│       └── conversation_repository.dart      # abstract
├── data/                         # data layer
│   ├── db/                       # drift database, tables, DAOs
│   │   ├── app_database.dart
│   │   ├── tables.dart
│   │   └── daos/conversation_dao.dart
│   ├── model/                    # model file manager + download controller (foreground service)
│   └── repositories/
│       └── drift_conversation_repository.dart
├── infrastructure/               # the ONLY place flutter_gemma is imported
│   └── gemma/flutter_gemma_service.dart       # implements GemmaService
└── features/                     # presentation, by feature (Riverpod controllers + widgets)
    ├── onboarding/               # welcome + license ack + preflight gate
    ├── download/                 # download screen + controller
    ├── chat/                     # chat screen, composer, streaming, stop, context assembler
    ├── history/                  # conversation list, new, delete
    └── settings/                 # model storage (size/delete) + theme toggle

test/
├── unit/                         # domain, repositories (in-memory drift), controllers (FakeGemmaService)
├── widget/                       # screen widget tests
└── helpers/                      # FakeGemmaService, fixtures, ProviderContainer harness

android/                          # foreground service, RAM/ABI platform channel, manifest, abiFilters
```

**Structure Decision**: A single Flutter module (mobile-app type) using a layered architecture.
`domain/` is pure Dart (entities + the `GemmaService` and `ConversationRepository` interfaces)
so it and the presentation controllers are unit-testable without the native plugin. The plugin
seam (Principle VII) is enforced structurally: `flutter_gemma` may be imported **only** inside
`lib/infrastructure/gemma/`. Riverpod providers compose the layers and own resource lifecycles
(stream cancellation, model release on dispose/background).

## Complexity Tracking

No constitution violations — this section is intentionally empty. The architecture stays at the
minimum needed to honor the plugin seam, resource hygiene, and graceful-degradation principles;
no extra projects, patterns, or abstractions are introduced beyond those gates.

## Post-Design Constitution Re-Check

After Phase 1 (research + data model + contracts), the gate is re-evaluated. **Result: PASS.**
Both implementation-caution (⚠) items from the initial check are now resolved with concrete
designs; no new violations were introduced.

- **IV — Responsive & Cancellable (⚠ → ✅)**: `flutter_gemma` runs inference in native code, off
  the Dart UI isolate; `GemmaService.generate` returns a `Stream<String>` and `loadModel` is an
  awaited `Future`, so neither blocks the UI. The 2.4 GB download runs in an Android foreground
  service via `background_downloader` (non-blocking, cancellable). Generation cancel = `stop()`
  (`chat.stopGeneration()` + subscription cancel). See [research.md](research.md) R1/R2/R5.
- **VI — Dark-First & Accessible (⚠ → ✅)**: research measured token contrast on `#000000`.
  `textSecondary #A0A0A0` passes AA (8.03:1) on all surfaces; `textMuted #5C5C5C` (3.14:1) and
  `accent #D71921` (4.05:1) **fail** AA for normal text. The binding rule (FR-025/FR-031, enforced
  in the design + quickstart V7): conversation-list timestamps (FR-021) use `textSecondary`, not
  `textMuted`; red is used only as large/bold text, icons, or a white-on-red fill. 48dp targets
  via the default padded tap-target size. See [research.md](research.md) R6.

**New-artifact compliance:**

| Principle | Honored by design artifacts |
|-----------|-----------------------------|
| I Privacy | `ModelDownloader` is the only network seam; no service performs content I/O ([contracts](contracts/)) |
| III Capability-Driven | `GemmaService.capabilities` value object (data, not branches) — [gemma_service.md](contracts/gemma_service.md) |
| V Graceful Degradation | `DevicePreflightService` + `DeviceCapability` gate before download — [device_preflight.md](contracts/device_preflight.md) |
| VII Plugin Seam | `flutter_gemma` confined to `infrastructure/gemma/`; all seams have fakes — [contracts](contracts/) |
| VIII Resource Hygiene | single-active-model + explicit `close()`; model delete/size in data model + [model_download.md](contracts/model_download.md) |
| X Design Identity | tokens/typography/motion centralized per design-system; AA override rule documented |

Gate clear → ready for `/speckit-tasks`. Complexity Tracking remains empty.
