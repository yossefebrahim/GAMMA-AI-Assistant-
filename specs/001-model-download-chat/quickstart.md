# Quickstart & Validation: Model Download & Chat

**Feature**: `001-model-download-chat` | **Date**: 2026-06-07

How to build, run, and **prove** this feature works end-to-end. Validation scenarios map to the
spec's user stories (US1–US5) and success criteria (SC-001…SC-012). Implementation lives in
`tasks.md`; this is a run/verify guide.

## Prerequisites

- Flutter stable (3.2x+) with the Android toolchain; **Kotlin 2.1.0+** (required by
  `background_downloader`).
- A **physical** Android device, `arm64-v8a`, **≥ 8 GB RAM**, Android 10+ (the baseline; emulators
  fail the ABI preflight by design).
- The default model published at an open, redistributable URL (clarification Q1) reachable for the
  one-time download.
- Dependencies (see [research.md](research.md) for pinned versions): `flutter_gemma`,
  `background_downloader`, `drift`/`drift_flutter`/`drift_dev`, `device_info_plus`,
  `flutter_riverpod`, `path_provider`, `google_fonts` (offline) + bundled fonts.

## Build & run

```bash
flutter pub get
dart run build_runner build --delete-conflicting-outputs   # drift codegen
flutter run --release -d <android-device-id>               # release ≈ realistic inference speed
```

> Use `--release` for any timing check (SC-004/SC-011); debug-mode inference is much slower.

## Test suite

```bash
flutter test                      # unit + widget tests (no device, no native plugin, no network)
flutter test test/unit            # domain, context assembler, controllers (FakeGemmaService)
flutter test test/widget          # screen widget tests
```

All unit/widget tests run against the seam fakes (`FakeGemmaService`, `FakeModelDownloader`,
`FakeDevicePreflightService`) and an in-memory `drift` DB — so they need no model file, no network,
and no device (Principle VII).

---

## Manual validation scenarios

### V1 — Onboarding & download (US1: SC-001, SC-002, SC-003)

1. Fresh install → app opens to a **dark** welcome screen explaining on-device privacy.
2. Tap through the one-time license acknowledgment → device preflight passes (supported device).
3. Start the download → a **dot-matrix `%`** + thin progress bar + bytes readout updates ≥ 1×/sec.
4. Navigate within the app while downloading → download continues, UI stays responsive.
5. Tap **cancel** → stops within 2 s; reopening shows the pre-download state (no partial model).
6. Restart the download → on completion the app routes into chat.
   - ✅ Expected: progress always visible (SC-002); cancel ≤ 2 s with no leftover model (SC-003).

### V2 — Streaming chat with stop (US2: SC-004, SC-005, SC-011)

1. In chat, type a message and send.
2. The reply renders **incrementally** (multiple visible updates), first words within ~5 s on the
   baseline device (SC-004); the **send control is replaced by a red stop control** while
   generating (Q4).
3. While streaming, scroll the conversation → stays responsive (SC-011).
4. Tap **stop** mid-reply → text halts within 1 s; the partial reply remains in the thread (SC-005).
   - ✅ Expected: no single-block reply; stop retains 100% of produced text.

### V3 — Conversational memory (US3)

1. Send a message establishing a fact; send a follow-up that depends on it.
2. ✅ Expected: the reply reflects the earlier turn. (Determinism note: FR-017 is verified by
   inspecting the **assembled context** in a unit test — the manual check is a sanity pass.)

### V4 — Persistence & history (US4: SC-006)

1. Hold a conversation; **force-quit** and relaunch.
2. ✅ Expected: the conversation and messages are intact and correctly ordered (SC-006).
3. Start a **new** conversation → both appear in the history list with first-message-derived labels
   + timestamps; open each; **delete** one → it disappears and its messages are unretrievable.

### V5 — Device preflight (US5: SC-008)

1. On an unsupported device (or via `FakeDevicePreflightService` in a widget test): < 7000 MB RAM
   or non-`arm64-v8a`.
2. ✅ Expected: a clear message names the reason **before** any download; no download starts; no
   crash/OOM.

### V6 — Offline & privacy (SC-007, SC-009) — the headline guarantee

1. After install, enable **airplane mode**.
2. Create a conversation, exchange ≥ 5 turns, reopen a past conversation, browse history.
3. ✅ Expected: everything works with zero connectivity failures (SC-007).
4. With a network monitor / proxy over the app's full lifetime: ✅ the **only** network activity is
   the one-time model download; no request carries conversation content (SC-009, Principle I).

### V7 — Accessibility (SC-012, FR-031)

1. Run the Android Accessibility Scanner over each screen.
2. ✅ Expected: all interactive controls ≥ 48dp; text meets WCAG AA. **In particular**, conversation
   timestamps use `textSecondary #A0A0A0` (8.03:1), **not** `textMuted #5C5C5C` (3.14:1 — fails AA);
   see [research.md](research.md) R6.

### V8 — Resource hygiene (FR-029, Principle VIII)

1. Open chat (model loads), then leave the chat screen / background the app.
2. ✅ Expected: model/session released (memory drops); persisted conversations intact; exactly one
   model ever active.
3. In settings, view the model's on-disk size and **delete** it → space reclaimed, app returns to
   onboarding; re-download succeeds.

---

## Done = all green

- `flutter test` passes (unit + widget, via seam fakes + in-memory drift).
- V1–V8 manual scenarios pass on a baseline device.
- Airplane-mode run (V6) shows zero content-bearing network calls — the privacy guarantee holds.
