# GAMMA AI Assistant

**A private, fully on-device AI assistant for Android.** Gemma 4 E2B runs locally via [flutter_gemma](https://pub.dev/packages/flutter_gemma) (LiteRT-LM) — your conversations never leave the device unless you explicitly opt in.

[![CI](https://github.com/yossefebrahim/GAMMA-AI-Assistant-/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/yossefebrahim/GAMMA-AI-Assistant-/actions/workflows/ci.yml)

---

## What is this?

GAMMA AI Assistant (Dart package `ai_assistant`) is a Flutter chat app that runs the **Gemma 4 E2B** model entirely on-device. There is no backend, no account, and no telemetry. The model is downloaded once (~2.4 GB) and every inference after that happens locally — chat, vision, voice transcription, on-device tools, and long-term memory all work with the network turned off.

The app is **offline-first** and Android-first. The only network activity the app performs by default is the one-time model download. Everything else is opt-in and clearly disclosed:

- **On-device only** — model weights, chat history, and your facts live in app-private SQLite and local files. Nothing is sent to a server for inference.
- **Opt-in egress with a named recipient** — the only outbound feature, *web research*, is off by default. When you enable it, every network call names its recipient (Tavily for search, the target website for page fetches), and the API key you provide is stored in Android Keystore-backed secure storage, never in the database, logs, or model context.
- **Auditable seams** — all platform and network access is confined behind explicit interfaces, enforced in CI by `tool/check_plugin_seam.sh` and `tool/check_network_seam.sh`.

The privacy posture and architecture are governed by a versioned project constitution at [`.specify/memory/constitution.md`](.specify/memory/constitution.md).

> **Hardware baseline:** an `arm64-v8a` Android device with ~8 GB RAM (the eligibility check passes at ~7 GB, since real 8 GB phones report 7.4–7.7 GB after kernel/DMA reservations). The model is large; older or low-RAM devices are blocked at a preflight gate rather than failing at load.

---

## Features

All features are gated by the model's reported capabilities (data-driven, never hardcoded per build) and surface a clean, monochrome Material 3 UI.

### Chat & model lifecycle
- **Streaming chat** with token-by-token rendering and Markdown formatting for assistant replies.
- **One-time model download** of Gemma 4 E2B (~2.4 GB) under an Android foreground service, with resumable progress and a reinstall fast-path. The model is stored in public shared storage so it survives an APK uninstall/reinstall — no 2.4 GB re-download every time.
- **Conversation history** with reactive list, rename-on-first-message, and per-conversation deletion.
- **Device preflight** — RAM and ABI eligibility is checked before the model loads; ineligible devices get a clear explanation instead of a crash.

### Multimodal input
- **Image (vision) input** — attach a single image from the camera or the Android Photo Picker (permissionless, per-image access). Pick-time downscaling keeps stored copies modest.
  > **Known limitation:** on the pinned `flutter_gemma 0.15.3` + Gemma 4 E2B combination, image *grounding* fails at the native/plugin layer on the verified test device (the model replies as if no image was provided). The Dart plumbing is correct; this is a vision-specific gap in the runtime, and it does not affect text, audio, or tools.
- **Audio / voice input** — record a voice clip (WAV 16 kHz mono PCM16, captured natively with no transcoding) up to 30 seconds. Voice transcription/grounding is verified working on-device.

### Function calling (on-device tools)
When the model decides it needs a tool, it calls one of four local, privacy-safe device tools — all executed on-device, none touching the network:

| Tool | What it does |
| --- | --- |
| `get_device_info` | Reports battery, storage, and device details. |
| `summarize_clipboard` | Reads the current text clipboard for the model to work with. |
| `set_theme` | Switches the app between dark and light. |
| `set_timer` | Hands a timer off to the system clock app via an Android intent. |

Tool activity is shown as inline chips so you can see exactly what ran.

### Long-term memory
- The assistant can **remember facts** about you across conversations (`remember_fact`) and **forget** them (`forget_fact`).
- Facts are stored locally, de-duplicated, capped, and grouped by category. They are injected as a native system instruction at session start, so the model carries context between chats.
- A full **memory management screen** lets you review, edit, clear, and disable saved facts at any time.

### Opt-in web research (off by default)
- **`web_search`** — bring-your-own-key search via [Tavily](https://tavily.com/), returning the top 3 results.
- **`fetch_page`** — a direct GET to a target website with on-device HTML text extraction, hard-bounded to keep results small.
- **Triple-gated:** web tools are only declared to the model when *function calling is supported*, *web access is enabled*, and *a valid API key is present*. If any condition is false the tools are structurally absent — never offered and then refused.
- **Three-state per-conversation override** (inherit global / explicitly on / explicitly off) lets you scope web access per chat.
- **Named recipients in the UI:** search chips read `WEB_SEARCH · Tavily`; fetch chips read `FETCH_PAGE · <domain>` (the actual site, not Tavily). Tappable source-URL chips appear beneath answers so you can verify where information came from.
- With web access off, behavior is byte-identical to the pre-web-research build, with zero network activity.

---

## Architecture

The codebase follows a strict layered architecture with a **plugin-seam discipline**: no widget, provider, or domain class ever imports a platform plugin or HTTP library directly. Every platform capability is named by an `abstract interface class` in `lib/domain/`, and the single concrete implementation lives in `lib/infrastructure/`. This makes every controller unit-testable with pure-Dart fakes — no mocking framework required — and lets CI mechanically prove the privacy boundary.

```
lib/
├── app/            App shell: bootstrap, routing (Navigator 1.0), theme tokens, root gate
├── core/           Pure data: tool registry, JSON-schema validator, model catalog, preflight
├── domain/         Entities (immutable value types) + service/repository interfaces (the seams)
├── data/           Drift/SQLite repositories, migrations, file stores, model downloader
├── infrastructure/ The only place plugins are touched:
│   ├── gemma/      flutter_gemma adapter (the single GemmaService seam)
│   ├── media/      image_picker, permission_handler, record, audioplayers
│   ├── tools/      battery_plus, android_intent_plus (device tools)
│   └── network/    http, html, flutter_secure_storage (web research + BYOK key)
└── features/       Feature surfaces: chat, settings, onboarding, download, history
```

Key architectural choices:

- **One model seam.** All flutter_gemma interaction — model load, kept-warm session management, streaming, tool-call replay — is confined to `lib/infrastructure/gemma/`. Everything else depends on the `GemmaService` interface.
- **Riverpod 3, manual Notifiers.** State is managed with hand-written `Notifier` classes (no `StateNotifier`/`ChangeNotifier`). Controllers hold no data themselves; UI reads reactive providers.
- **Drift over app-private SQLite.** Type-safe, reactive persistence (schema version 6). Timestamps are stored as ISO-8601 UTC text; the database lives in OS-encrypted app-private storage.
- **Sealed event/outcome types.** The generation stream yields a sealed `GenerationEvent` (`TextDelta` | `ToolCallRequested`); the dispatcher returns a sealed `ToolOutcome` and never throws — every consumer uses a compiler-checked exhaustive switch.

---

## Tech stack

| Concern | Choice |
| --- | --- |
| UI / runtime | Flutter + Dart (verified on stable Flutter 3.44.1 / Dart 3.12) |
| State management | `flutter_riverpod` 3.3.1 (manual Notifiers) |
| On-device model | `flutter_gemma` 0.15.3 (LiteRT-LM, Gemma 4 E2B) |
| Persistence | `drift` / `drift_flutter` over SQLite |
| Model download | `background_downloader` (Android foreground service) |
| Device preflight | `device_info_plus` |
| Image input | `image_picker` + `permission_handler` |
| Audio input | `record` + `audioplayers` |
| Device tools | `battery_plus`, `android_intent_plus` |
| Web research | `http` + `html` + `flutter_secure_storage` (all seam-isolated) |
| Markdown / fonts | `gpt_markdown`, `google_fonts` (runtime fetching disabled; fonts bundled) |

> `flutter_gemma` is intentionally pinned to `^0.15.0` (resolving to 0.15.3). **Do not bump to 0.16.x** — it regresses model loading on the baseline device. See the inline rationale in [`pubspec.yaml`](pubspec.yaml).

---

## Getting started

### Prerequisites

- **Flutter SDK** 3.44.x / stable channel. The Dart SDK constraint is `^3.10.7`; the project is built and verified on Dart 3.12.
- An **Android device or emulator** that is `arm64-v8a` with ~8 GB RAM. The model is large; low-RAM or non-arm64 devices are blocked at preflight.
- Roughly **3 GB of free storage** for the model file plus working space.
- A JDK for Android builds (Temurin 21 is recommended locally; CI uses Temurin 17 for the debug build).

### Setup

```bash
# 1. Install dependencies
flutter pub get

# 2. Generate Drift code (required before building — produces *.g.dart)
dart run build_runner build

# 3. Run on a connected Android device
flutter run -d <device-id>
```

> Note: `build_runner` is run without `--delete-conflicting-outputs` in this project; the bare command above is correct.

### First run

On first launch the app walks you through onboarding: a welcome screen, a license acknowledgement + device preflight, and then the **one-time model download** (~2.4 GB). The download runs under a foreground service and requests "all files access" once so the model can be stored in public storage (and survive future reinstalls). Once the model is installed, the app routes straight to chat.

To skip the long download during development, you can push a pre-downloaded model file to the device's `/storage/emulated/0/AiAssistant/models/` path. (Public download source: the [litert-community Gemma 4 E2B `.litertlm`](https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm) artifact — a plain GET, no auth token.)

### Enabling web research (optional)

Web research is off by default. To turn it on, go to **Settings → Web research**, paste a [Tavily](https://tavily.com/) API key (stored only in secure storage), and enable the global toggle. You can then override web access per-conversation from the composer.

---

## Project structure

```
ai_assistant/
├── lib/                  Application source (see Architecture above)
│   ├── app/              Shell, routing, theme
│   ├── core/             Tool registry, schema validator, model catalog
│   ├── domain/           Entities + seam interfaces (no plugin imports)
│   ├── data/             Drift repositories, migrations, file stores, downloader
│   ├── infrastructure/   Plugin adapters (gemma / media / tools / network)
│   └── features/         chat, settings, onboarding, download, history
├── test/                 Host-side unit + widget tests, fakes, migration proofs
├── integration_test/     On-device reliability harness (run via `flutter drive` only)
├── test_driver/          Driver entry point for the on-device harness
├── specs/                Spec-Kit feature specs (001…006), one folder per feature
├── tool/                 verify.sh + the two seam-guard scripts + branch protection
├── docs/                 ci-cd.md and other developer docs
└── .specify/             Project constitution + design system (governing documents)
```

---

## Testing & quality

All unit and widget tests run host-side with no device, fully isolated behind seam fakes:

```bash
flutter test                 # run the full host-side suite
flutter test --coverage      # with coverage

# Reproduce the entire CI pipeline locally (pub get, lockfile check, analyze,
# seam guards, codegen check, tests with coverage, debug APK build):
bash tool/verify.sh
SKIP_BUILD=1 bash tool/verify.sh   # skip the slow Android build while iterating
```

The two **seam guards** are the auditable enforcement of the privacy and testability invariants and must stay green:

```bash
bash tool/check_plugin_seam.sh    # each plugin confined to its infrastructure dir
bash tool/check_network_seam.sh   # http/html/secure-storage confined to lib/infrastructure/network/
```

> ⚠️ **Never run `flutter test integration_test/...`** — it uninstalls the app and wipes the ~2.4 GB model and the SQLite database. The on-device reliability harness must be run with `flutter drive --driver=test_driver/integration_test.dart --target=integration_test/<test>.dart -d <device-id>`.

For the full CI/CD breakdown (the three parallel jobs, the aggregated "CI Passed" check, and the release flow), see [`docs/ci-cd.md`](docs/ci-cd.md).

---

## Development workflow

This project is built with a **Spec-Kit spec-driven workflow**: every feature is specified, planned, and broken into tasks before implementation.

- Each feature lives in `specs/NNN-feature-name/` (e.g. `specs/006-web-research/`) and produces a canonical artifact set: `spec.md`, `plan.md`, `research.md`, `data-model.md`, `contracts/`, `quickstart.md`, and `tasks.md`.
- The flow is **specify → plan → tasks → implement**, with a Constitution Check gate that must pass before design and again before implementation.
- **Branch naming** is strictly `NNN-feature-name` (three-digit zero-padded prefix, kebab-case suffix).
- The governing [`.specify/memory/constitution.md`](.specify/memory/constitution.md) (currently v2.0.0) is the authority over architectural decisions — on-device only, offline-first, plugin-seam testability, and opt-in egress with a named recipient. The visual source of truth is [`.specify/memory/design-system.md`](.specify/memory/design-system.md).

Six features have shipped so far:

1. **001** — model download + streaming chat (foundation)
2. **002** — image (vision) input
3. **003** — audio / voice input
4. **004** — function calling (four on-device tools)
5. **005** — long-term memory
6. **006** — opt-in web research (Tavily BYOK + page fetch)

---

## Status & roadmap

The app is functional end-to-end on the baseline Android device. The web-research feature (006) is fully implemented and host-tested; the remaining open items are the on-device reliability harness run and the device walkthrough/accessibility gates.

Known limitations are documented honestly above and in the relevant `specs/` folders — most notably the image-grounding gap on `flutter_gemma 0.15.3` (vision-specific; text, audio, tools, memory, and web research are unaffected).
