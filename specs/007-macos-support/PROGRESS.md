# 007 macOS Support — Autonomous Run Progress Log

Started 2026-06-14 (overnight autonomous `/loop`). This file is the durable log across loop
iterations and the source for the morning HTML report. Newest entries appended at the bottom.

## Environment (verified)
- Flutter 3.44.1 stable · Xcode 26.5 · CocoaPods 1.16.2 · device: `macOS (desktop) darwin-arm64` (macOS 26.5.1)
- flutter_gemma Metal dylibs cached at `~/Library/Caches/flutter_gemma/native/macos_arm64/` ✓
- **No `.litertlm` model file on this Mac** → full inference (SC-007) cannot be exercised tonight; build/launch/web/tests CAN.

## Validation targets — FINAL
- [x] SC-001 `flutter build macos --debug` (clean) SUCCEEDS — `✓ Built ai_assistant.app`; LiteRtLm/Metal/StreamProxy/GemmaModelConstraintProvider + flutter_gemma frameworks bundled. ⚠ CLEAN build only (see incremental-cycle caveat).
- [x] SC-002 Apple-Silicon launch boots cleanly — `[FlutterGemmaDesktop] Plugin registered for desktop platform`, no crash, no preflight block, ran full 20s to UI.
- [x] SC-003 `flutter analyze --fatal-infos --fatal-warnings` clean + `flutter test` = 689 passed (688 + new macOS gating test). Android not regressed.
- [x] SC-004 both seam guards pass.
- [ ] SC-005 web_search on macOS — wired (entitlements done); needs a Tavily key to exercise (manual).
- [ ] SC-006 BYOK key persists — DEBUG build omits keychain-access-groups (needs dev cert); see report. Release entitlement retained.
- [ ] SC-007 model loads + streams on Metal — BLOCKED: no .litertlm model file on this Mac. Runtime bundled + registered; needs model import.
- [x] SC-008 set_timer absent from declared list on macOS (new test passes); get_device_info returns real MacosDeviceInfo values.

## Build journey (issues fixed, in order)
1. Code signing: `keychain-access-groups` requires a dev cert → removed from DebugProfile (kept in Release). 
2. Deployment target: Runner target still 10.15 while flutter_gemma needs 11.0 → set 11.0 in all 3 pbxproj configs.
3. Build-phase cycle (my flutter_gemma Podfile phase) → `always_out_of_date = '1'`.
4. Build-phase cycle (Flutter Assemble native-assets self-reference: dir contains its output dylib) → cleared by `flutter clean`.
5. ⚠ CYCLE RECURS on INCREMENTAL builds — clean builds work, `flutter build`/`flutter run` without clean re-derive the cyclic graph. Workaround: always `flutter clean` before a macOS build. Root cause is flutter_gemma 0.15.3 native-assets + Flutter 3.44 + Xcode 26.5 (cf. flutter/flutter#134256, #153842). Needs a Flutter SDK / plugin fix (plugin pinned for Android).

## Phase 3 (DONE + validated)
- set_timer gated out of the DECLARED tool list on macOS via overridable `isMacOsProvider` (registry unchanged → replay-safe); harness `isMacOs` param + new test.
- get_device_info macOS branch (MacosDeviceInfo: model, osVersion, ram); `osVersion` neutral key added.

## Round 2 (loop continuation)
- Incremental-build cycle: deep investigation, 3 fix attempts — (a) my-phase `alwaysOutOfDate` [fixed clean builds], (b) `ASSETCATALOG_COMPILER_GENERATE_ASSET_SYMBOLS = NO` [no effect, reverted], (c) `alwaysOutOfDate` on Flutter's "Flutter Assemble" Run Script [no effect, reverted]. CONFIRMED upstream: the cache dir is declared explicitly via Flutter-generated `FlutterInputs.xcfilelist` (dir contains its own output dylib). Needs a Flutter SDK / flutter_gemma fix. pbxproj reverted to clean known-good state.
- FR-018: scoped the FBE at-rest-encryption claim in app_database.dart to Android (macOS = FileVault-dependent). DONE.
- FR-017: added an opt-in macOS build gate to tool/verify.sh (`BUILD_MACOS=1`, Darwin-only, clean build). DONE.
- Composer Enter-to-send (FR-014): DEFERRED — fiddly multiline focus/key interception, risky to ship unattended without desktop verification; recommended approach documented in the report.
- Authored specs/007-macos-support/quickstart.md — the macOS device-validation recipe (V1 build/launch, V2 model-import + inference, V3 web research, V4 tools, V5 regression).
- Re-validated: analyze clean, seam guards green, verify.sh syntax OK, clean macOS build `✓ Built` (artifact restored).

## Stopped here — reason
All safe, decision-free, resource-available work is done. Remaining items need YOUR input or external resources, so they're not appropriate for an unattended run:
- Dependency decisions: `file_selector` (in-app model picker), `url_launcher` (source-URL chips).
- Sandbox/signing decision: dev-team cert for keychain (BYOK key persistence on debug).
- Inference verification (SC-007): needs the 2.4 GB model file + benefits from your judgement on model behavior (and would mean a forbidden integration-test command or GUI automation).
- Composer Enter-to-send: risky to ship unattended without desktop verification.

## Deferred (documented in report)
- Incremental-build cycle workaround / upstream fix.
- In-app model file-import picker (needs `file_selector` dep) — today: guidance + adopt-from-app-support fast-path.
- keychain-access-groups for signed builds; developer.kernel.* memory entitlements for the 2.4GB model.
- Composer Enter-to-send; source-URL launcher via url_launcher; verify.sh macOS gate; image-attach decision.
- On-device inference (SC-007) + web round-trip (SC-005/006) — need a model file + Tavily key.

## Log

### [start] Planning artifacts
- Constitution amended v2.0.0 → v2.1.0 (macOS Apple Silicon sanctioned; Principle V macOS tier; IX NON-GOAL narrowed; VIII file-import; Platform constraints). DONE.
- specs/007-macos-support/spec.md + plan.md written. DONE.
- Branch `007-macos-support` created from main.

### Phase 1 implementation (DONE)
- macos/Runner/DebugProfile.entitlements + Release.entitlements: added network.client, cs.disable-library-validation, cs.allow-unsigned-executable-memory, device.audio-input, files.user-selected.read-only, keychain-access-groups. (developer.kernel.* memory entitlements intentionally OMITTED to avoid codesign issues on ad-hoc debug; recommended before loading the 2.4 GB model — see report.)
- macos/Runner/Info.plist: NSMicrophoneUsageDescription added (lowercase microcopy).
- macos/Runner/MainFlutterWindow.swift: default 480×820, min 380×600, centered.
- macos/Podfile: platform :osx '11.0' + the verbatim flutter_gemma `[flutter_gemma] Setup LiteRT-LM macOS` post_install block (companion-dylib framework bundling + LC_LOAD_DYLIB repatch).
- lib/domain/entities/device_capability.dart: `DeviceCapability.fromMacProbe` (Apple Silicon eligible; Intel → unsupportedAbi).
- lib/core/platform/device_info_preflight_service.dart: Platform.isMacOS branch (reads macOsInfo.memorySize + arch).
- lib/infrastructure/media/permission_handler_service.dart: macOS camera/mic guard (returns granted; no MissingPluginException) + openSettings guard.
- lib/data/model/desktop_model_downloader.dart: NEW macOS ModelDownloader (file-import based; Application Support storage; non-crashing guidance from download()).
- lib/data/model/background_model_downloader.dart: modelDownloaderProvider now platform-selects DesktopModelDownloader on macOS.

### Validation so far
- `flutter analyze --fatal-infos --fatal-warnings`: No issues found ✓
- `flutter test`: All 688 tests passed ✓ (Android baseline intact)
- `bash tool/check_plugin_seam.sh` + `check_network_seam.sh`: both green ✓
- `flutter config --enable-native-assets`: set ✓
- Next: `flutter build macos --debug` (running in background) → then attempt launch.

### Deferred to later loop iterations (non-crashing on macOS today, so safe to defer)
- Phase 3 polish: platform-gate set_timer out of declared list; get_device_info macOS branch (MacosDeviceInfo); cross-platform source-URL launcher (url_launcher); composer Enter-to-send; image attach decision/downscale; verify.sh macOS gate.
- In-app model file-import picker (needs `file_selector` dep) — today macOS shows guidance to drop the .litertlm into the app-support models dir; the existing reinstall fast-path then adopts it.
- developer.kernel.* memory entitlements before exercising the 2.4 GB model.
