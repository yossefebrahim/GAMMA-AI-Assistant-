# Feature Specification: macOS (Apple Silicon) Support

**Feature Branch**: `007-macos-support`

**Created**: 2026-06-14

**Status**: Draft

**Input**: User description: "Make the Android-first on-device Gemma assistant also run on macOS
(Apple Silicon), as a sanctioned secondary target, reusing the existing seams and the shared
flutter_gemma pin without forking Android behavior. Ship all features where achievable; web
research is config-only, voice/image/device-tools need small seam-confined changes."

## Context & Constraints (non-template preamble)

This feature is gated behind constitution **v2.1.0** (the MINOR amendment in
`.specify/memory/constitution.md` that carves macOS — Apple Silicon out of the Principle IX
NON-GOAL list and adds a macOS device tier to Principle V). It builds on the verified finding that
**flutter_gemma 0.15.3 — the exact pinned version — already ships a complete macOS Apple-Silicon
backend** (`dart:ffi` over LiteRT-LM with a Metal GPU delegate, `dartPluginClass:
FlutterGemmaDesktop`). No version bump, no model-format change (`.litertlm`), no fork of the
Android pin. macOS is a single codebase with platform-conditional provider wiring — never a build
flavor.

Hard scope boundaries:

- **Apple Silicon only.** Intel (x86_64) Macs MUST be rejected at startup (no x86_64 runtime
  artifact exists). Windows, Linux, web, and Intel macOS remain NON-GOALS.
- **Android is untouched.** Every macOS change is additive and platform-guarded; the A34-verified
  Android baseline, the `flutter_gemma ^0.15.0` pin, and both CI seam guards stay green.
- **"All features without changing the codebase" is only partially possible.** Web research is the
  ONLY feature that ships config-only (entitlements). Voice, image, device tools, and model
  acquisition each require small, seam-confined Dart/Swift changes — they are scoped as later user
  stories, not pretended to be free.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - The app launches on macOS and does web research (Priority: P1)

A user on an Apple-Silicon Mac installs and opens the app. It boots past onboarding without
dead-ending on the Android-shaped device preflight, persists its database, and — once the user
supplies a Tavily key — performs `web_search` / `fetch_page` exactly as on Android, with the same
opt-in, off-by-default, named-recipient egress chips. On-device chat is gated behind a clear
"import a model to enable on-device chat" state (the runtime is wired but the model is acquired in
US2).

**Why this priority**: This is the highest-confidence, lowest-risk slice and the quickest path to a
shippable Mac artifact. Web research is pure cross-platform Dart and works on macOS once the App
Sandbox network/keychain entitlements land. It decouples "app runs on Mac" (provable tonight) from
"on-device chat works on Mac" (needs the model file + a Metal spike).

**Independent Test**: `flutter build macos --debug` succeeds; the app launches on a Mac; a fresh
install reaches the home/onboarding surface instead of the "unsupported processor" screen; with a
Tavily key entered, a web search returns results and renders a `WEB_SEARCH · Tavily` chip; web off
⇒ zero network.

**Acceptance Scenarios**:

1. **Given** a fresh install on an Apple-Silicon Mac, **When** the app launches, **Then** the
   device preflight reports eligible and the user reaches onboarding/home (not `PreflightBlocked`).
2. **Given** an Intel Mac, **When** the app launches, **Then** it is rejected at startup with
   clear, actionable guidance — never a `DynamicLibrary.open` crash.
3. **Given** web access enabled with a valid Tavily key, **When** the model would call `web_search`,
   **Then** the outbound call succeeds under the App Sandbox and the recipient chip renders before
   the request completes.
4. **Given** web access off, **When** the user chats, **Then** zero network egress occurs
   (byte-identical to Android web-off behavior).
5. **Given** the BYOK key was entered and the app fully relaunched, **When** the user returns,
   **Then** `hasValidKey` is still true (macOS Keychain round-trip via the same `SecureKeyStore`
   seam).

---

### User Story 2 - On-device Gemma chat works on macOS via Metal (Priority: P2)

A user imports a `.litertlm` model file, the app loads it through the existing `GemmaService` seam
onto the macOS Metal backend, and streams a token-by-token reply to a prompt — including a function
call round-trip — without running inference on the UI isolate.

**Why this priority**: This is the make-or-break of "real" macOS support and the highest technical
risk (the Metal FFI path is a different native backend than the A34's Mali path; the macOS Podfile
post-install + Native Assets bundling is mandatory and unproven for this app). It depends on US1's
launch path and on a model-acquisition route (macOS has no `background_downloader` implementation,
so the chosen route is **user-initiated file import**).

**Independent Test**: With the flutter_gemma macOS Podfile block + entitlements in place, a built
app loads a `.litertlm` Gemma 4 E2B model, activates `PreferredBackend.gpu` (Metal, not silent CPU
fallback), and streams a response; a tool-call round-trip completes via `resumeWithToolResult`.

**Acceptance Scenarios**:

1. **Given** a built macOS app and a local `.litertlm` file, **When** the user imports it, **Then**
   the model is registered and loadable through the unchanged `GemmaService` seam.
2. **Given** a loaded model, **When** the user sends a prompt, **Then** output streams token-by-token
   and the UI stays interactive throughout (no main-isolate inference).
3. **Given** function calling is supported, **When** the model emits a tool call, **Then** the
   one-round-trip contract completes and the tool chip renders — re-verified on the macOS SDK
   response path (not assumed from the A34 spike).
4. **Given** an 8 GB Mac, **When** GPU memory is insufficient, **Then** the seam falls back to CPU
   without crashing (degraded, not fatal).

---

### User Story 3 - Voice input on macOS (Priority: P3)

A user records a voice clip on macOS; the OS microphone prompt appears once (granted via the
audio-input entitlement + usage string), and the clip is captured as WAV 16 kHz mono PCM16 and sent
to the model.

**Why this priority**: Audio is the modality the FFI backend supports and the A34 already proved
end-to-end; `record_macos` exists. It needs an entitlement, an `Info.plist` usage string, and a
macOS guard in `PermissionHandlerService` (which otherwise throws `MissingPluginException` because
`permission_handler` has no macOS implementation).

**Acceptance Scenarios**:

1. **Given** the audio-input entitlement + usage string, **When** the user taps record the first
   time, **Then** the macOS mic permission prompt appears and recording proceeds (no
   `MissingPluginException`).
2. **Given** a recorded clip, **When** it is sent, **Then** it reaches the model in the existing WAV
   contract unchanged.

---

### User Story 4 - Device tools behave correctly on macOS (Priority: P3)

The model is offered only tools that work on macOS: `set_timer` (Android-only, via
`android_intent_plus`) is NOT declared on macOS; `get_device_info` returns real macOS values
(model, OS version, memory) instead of "unknown"; source-URL chips open in the default browser via
a cross-platform launcher.

**Why this priority**: Prevents the model from confidently calling tools that always fail on macOS
and removes silent dead-taps. All changes are seam-confined and registry-replay-safe (the tool
specs stay in `ToolRegistry` so historical Android transcripts still replay; only the *declared*
list is platform-gated).

**Acceptance Scenarios**:

1. **Given** macOS, **When** the tool list is declared to the model, **Then** `set_timer` is absent
   while all other applicable tools are present.
2. **Given** a replayed Android conversation containing a `set_timer` turn, **When** it is loaded on
   macOS, **Then** `ToolRegistry.byName('set_timer')` still resolves and the historical chip renders.
3. **Given** `get_device_info` is called on macOS, **Then** it returns real `MacosDeviceInfo` values,
   not Android-shaped "unknown".
4. **Given** a web-research source chip, **When** tapped on macOS, **Then** the URL opens in the
   default browser.

---

### User Story 5 - Image input on macOS (Priority: P4, conditional)

A user attaches an image from the file system on macOS. The camera affordance (which `image_picker`
cannot satisfy on a Mac) is hidden; library/file pick works; the image is downscaled in Dart to
respect the model's input cap.

**Why this priority**: Lowest value and partially moot — image *grounding* is broken at the
flutter_gemma 0.15.3 native layer regardless of platform (a known Android finding that may or may
not differ on the Metal FFI path). Recommended default: **disable image attach on the macOS build**
unless the US2 spike shows grounding works on Metal. Captured here so the decision is explicit.

**Acceptance Scenarios**:

1. **Given** macOS, **When** the attach sheet opens, **Then** the camera option is hidden and only
   file/library pick is offered.
2. **Given** a large image is picked, **When** it is attached, **Then** it is downscaled in Dart
   below the model input cap (because `image_picker_macos` ignores `maxWidth`/`imageQuality`).

---

### Edge Cases

- **Intel Mac**: rejected at startup with guidance (no x86_64 backend); must not reach a native load.
- **No model present**: chat surfaces a clear "import a model" state; web research still works.
- **App Sandbox + iCloud Documents sync**: a `.litertlm` in a cloud-synced Documents dir can break
  FFI mmap — model storage SHOULD use Application Support, not Documents, on macOS.
- **Battery-less desktop Mac** (Mac mini/Studio): `get_device_info` battery reads
  `UNAVAILABLE`/`connected_not_charging`; suppress or label honestly rather than mislead the model.
- **Missing entitlement at runtime**: keychain write silently no-ops (triple gate never opens) and
  network calls fail — only caught on a signed on-device run, not by host tests using fakes.
- **First build offline**: the flutter_gemma build hook fetches the native dylib from a GitHub
  release; offline first-build fails unless `~/Library/Caches/flutter_gemma/native` is populated
  (it is, on this machine).

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The app MUST run on macOS (Apple Silicon, arm64) as a sanctioned secondary target,
  reusing all existing domain seams without forking Android behavior.
- **FR-002**: Device preflight MUST treat Apple Silicon macOS as eligible (reading real unified
  memory via `device_info_plus` macOS support) and MUST reject Intel (x86_64) macOS at startup with
  clear, actionable guidance — never a runtime native-load crash.
- **FR-003**: Both macOS entitlement files (`DebugProfile.entitlements`, `Release.entitlements`)
  MUST grant `com.apple.security.network.client` (model download/import preflight + Tavily egress),
  `com.apple.security.cs.disable-library-validation` (load the bundled LiteRT-LM dylibs), and
  `keychain-access-groups` (the BYOK key via `flutter_secure_storage_darwin`).
- **FR-004**: The macOS `Podfile` MUST include the flutter_gemma `[flutter_gemma] Setup LiteRT-LM
  macOS` `post_install` build phase (wrapping the three Metal companion dylibs into
  `Contents/Frameworks/` and patching `LiteRtLm`'s `LC_LOAD_DYLIB`), and the macOS deployment target
  MUST be ≥ 11.0. Native Assets MUST be enabled for the build.
- **FR-005**: The `GemmaService` seam MUST remain unchanged and load `.litertlm` Gemma 4 E2B on the
  macOS Metal backend via the existing `installModel().fromFile()` + GPU→CPU fallback path.
- **FR-006**: macOS model acquisition MUST use a user-initiated file-import flow (since
  `background_downloader` has no macOS implementation), routed through the existing `ModelDownloader`
  seam via platform-conditional provider selection. The imported model MUST land in a sandbox-safe,
  FFI-mmap-safe location (Application Support, not cloud-synced Documents).
- **FR-007**: `PermissionHandlerService` MUST be macOS-safe — camera/mic status/request MUST NOT
  throw `MissingPluginException`; they MUST mirror the existing non-Android short-circuit (return
  granted; let `record_macos`/file pickers trigger the native TCC prompt).
- **FR-008**: The DECLARED tool list MUST be platform-gated: `set_timer` MUST NOT be declared on
  macOS. `ToolRegistry` MUST remain unchanged (all specs retained) so historical Android tool turns
  still replay (`ToolRegistry.byName` resolves on every platform).
- **FR-009**: `get_device_info` MUST return real macOS values (model, OS version, memory) on macOS
  rather than Android-shaped "unknown".
- **FR-010**: The web-research source-URL chip launcher MUST open URLs on macOS (cross-platform
  launcher behind the existing `WebUrlLauncher` seam), replacing the Android-only
  `android_intent_plus` path.
- **FR-011**: Web research (`web_search` + `fetch_page` + BYOK key storage) MUST function on macOS
  with ZERO Dart code changes — entitlements only — and MUST preserve all Principle I safeguards
  (opt-in, off by default, named recipient, offline-degrading, auditable).
- **FR-012**: Voice input (`record_macos`) MUST work on macOS with the audio-input entitlement and
  `NSMicrophoneUsageDescription`, producing the model's exact WAV 16 kHz mono PCM16 contract.
- **FR-013**: Image input on macOS MUST hide the camera affordance and downscale picked images in
  Dart (because `image_picker_macos` ignores `maxWidth`/`imageQuality`); image attach MAY be
  disabled entirely on macOS pending the US2 grounding finding.
- **FR-014**: The macOS window MUST open at a usable default size with a sensible minimum
  (`MainFlutterWindow.swift`), and the composer MUST support a desktop keyboard send affordance
  (Enter-to-send / Shift+Enter newline), gated to desktop so mobile is unaffected.
- **FR-015**: Both seam guards (`check_plugin_seam.sh`, `check_network_seam.sh`) MUST stay green;
  any new plugin (e.g. a cross-platform URL launcher or file picker) MUST gain its confinement rule
  in the same change, and any new egress file MUST be added to the network-seam allowlist.
- **FR-016**: The Android build, the `flutter_gemma ^0.15.0` pin, and all existing host unit/widget
  tests MUST remain green — no macOS change may regress Android.
- **FR-017**: CI/`verify.sh` MUST gain a `flutter build macos --debug` gate (guarded to skip on
  non-Mac hosts) alongside the existing arm64 APK build.
- **FR-018**: At-rest-encryption documentation that claims Android FBE MUST be scoped to Android;
  the macOS reality (FileVault-dependent) MUST be stated, not overstated.

### Key Entities *(include if feature involves data)*

- **Platform device tier**: the per-platform eligibility model (Android arm64-v8a/8 GB; macOS Apple
  Silicon/8 GB unified memory; Intel rejected). Drives preflight and the E4B-offer threshold.
- **Model source**: how the `.litertlm` is acquired — Android download (existing) vs macOS
  file-import (new) — both resolving to an absolute file path the `GemmaService` seam loads.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: `flutter build macos --debug` completes successfully on Apple Silicon with the
  flutter_gemma Metal dylibs bundled into `Contents/Frameworks/`.
- **SC-002**: A fresh macOS launch reaches onboarding/home (not `PreflightBlocked`) on Apple Silicon;
  an Intel Mac is rejected at startup.
- **SC-003**: `flutter analyze --fatal-infos --fatal-warnings` is clean and `flutter test` passes
  (host tests run on the Mac dev host) after all changes — Android not regressed.
- **SC-004**: Both seam guards pass (`bash tool/check_plugin_seam.sh`, `bash
  tool/check_network_seam.sh`).
- **SC-005**: With a Tavily key, a `web_search` returns results on macOS and the recipient chip
  renders; web off ⇒ zero network.
- **SC-006**: The BYOK key persists across a full app relaunch (macOS Keychain round-trip).
- **SC-007** *(needs model file)*: A `.litertlm` Gemma 4 E2B model loads and streams a reply on the
  macOS Metal backend through the unchanged `GemmaService` seam; a tool round-trip completes.
- **SC-008**: `set_timer` is absent from the declared tool list on macOS while resolving by name for
  replay; `get_device_info` returns real macOS values.

## Assumptions

- The target is Apple Silicon only; Intel macOS is explicitly out of scope and rejected at startup.
- flutter_gemma 0.15.3's macOS Metal backend loads Gemma 4 E2B `.litertlm` — verified statically
  (plugin source, README, cached dylibs); to be confirmed on-device in the US2 spike. The A34 spike
  findings (audio works, image grounding broken, FC 83% floor, main-thread perf) are Android/Mali
  specific and do NOT transfer.
- The model is supplied by the user via file import on macOS (no in-app download); the existing
  reinstall fast-path already adopts a pre-existing model file.
- App Sandbox stays ON (App Store viability); a signing identity/team is available so
  `keychain-access-groups` is honored. Local debug may run ad-hoc-signed with caveats.
- macOS is a secondary target: single codebase, platform-conditional provider wiring, shared
  `flutter_gemma ^0.15.0` pin, no build flavors.
- Existing seams (`GemmaService`, `NetworkResearchService`, `SecureKeyStore`, `ModelDownloader`,
  media/device-tool services) are the integration points; no new architectural layer is introduced.
