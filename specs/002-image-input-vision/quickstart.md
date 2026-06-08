# Quickstart & Validation: Image Input — Visual Understanding

**Feature**: `002-image-input-vision` | **Date**: 2026-06-08

How to build, run, and **prove** image input works end-to-end. Validation scenarios map to the
spec's user stories (US1–US6) and success criteria (SC-001…SC-011). Implementation lives in
`tasks.md`; this is a run/verify guide. Builds on the 001 quickstart — only the image-specific
additions are detailed here.

## Prerequisites

- The 001 prerequisites (Flutter stable 3.2x+ / **Flutter 3.44.1** here, Android toolchain, Kotlin
  2.1.0+) plus a **physical** `arm64-v8a`, **≥ 8 GB RAM**, Android 10+ device **with a camera and
  some photos** in the library. (Emulators fail the 001 ABI preflight by design.)
- An **image-capable** model installed (Gemma 4 E2B — the default; `ModelCatalog.supportsImage ==
  true`). The 001 download flow installs it.
- New dependencies (pinned in [research.md](research.md)): `image_picker`, `permission_handler`.
- `AndroidManifest.xml` includes `CAMERA` (and any media entries the plugins require).

## Build & run

```bash
flutter pub get
dart run build_runner build --delete-conflicting-outputs   # drift codegen — REQUIRED (schema v2)
flutter run --release -d <android-device-id>               # release ≈ realistic inference speed
```

> Run `build_runner` after the schema change (`messages.imagePath/imageMimeType`, schemaVersion 2)
> or the app won't compile. Use `--release` for any timing check (SC-003/SC-010).
> **Upgrade check**: install the *previous* (001/v1) build first, hold a text conversation, then
> install this build over it and confirm the old conversation still opens (v1→v2 migration, R5).

## Test suite

```bash
flutter test                      # unit + widget + data (no device, no native plugin, no network)
flutter test test/unit            # attachment & chat controllers, context assembler (image turns)
flutter test test/widget          # composer attach/preview/remove, gating flip, permission explainer, bubble
flutter test test/data            # drift v1→v2 migration; repository image persistence + cleanup
./tool/check_plugin_seam.sh       # flutter_gemma confined to lib/infrastructure/gemma/ (Principle VII)
./tool/check_network_seam.sh      # no new network egress (Principle I)
```

All unit/widget/data tests run against the seam fakes (`FakeGemmaService` extended for images,
`FakeMediaPickerService`, `FakeMediaPermissionService`) + an in-memory `drift` DB + a temp-dir
image store — no model file, no device, no network (Principle VII).

---

## Manual validation scenarios

### V1 — Attach & reply, library + camera (US1: SC-001, SC-003)

1. In chat with the image-capable model, the composer shows the **attach** control (left of the
   field). Tap it → choose **photo library** → pick one image → it appears as a **preview** in the
   composer.
2. Send with **no text** → the image appears inside the user message; the assistant streams a reply
   **about** the image; first words within ~20 s on the baseline device (SC-003).
3. Repeat with **camera**: attach → camera → capture → preview → add the text "what's in this
   picture?" → send → reply addresses the prompt in the image's context.
   - ✅ Expected: preview before send; image rendered in the user bubble; reply streams incrementally.

### V2 — Preview controls: remove & replace (US1: FR-002/FR-003)

1. Attach an image → in the preview, tap **remove** → preview clears, no attachment on next send.
2. Attach again → without sending, pick **another** image → the preview is **replaced** (still one
   image).
   - ✅ Expected: at most one image; remove and replace behave as described; remove is **monochrome**
     (not red).

### V3 — Capability gating & history retention (US2: SC-002, SC-004)

1. With the image-capable model active → attach control **present**.
2. Switch to a text-only model (use a text-only catalog entry or a `FakeGemmaService` with
   `image:false` in a widget test) → attach control **gone**; text chat still works.
3. Switch back → control **reappears** (no app restart).
4. In a conversation that already has a sent image, switch to a text-only model and reopen it → the
   earlier image is **still shown** in history (SC-004).
   - ✅ Expected: control tracks `capabilities.image` (data); already-sent images persist in view.

### V4 — Follow-up memory about the image (US3: SC-006)

1. After V1, send a text-only follow-up that depends on the image (e.g. "what color is it?").
2. ✅ Expected: the reply reflects the previously shown image **without** re-attaching. (Determinism
   note: FR-016 is verified in a unit test by inspecting the **assembled context** — the prior image
   turn is present; the manual check is a sanity pass.)

### V5 — Permission guidance, no silent failure (US4: SC-007)

1. With camera access **not** granted, tap attach → **camera** → an explainer states why access is
   needed and offers to grant/continue.
2. Deny → a clear message appears; **text chat still works** (FR-011).
3. Set the camera permission to "don't ask again", retry → explainer routes to **system settings**
   (`openAppSettings`).
   - ✅ Expected: every attempt yields guidance with a next action; zero silent no-ops (SC-007).

### V6 — Persistence across restart (US5: SC-005)

1. Send an image (with and without text) → **force-quit** and relaunch → reopen the conversation.
2. ✅ Expected: the image is shown **in place** and message order is intact (SC-005). Continue the
   conversation and confirm the image is still part of its history.

### V7 — Honest handling of an unprocessable image (US6: SC-008)

1. Send an image the device/model can't process (e.g. force an `ImageProcessingException` via the
   fake in a widget test; on-device, an extreme image on the 8 GB baseline).
2. ✅ Expected: a clear "couldn't process this image" message; the conversation stays usable; **no**
   crash, OOM, or indefinite hang (SC-008).
3. While an image-grounded reply streams, tap **stop** → halts promptly, partial text retained
   (FR-014).

### V8 — Offline & privacy (SC-009) — the headline guarantee

1. After install, enable **airplane mode**.
2. Attach + send an image, get a reply, ask ≥ 3 image-referencing follow-ups.
3. ✅ Expected: everything works offline; with a network monitor over the app's lifetime, the **only**
   network activity remains the one-time model download — **no** request carries image content
   (SC-009, Principle I). `./tool/check_network_seam.sh` stays green.

### V9 — Accessibility (SC-011, Principle VI)

1. Run the Android Accessibility Scanner over the composer (with a pending preview) and a
   conversation containing an image.
2. ✅ Expected: attach, camera/library, and remove/replace controls are ≥ 48dp; icons/text meet AA
   (labels use `textSecondary`, never `textMuted`); the in-bubble image exposes a semantic label.

---

## Done = all green

- `flutter test` passes (unit + widget + data, via seam fakes + in-memory drift + temp image store),
  including the **v1→v2 migration** test.
- Both seam guards pass (`check_plugin_seam.sh`, `check_network_seam.sh`).
- V1–V9 manual scenarios pass on a baseline device.
- Airplane-mode run (V8) shows zero content-bearing network calls — the privacy guarantee holds with
  images.
