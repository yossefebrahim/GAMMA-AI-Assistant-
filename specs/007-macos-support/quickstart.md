# Quickstart — macOS (Apple Silicon) validation

Device validation steps for the 007 macOS port. Host-side gates (analyze, tests, seam guards) and
the build + launch were validated autonomously on 2026-06-14 (macOS 26.5 · Xcode 26.5 ·
Flutter 3.44.1 · Apple Silicon). The steps below cover the **manual** checks that need a model file,
a Tavily key, or human judgement.

## Prerequisites

- Apple-Silicon Mac (Intel is rejected at startup by design — no x86_64 backend).
- Xcode + CocoaPods; `flutter config --enable-native-assets` (already set on this machine).
- The flutter_gemma Metal dylibs cached at `~/Library/Caches/flutter_gemma/native/macos_arm64/`
  (auto-fetched by `flutter pub get`).

> ⚠️ **Always CLEAN-build macOS.** Incremental builds hit an upstream "Cycle inside Flutter Assemble"
> (flutter_gemma 0.15.3 native-assets × Xcode 26). Use `flutter clean` before every macOS build.

## V1 — Build & launch (validated ✓)

```bash
flutter clean && flutter pub get
flutter build macos --debug
open build/macos/Build/Products/Debug/ai_assistant.app
```

Expect: the app launches, no crash, and the welcome/onboarding screen appears (NOT
"unsupported processor"). Confirm in the run log: `[FlutterGemmaDesktop] Plugin registered for
desktop platform`. To watch logs: `flutter run -d macos` after a clean build, OR run the binary
directly: `build/macos/Build/Products/Debug/ai_assistant.app/Contents/MacOS/ai_assistant`.

## V2 — Import a model & verify on-device inference (SC-007, needs a model file)

macOS has no in-app download (no `background_downloader`); acquisition is **file import**. Until the
in-app picker lands, place the model file where the app adopts it:

1. Obtain `gemma-4-e2b.litertlm` (the same file the Android app downloads — `litert-community/
   gemma-4-E2B-it-litert-lm`, ~2.4 GB). You can copy it off the A34, or download it from Hugging Face.
2. Put it in the app's sandbox Application Support models dir:
   `~/Library/Containers/<bundle-id>/Data/Library/Application Support/<app>/models/gemma-4-e2b.litertlm`
   (run the app once first so the container exists; the exact path is logged by `DesktopModelDownloader`).
3. Relaunch. The reinstall fast-path adopts the file → routes to chat.

Validate:
- **V2a** — the model loads; `PreferredBackend.gpu` (Metal) activates and does NOT silently fall to
  CPU (watch the log). On an 8 GB Mac, GPU→CPU fallback is acceptable (degraded, not fatal).
- **V2b** — a prompt streams a token-by-token reply; the UI stays interactive during generation.
- **V2c** — a tool round-trip completes (e.g. "what's my battery / device info?" → `get_device_info`
  returns real macOS values; the chip renders).
- **V2d** — audio: record a clip and confirm transcription (mic prompt appears once).
- ⚠️ Re-measure, don't assume: the A34 spike findings (audio works, image grounding broken, FC 83%
  floor, main-thread perf) are Mali/Android-specific. macOS uses a different Metal/FFI backend.

## V3 — Web research (SC-005/006, needs a Tavily key)

1. Settings → web research → enter a Tavily key, enable web access.
2. Ask something current; expect a `WEB_SEARCH · Tavily` chip + tappable source URLs.
   - ⚠️ Source-URL chips are a **silent no-op** on macOS today (no `url_launcher`) — they won't open.
3. **V3a** — relaunch the app; confirm the key persists (`hasValidKey` true, tools still declared).
   - ⚠️ On an ad-hoc DEBUG build the keychain entitlement is omitted (it needs a dev cert). If the key
     does not persist, sign with a team (+ Keychain Sharing) or set `useDataProtectionKeyChain:false`
     in `FlutterSecureKeyStore`.
4. **V3b** — disable web access and chat: confirm zero network egress (byte-identical to Android web-off).

## V4 — Tool behavior on macOS (SC-008, validated by unit test ✓)

- `set_timer` is NOT declared to the model on macOS (no Android intent path) — covered by
  `test/unit/features/tool_gating_test.dart`.
- `get_device_info` returns real `MacosDeviceInfo` (model, `osVersion`, ram), not "unknown".
- A replayed Android conversation containing a `set_timer` turn still renders (registry unchanged).

## V5 — Regression: Android untouched (validated ✓)

```bash
flutter analyze --fatal-infos --fatal-warnings   # clean
flutter test                                      # 689 passed
bash tool/check_plugin_seam.sh && bash tool/check_network_seam.sh   # green
BUILD_MACOS=1 bash tool/verify.sh                 # optional: also clean-builds macOS (Darwin only)
```

## Known limitations (see macos-support-report.html)

- Clean-build only (incremental cycle — upstream).
- No in-app model picker (`file_selector` decision); source-URL chips no-op (`url_launcher` decision).
- Composer Enter-to-send deferred (desktop keyboard send).
- Image grounding broken on flutter_gemma 0.15.3 regardless of platform.
