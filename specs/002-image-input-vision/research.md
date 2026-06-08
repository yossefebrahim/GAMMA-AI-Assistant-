# Phase 0 Research: Image Input — Visual Understanding

**Feature**: `002-image-input-vision` | **Date**: 2026-06-08

Resolves the technology unknowns for adding single-image visual understanding. The stack is fixed
by the constitution and the 001 slice (Flutter/Dart, Riverpod, drift, **flutter_gemma 0.15.3**,
Gemma 4 E2B); this phase pins the **image API actually present in the installed plugin**, the
acquisition + permission packages, image preparation, and persistence. Findings were verified
against the installed package source in `~/.pub-cache` and the local toolchain
(**Flutter 3.44.1 stable / Dart ^3.10.7**) as of June 2026.

## Pinned dependencies

| Concern | Package | Version | Notes |
|---------|---------|---------|-------|
| Model runtime (already present) | `flutter_gemma` | **`0.15.3`** (resolved) | Image API present: `Message.withImage`, `createChat(supportImage:)` → `enableVisionModality`, built-in `ImageProcessor`. Pubspec constraint stays `^0.15.0`. |
| Image acquisition | `image_picker` | `^1.2.0` (pin highest SDK-compatible) | Camera capture + Android Photo Picker for the library; supports `maxWidth/maxHeight/imageQuality` downscale at pick time. |
| Permissions | `permission_handler` | `^12.0.0` (pin highest SDK-compatible) | `Permission.camera` status/request + `openAppSettings()` for the permanently-denied path. |
| Image bytes for the model | `dart:typed_data` / `dart:io` | SDK | Read the stored file's bytes just-in-time; no extra package. |

> **Verify at `pub get`**: confirm the highest `image_picker` / `permission_handler` that resolve
> against Dart ^3.10.7 / Flutter 3.44.1 (same discipline 001 used for `device_info_plus`). A
> standalone `image` package is **not** added — pick-time downscale + the plugin's `ImageProcessor`
> cover sizing (R4).

---

## R1 — flutter_gemma image API (verified against installed 0.15.3)

**Decision**: Drive image input through the **existing `GemmaService` seam**, extended with an
optional image for the current prompt and an optional image on each history `ChatTurn`. Inside
`FlutterGemmaService` (the only file that imports `flutter_gemma`):
- Create the chat with vision enabled when the active model supports it:
  `model.createChat(modelType: ModelType.gemma4, supportImage: caps.image, …)` — internally sets
  `enableVisionModality: supportImage`. (Currently hardcoded `supportImage: false`; flip to the
  capability value.)
- Send an image-bearing prompt with `Message.withImage(text: prompt, imageBytes: bytes, isUser: true)`
  (or `Message.imageOnly(imageBytes: bytes)` when there is no text), passed to `addQueryChunk(...)`.
- Replay a prior image turn in `clearHistory(replayHistory: [...])` using the same
  `Message.withImage(...)` so follow-ups keep the image in context (FR-015/FR-016).
- Stream + stop unchanged: map `TextResponse.token` → `Stream<String>`; `stopGeneration()` + cancel
  the Dart subscription (FR-014).

**Verified API surface (0.15.3, wrapped — never leaked):**
- `class Message` with `final Uint8List? imageBytes; final List<Uint8List> images; bool get hasImage`.
- Factories: `Message.text({text, isUser})`, `Message.withImage({text, imageBytes, isUser})`,
  `Message.imageOnly({imageBytes, isUser, text=''})` (also `withImages`/`imagesOnly` — unused; single
  image this phase).
- `createChat({ModelType modelType, int? maxNumImages, bool? supportImage, bool? supportsFunctionCalls,
  bool isThinking, …})` → `enableVisionModality: supportImage ?? false`. Set `maxNumImages: 1`.
- `ImageProcessor.processImage(...)`: decodes, validates (`_maxFileSize = 10 MB`, rejects empty),
  and resizes to **896×896** (`_targetWidth/_targetHeight`) before the model sees it.
- Low-level `addImage(Uint8List)` exists on the pigeon channel but the `Message.withImage` +
  `addQueryChunk` path is the supported high-level route — use it.

**Rationale**: the seam already centralizes load/generate/stop/close; adding an optional image keeps
domain/presentation plugin-free (Principle VII). `Message.withImage` + `enableVisionModality` is the
documented multimodal path in 0.15.3 and Gemma 4 E2B is image-capable per the constitution.

**Capabilities as data (Principle III)**: the single-model `ModelCatalog` declares
`supportsImage: true`; the value is passed into `loadModel` and returned by
`GemmaService.capabilities` (replacing the hardcoded `ModelCapabilities.textOnly`). The composer
already reads `modelCapabilitiesProvider` — no per-model `if` anywhere in the UI.

**Alternatives rejected**: a separate "vision service" (duplicates the seam, two model handles —
violates single-active-model VIII); low-level `addImage` pigeon call (bypasses message templating);
hardcoding `supportImage: true` in the UI (violates III — capabilities must be data).

**Risks carried forward**:
- **Version discrepancy**: 001 docs/CLAUDE.md say `flutter_gemma 0.16.4`; the **installed/verified**
  runtime is **0.15.3** (pubspec.lock, the seam's header comment, and auto-memory
  `model-download-url-placeholder.md`). This plan + CLAUDE.md are aligned to 0.15.3. If the team
  later bumps to 0.16.x, re-verify `Message.withImage`/`createChat` signatures.
- **History replay with images**: confirm `clearHistory(replayHistory:[Message.withImage(...)])`
  re-ingests the image on each turn on 0.15.3. If replaying images is unreliable or too slow,
  fall back to keeping the chat session warm (don't `clearHistory` every turn) — a scoped change
  inside the seam only. Verify on the A34 before finalizing.
- **GPU/vision memory**: vision prefill is heavier; on an 8 GB device the GPU backend may OOM. Reuse
  the existing GPU→CPU fallback in `loadModel`; surface load/runtime failure as a clear message (V).

---

## R2 — Image acquisition (camera + photo library)

**Decision**: Use **`image_picker`** behind a `MediaPickerService` seam with two methods:
`pickFromCamera()` and `pickFromLibrary()`. Downscale at pick time
(`pickImage(source:, maxWidth: 1536, maxHeight: 1536, imageQuality: 90)`) so the stored copy is
modest and stays under the plugin's 10 MB ceiling (R1/R4). Returns a small
`PickedImage(path, mimeType)` (the picker's temp-file path) or `null` if the user cancels.

**Rationale**: `image_picker` is the standard, well-maintained Flutter plugin for both **camera
capture** and **photo-library selection**, and on Android 13+ its gallery path uses the system
**Photo Picker**, which needs **no storage permission** (the user grants access to the single image
they choose). Confining it to `lib/infrastructure/media/` keeps the composer/attachment controller
unit-testable with a `FakeMediaPickerService` (Principle VII discipline, even though VII names only
flutter_gemma).

**Mechanics**:
- `final picker = ImagePicker();`
- Library: `picker.pickImage(source: ImageSource.gallery, maxWidth: 1536, maxHeight: 1536, imageQuality: 90)`.
- Camera: `picker.pickImage(source: ImageSource.camera, …)`.
- A returned `XFile` → copy into app-private `images/` on **send** (R5), not at pick time, so a
  cancelled compose leaves nothing persisted.
- Single image only (`pickImage`, never `pickMultiImage`) — FR-002.

**Alternatives rejected**: `file_picker` (document-centric; pulls non-image files — out of scope);
raw platform channels to the Photo Picker / camera intents (re-implements `image_picker`);
`pickMultiImage` (multi-image is out of scope).

**Risks**: camera capture still requires the `CAMERA` permission (R3); some OEMs route
`ImageSource.gallery` to a non-photopicker file UI on older Android (then `READ_MEDIA_IMAGES` may be
needed) — handle the resulting denial through the permission flow (R3); `image_picker` can return
HEIC on some devices — the plugin's decoder handles common formats, and unsupported/corrupt bytes
are caught at the store/seam and reported (FR-021).

---

## R3 — Permissions (explain, request, guide to settings)

**Decision**: Use **`permission_handler`** behind a `MediaPermissionService` seam exposing the
camera permission lifecycle (`status`, `request`, `openSettings`). Treat the photo **library** as
permissionless on modern Android (the Photo Picker grants per-image access); only **camera** needs
an explicit runtime grant. Drive the FR-009/FR-010 flow as:

```
camera tapped → status:
  granted               → open camera
  denied (askable)      → request(); if granted → camera, else show explainer
  permanentlyDenied     → explainer + "open settings" (openAppSettings())
  restricted            → explainer (cannot change here)
library tapped          → open Photo Picker directly (no permission prompt on modern Android);
                          if a legacy device denies media access → same explainer + settings path
```

**Rationale**: `permission_handler` gives the status granularity (`denied` vs `permanentlyDenied`)
needed to choose between "request again" and "guide to settings", plus `openAppSettings()` — exactly
what FR-009/FR-010 require (no silent failure). Behind a seam, the explainer/settings logic is
unit-testable with a `FakeMediaPermissionService` that scripts each status.

**Android manifest**: add `<uses-permission android:name="android.permission.CAMERA"/>`. The Photo
Picker requires no gallery permission; if a legacy fallback is kept, add the scoped
`READ_MEDIA_IMAGES` (Android 13+) — decide during implementation based on the minSdk-29 matrix.
`image_picker` already declares what it needs; confirm the merged manifest.

**Alternatives rejected**: reading permission state via `image_picker` alone (it surfaces failures
but not a clean `permanentlyDenied` distinction or a settings entry point); `app_settings` package
(redundant — `permission_handler` opens settings); requesting storage broadly (the Photo Picker
makes it unnecessary and would over-ask, hurting trust — Principle I posture).

**Risks**: behavior differs across Android versions (pre-13 vs 13+); the "if the user declines, text
chat still works" guarantee (FR-011) must be enforced in the controller, not assumed; an explainer
must never dead-end — always offer a next action.

---

## R4 — Image preparation (off-isolate, sizing, honest failure)

**Decision**: Two-stage, both off the UI isolate:
1. **At pick** — `image_picker` downscales (`maxWidth/maxHeight 1536`, `imageQuality 90`) natively
   (off the Dart isolate). This bounds the stored file and keeps it under the 10 MB cap.
2. **At inference** — flutter_gemma's `ImageProcessor` decodes/validates/resizes to **896×896**
   inside the plugin before prefill. The seam passes raw bytes; the plugin owns model-facing
   normalization.

If any additional Dart-side processing is ever needed, run it via `compute()` (a background isolate)
— **never** on the UI isolate (Principle IV). No standalone `image` package is required for this
phase.

**Honest failure (FR-020/FR-021, Principle V)**: the seam wraps image generation in a try/catch and
maps decode/validation/size/OOM errors to a typed **`ImageProcessingException`**. The chat
controller catches it, finalizes the assistant turn without a hang, and the UI shows a clear "couldn't
process this image" message. Oversized (>10 MB after pick) or corrupt picks are rejected at
`ImageFileStore` with a "pick another" message before any model call.

**Rationale**: doing the heavy resize natively (picker) + in-plugin (`ImageProcessor`) keeps the Dart
UI isolate free and avoids a second full decode in Dart. Typed failures make graceful degradation
testable with `FakeGemmaService` (script an `ImageProcessingException`).

**Alternatives rejected**: decoding/resizing in Dart on the main isolate (jank — violates IV);
sending full-resolution camera images (risks the 10 MB cap and slow prefill); silently dropping a
bad image (violates V — the user must be told).

**Risks**: first image-grounded reply latency is materially higher than text (prep + vision prefill)
— SC-003 targets 20 s on the baseline, to be confirmed on the A34; very large panoramas may still
strain an 8 GB device → the OOM path must degrade honestly.

---

## R5 — Persistence (image files + drift v1→v2 migration + context replay)

**Decision**: Store image **bytes as files**, not DB BLOBs. `ImageFileStore` (in `lib/data/images/`)
copies the picked temp file into app-private `…/images/<unique>.<ext>` on send and returns the
stored path; `messages` gains nullable **`imagePath`** and **`imageMimeType`** columns. Bump
`schemaVersion` **1 → 2** with a real `onUpgrade` that `addColumn`s both (001 has shipped, so
`createAll` alone is insufficient for upgraders).

**Mechanics**:
- `app_database.dart`: `schemaVersion => 2`; `onUpgrade: (m, from, to) async { if (from < 2) { await
  m.addColumn(messages, messages.imagePath); await m.addColumn(messages, messages.imageMimeType); } }`
  (keep `beforeOpen` `PRAGMA foreign_keys = ON`). Regenerate `app_database.g.dart` via build_runner.
- `appendUserMessage(conversationId, text, {ImageAttachment? image})` writes the path/mime; the
  message entity gains an optional `ImageAttachment` (R: data-model).
- **Context replay (FR-015/FR-016)**: `ChatTurn` gains an optional image; the context assembler
  carries the stored image forward; the chat controller reads the file bytes **just-in-time** and
  hands them to `generate`/replay (bytes are not held in memory between turns — Principle VIII).
- **Cleanup (FR-019)**: `deleteConversation` first reads its messages' `imagePath`s and deletes those
  files, then deletes the conversation row (messages cascade). No orphan files.

**Rationale**: multi-MB images as SQLite BLOBs bloat the DB, slow `watch()` queries, and load into
memory on every row read; files are the right store, with the DB holding a path. App-private storage
inherits OS file-based encryption (FR-024), same guarantee as the DB. A column-add migration is the
standard, low-risk drift upgrade.

**Alternatives rejected**: BLOB-in-SQLite (memory/perf cost on a reactive list query); a separate
images table (over-modeled for a 1:0..1 message→image relationship — a nullable column is enough);
re-deriving images from the picker cache (the OS purges caches — history would lose images, breaking
FR-018).

**Risks**: a crash between file-write and row-commit could orphan a file — acceptable (a startup
sweep can be added later; out of scope now); migration must be covered by a v1→v2 test
(`NativeDatabase.memory()` seeded at v1) so existing users don't lose data.

---

## R6 — UI: composer preview, in-bubble image, accessibility

**Decision**:
- **Composer** ([composer.dart](../../lib/features/chat/widgets/composer.dart)): the existing
  `if (capabilities.image) IconButton(Icons.add_photo_alternate_outlined …)` stub is wired to an
  attachment flow — tapping offers **camera** / **photo library** (a small monochrome sheet/menu).
  When an image is pending, an `AttachmentPreview` (thumbnail + a remove "×", tap-to-replace) sits
  above/inside the input; send is enabled when there is an image OR text (FR-004). Switching to a
  text-only model clears a pending image with a brief note (FR-008).
- **Bubble** ([message_bubble.dart](../../lib/features/chat/widgets/message_bubble.dart)): when a
  user message has an `imagePath`, render the image (rounded, hairline border, `BoxFit` contained,
  capped height) **above** any text, in place, from the file. Reuse the existing
  alignment/fill/no-color rules. A failed-to-load file shows a quiet monochrome placeholder.
- **Design tokens (Principle X)**: monochrome surfaces, `outline` hairline border, **no
  gradient/shadow**; loading/image-prep uses the **dot-matrix pulse** (`DotPulse`), not a spinner;
  the **remove** control is monochrome (it is a minor remove, not a destructive *confirmation*, so it
  does **not** use the red accent — red stays reserved for stop/recording/error).
- **Accessibility (Principle VI)**: every new control wrapped to **≥48dp**; icons meet the 3:1 icon
  floor on `#000000`/surfaces; any text label uses `textSecondary #A0A0A0` (8.03:1), **never**
  `textMuted #5C5C5C` (3.14:1 — fails AA), per the 001 contrast rule (001 research R6). The in-bubble
  image carries a `Semantics(label: 'attached image')` for screen readers.

**Rationale**: reusing the design system and the already-present capability gate keeps the feature
coherent and on-identity; file-backed `Image.file` avoids holding decoded bytes in widget state.

**Alternatives rejected**: a full-screen image picker route (heavier than an inline preview;
inconsistent with the inline composer); red remove button (violates the accent-discipline rule);
`Image.memory` from retained bytes (memory cost — VIII).

---

## Resolved unknowns (Technical Context)

| Unknown | Resolution |
|---------|-----------|
| flutter_gemma image API on the installed version | R1 — 0.15.3 `Message.withImage`/`imageOnly` + `createChat(supportImage:)`; behind `GemmaService` |
| How capability gates the attach control | R1 — `ModelCatalog.supportsImage` (data) → `loadModel` → `capabilities` → `modelCapabilitiesProvider`; composer stub already gates on it |
| Acquiring an image (camera + library) | R2 — `image_picker` behind `MediaPickerService`; Android Photo Picker for gallery; pick-time downscale |
| Permission explain/request/settings | R3 — `permission_handler` behind `MediaPermissionService`; camera grant + `openAppSettings()`; library permissionless |
| Image preparation + off-isolate + failure | R4 — native pick-time resize + plugin `ImageProcessor` (896², 10 MB); `ImageProcessingException` for honest failure |
| Persisting images + schema change + replay | R5 — file store + `messages.imagePath/imageMimeType`, drift **v1→v2** migration; `ChatTurn` carries image for follow-ups |
| Composer preview, in-bubble image, a11y | R6 — monochrome preview + `Image.file` bubble; ≥48dp / AA; dot-matrix loading; red reserved |

All Technical Context unknowns are resolved. No `NEEDS CLARIFICATION` remains for Phase 1.
