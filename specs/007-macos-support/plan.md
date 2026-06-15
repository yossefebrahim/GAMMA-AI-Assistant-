# Implementation Plan: macOS (Apple Silicon) Support

**Branch**: `007-macos-support` | **Date**: 2026-06-14 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `/specs/007-macos-support/spec.md`, the macOS-port
feasibility investigation (12-agent workflow, 2026-06-14), and constitution **v2.1.0** (the MINOR
amendment that sanctions macOS — Apple Silicon).

## Summary

Make the Android-first on-device Gemma assistant also run on macOS (Apple Silicon) as a sanctioned
secondary target. The pivotal finding: **flutter_gemma 0.15.3 — the pinned version — already ships
a complete macOS Apple-Silicon backend** (`dart:ffi` over LiteRT-LM with a Metal GPU delegate). No
version bump, no model swap (`.litertlm`), no fork of the Android pin, and the `GemmaService` seam
needs zero changes. The work is therefore: (a) macOS host wiring (Podfile post-install + entitlements
+ Native Assets), (b) a handful of platform-conditional Dart branches at already-guarded sites
(preflight, permissions, tool gating, model acquisition), and (c) desktop UX polish — all additive
and Android-safe.

Approach — **single codebase, platform-conditional provider wiring**, no flavors. Sequence so the
app LAUNCHES first (US1: preflight + entitlements + web research, the quick win), then prove on-device
inference (US2: Podfile + Metal spike + model file-import), then close behavioral gaps (US3–US5:
voice, device tools, image). Both CI seam guards stay green; the Android baseline and the
`flutter_gemma ^0.15.0` pin are untouched.

Validated environment (2026-06-14): Flutter 3.44.1 stable, Xcode 26.5, CocoaPods 1.16.2, a `macOS
(desktop) darwin-arm64` device (macOS 26.5.1), and the flutter_gemma Metal dylibs already cached at
`~/Library/Caches/flutter_gemma/native/macos_arm64/`. No `.litertlm` model file is present on this
Mac, so SC-007 (inference) requires a model import; SC-001–SC-006/008 are validatable now.

## Technical Context

**Language/Version**: Dart 3.12.x on Flutter 3.44.1 stable — unchanged from 001–006.

**Primary Dependencies**: NO new direct runtime deps required for US1/US2. `flutter_gemma ^0.15.0`
(0.15.3) UNCHANGED — its macOS backend is already present; the forbidden 0.16.x bump is NOT in play
(that regression is Android-only). A cross-platform URL launcher (`url_launcher`) is added for US4's
source-URL chips (seam-confined, new `check_plugin_seam.sh` rule); a file picker for US2's model
import reuses macOS file-selection (confined to the infrastructure seam). `background_downloader`
stays a direct dep but is bypassed on macOS (no macOS impl) in favor of file import.

**Storage**: drift over app-private SQLite — macOS-ready out of the box (`sqlite3_flutter_libs`
darwin pod + `path_provider_foundation`). No schema change, no migration (schemaVersion stays **6**).
On macOS the DB lands in the app-support/sandbox container. The imported `.litertlm` model SHOULD be
stored under `getApplicationSupportDirectory()` (not Documents) to avoid iCloud-sync FFI-mmap breakage.

**Testing**: `flutter_test` host unit + widget against fakes — already runs on the macOS dev host.
New/changed coverage: preflight macOS branch (eligible Apple Silicon, Intel rejected), permission
service macOS guards, platform-gated declared tool list (`set_timer` absent on macOS, registry
unchanged), `get_device_info` macOS branch, macOS `ModelDownloader` file-import seam, URL launcher
seam. No device/plugin/native in host tests (Principle VII). Device verification is a `flutter run -d
macos` / `flutter build macos` walkthrough — NEVER `flutter test integration_test/...`.

**Target Platform**: Android (arm64-v8a, API 29+) UNCHANGED + macOS (Apple Silicon, deployment
target ≥ 11.0). New macOS entitlements: `network.client`, `cs.disable-library-validation`,
`keychain-access-groups`, `device.audio-input` (voice), `files.user-selected.read-only` (file
import/image), `kernel.increased-memory-limit` + `extended-virtual-addressing` (2.4 GB model).
`Info.plist`: `NSMicrophoneUsageDescription`. No new Android permissions.

**Performance Goals**: macOS inference latency/throughput — `TODO(device: US2 Metal spike)`. UI must
stay interactive (Principle IV) — the FFI backend runs inference off the platform thread; re-verify
no main-isolate stall on macOS. GPU→CPU fallback on 8 GB Macs prevents OOM crash (degrades perf).

**Constraints**: Apple Silicon only (Intel rejected at startup, FR-002); App Sandbox ON; all egress
(Tavily + any model fetch) under `network.client`; BYOK key in macOS Keychain via the unchanged
`SecureKeyStore` seam, never in DB/logs/context; both seam guards green (FR-015); Android baseline +
`flutter_gemma 0.15.3` pin untouched (FR-016); shared single pin couples macOS+Android upgrades
(accepted). The plugin build hook performs BUILD-TIME egress (native dylib fetch) — documented as
bytes-in tooling, distinct from the runtime opt-in-egress rule.

**Scale/Scope**: single local user; one new platform target; ~6 Dart files touched (preflight,
device-capability, permission service, tool gating, device-info tool, provider wiring), ~2 new
seam concretes (macOS `ModelDownloader` file-import, cross-platform `WebUrlLauncher`), macOS host
config (Podfile, 2 entitlement files, Info.plist, pbxproj, MainFlutterWindow.swift), composer
keyboard-send. No new layer, no schema change, no new model.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.* Constitution **v2.1.0**
(amended 2026-06-14 to sanction macOS — Apple Silicon). Legend: ✅ satisfied by design · ⚠
implementation/device caution carried into tasks/quickstart.

| # | Principle | Gate — how this plan satisfies it | Status |
|---|-----------|-----------------------------------|--------|
| I | Privacy Is the Product | On-device inference runs locally on macOS (LiteRT-LM/Metal, no cloud) — identical guarantee to Android. The only egress paths remain the model acquisition and the opt-in web-research seam; on macOS web research uses the SAME `NetworkResearchService`/`SecureKeyStore` seams with the BYOK key in the macOS Keychain. Opt-in, off-by-default, named-recipient, offline-degrading, auditable — all preserved unchanged. macOS App Sandbox `network.client` gates egress at the OS level (defense in depth). The plugin's build-time native-dylib fetch is bytes-in tooling (analogous to the model-download carve-out), not user-content egress. | ✅ |
| II | Offline-First | Web off ⇒ zero network on macOS, byte-identical to Android. Core chat/memory function with zero connectivity once a model is imported. Model acquisition is file-import (no network at all). | ✅ |
| III | Capability-Driven UX | Tools are declared via the existing data-driven gates; macOS ADDS a platform-availability predicate to the DECLARED list (`set_timer` absent on macOS) without per-model `if` branches. Capabilities still come from the model catalog. Image/voice affordances follow real platform capability (camera hidden on Mac). | ✅ |
| IV | Responsive & Cancellable | Streaming + cancel paths are seam-level and platform-agnostic. The macOS FFI backend runs inference off the platform thread; UI interactivity to be re-confirmed on-device (US2). | ⚠ Re-verify no main-isolate stall on the Metal backend — US2 spike |
| V | Graceful Degradation | Preflight gains a macOS branch: Apple Silicon eligible (real unified-memory read); **Intel rejected at startup with actionable guidance** (no x86_64 backend) — never a native-load crash (FR-002, amended Principle V macOS tier). GPU→CPU fallback on low-memory Macs. | ⚠ Confirm Intel-rejection copy + 8 GB fallback behavior on-device |
| VI | Dark-First & Accessible | All new surfaces (import-model state, desktop window) use centralized tokens; red reserved for error/destructive. Desktop adds keyboard send + window min-size; 48dp targets remain (oversized but unbroken for mouse). | ⚠ A11y pass on the new desktop surfaces |
| VII | Testable Through a Plugin Seam | `GemmaService` unchanged. New macOS concretes (file-import `ModelDownloader`, cross-platform `WebUrlLauncher`) sit behind existing interfaces in `lib/infrastructure/`; selected by platform in the single composition root (`tool_handler_providers.dart`) and the model-download provider. No widget/domain imports a plugin directly. Both grep guards stay green; new plugin confinement rules added in the same change. | ✅ |
| VIII | Resource Hygiene | Exactly one model active; release paths unchanged. Per the v2.1.0 amendment, macOS large-model acquisition uses a user-initiated file-import flow (no foreground service); imported storage is user-visible/user-deletable. Model stored in Application Support (FFI-mmap-safe). | ✅ |
| IX | Lean Scope | macOS (Apple Silicon) is now a sanctioned secondary target (v2.1.0). Single codebase, platform-conditional wiring, shared pin, NO flavors. Windows/Linux/web/Intel macOS remain NON-GOALS. No new architectural layer. | ✅ |
| X | Design Identity | Reuses existing tokens/components; new desktop window + import state follow the design system; lowercase microcopy. | ✅ |
| — | Technology & Platform Constraints | Stack extended only by macOS host config + at most a seam-confined URL launcher/file picker; SQLite/drift/flutter_gemma pin unchanged; shared runtime pin serves both platforms (no fork). | ✅ |

**Gate result**: PASS (post-amendment). No principle is violated; ⚠ items are device-verification
cautions carried into the US2 spike and quickstart. **Complexity Tracking is empty.** (Pre-amendment,
this plan FAILED on Principle IX + the Platform constraint + Principle V's Android-only tier — the
v2.1.0 amendment is the gating prerequisite and is the reason Phase 0 below is the amendment itself.)

## Project Structure

### Documentation (this feature)

```text
specs/007-macos-support/
├── spec.md                  # Feature spec (this PR)
├── plan.md                  # This file
├── PROGRESS.md              # Living implementation log (overnight autonomous run)
├── research.md              # Phase 0 (pinned macOS native-asset version, entitlement set) — /speckit-plan
├── data-model.md            # per-platform device tier + model-source entity — /speckit-plan
├── quickstart.md            # macOS device validation steps — /speckit-plan
├── contracts/               # macOS ModelDownloader + WebUrlLauncher seam contracts — /speckit-plan
└── tasks.md                 # Phase 2 (/speckit-tasks)
```

### Source Code (repository root) — changes layered on the existing 001–006 tree

```text
macos/                                   # was bare flutter-create scaffold
├── Podfile                              # CHANGED — flutter_gemma post_install block + platform :osx '11.0'
├── Runner/
│   ├── DebugProfile.entitlements        # CHANGED — network.client, cs.disable-library-validation, keychain-access-groups, audio-input, files.user-selected
│   ├── Release.entitlements             # CHANGED — same set
│   ├── Info.plist                       # CHANGED — NSMicrophoneUsageDescription
│   ├── MainFlutterWindow.swift          # CHANGED — default + minimum window size
│   └── Configs/AppInfo.xcconfig         # CHANGED — real PRODUCT_BUNDLE_IDENTIFIER
└── Runner.xcodeproj/project.pbxproj     # CHANGED — MACOSX_DEPLOYMENT_TARGET 11.0

lib/
├── core/platform/
│   └── device_info_preflight_service.dart   # CHANGED — Platform.isMacOS branch (eligible Apple Silicon; reject Intel)
├── domain/entities/
│   └── device_capability.dart               # CHANGED — per-platform eligibility (macOS arch/RAM tier)
├── infrastructure/
│   ├── media/permission_handler_service.dart # CHANGED — macOS camera/mic guard (no MissingPluginException)
│   ├── tools/
│   │   ├── device_info_tool_service.dart      # CHANGED — Platform.isMacOS branch (MacosDeviceInfo)
│   │   └── url_launcher_web_url_launcher.dart  # NEW — cross-platform WebUrlLauncher (url_launcher)
│   └── model/                                  # (data layer) macOS file-import downloader
│       └── file_import_model_downloader.dart   # NEW — macOS ModelDownloader via file picker
├── features/chat/
│   ├── chat_providers.dart                  # CHANGED — platform-gate declared deviceTools (drop set_timer on macOS)
│   ├── tool_handler_providers.dart          # CHANGED — platform-select timer + url-launcher + model-downloader providers
│   └── widgets/composer.dart                # CHANGED — desktop keyboard send (Enter / Shift+Enter)
└── data/db/app_database.dart                # CHANGED (doc only) — scope FBE at-rest claim to Android

tool/
├── check_plugin_seam.sh                     # CHANGED — confine url_launcher (+ any file picker) to its seam dir
└── verify.sh                                # CHANGED — add `flutter build macos --debug` gate (skip on non-Mac)
```

**Structure Decision**: same layered single-app structure as 001–006. No new layer. The macOS target
is realized through (a) host config under `macos/`, (b) platform-conditional branches at existing
guarded Dart sites, and (c) two new seam concretes selected by platform in the composition root. No
schema change, no new model, no flavor.

## Implementation Phases (overnight execution order)

- **Phase 0 — Constitution amendment** ✅ DONE (v2.0.0 → 2.1.0; this PR). Gating prerequisite.
- **Phase 1 — Launch on macOS** (US1): preflight macOS branch; the three core entitlements; bundle id
  + deployment target 11.0; permission-service macOS guard; macOS model file-import behind the
  `ModelDownloader` seam; verify the app builds + boots + web research works.
- **Phase 2 — On-device inference** (US2): flutter_gemma Podfile post_install block; first
  `flutter build macos`; load `.litertlm`, confirm Metal GPU, exercise generate + tool round-trip
  (re-measured, not assumed from A34). *Blocked tonight by the absent model file — wire + build-verify;
  inference run flagged for a model import.*
- **Phase 3 — Behavioral gaps** (US3–US5): voice entitlement + usage string; platform-gate
  `set_timer`; macOS `get_device_info`; cross-platform source-URL launcher; image-attach decision +
  downscale; window size + composer keyboard send; verify.sh macOS gate.

## Complexity Tracking

> No constitutional violations post-amendment — table intentionally empty. The one judgment call is
> **macOS model acquisition via file import** rather than an in-app downloader: chosen because
> `background_downloader` has no macOS implementation and file import adds no new egress path
> (aligns with Principle I), reusing the `ModelDownloader` seam and the existing reinstall fast-path.
