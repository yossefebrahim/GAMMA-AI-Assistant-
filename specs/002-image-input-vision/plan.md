# Implementation Plan: Image Input — Visual Understanding

**Branch**: `002-image-input-vision` | **Date**: 2026-06-08 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `/specs/002-image-input-vision/spec.md`

## Summary

Add the assistant's first multimodal capability: from the chat screen the user attaches **one**
image (camera or photo library), previews it in the composer, and sends it alone or with a text
prompt; the assistant streams a reply about the image, and follow-up text turns keep referring to
that image within the conversation. The attach affordance is shown only when the active model
declares image support (capability as data — Constitution III), persists with the conversation
across restarts, and fails honestly (clear message, no hang/crash) when an image cannot be
processed or access is not granted.

Technical approach — extend the existing 001 architecture rather than reshape it:

- **Seam (Principle VII).** `GemmaService.generate` gains an optional image for the current prompt,
  and `ChatTurn` gains an optional image so follow-ups replay the earlier image as context. The
  concrete `FlutterGemmaService` (the only file allowed to import `flutter_gemma`) creates the chat
  with `supportImage` from the active model's declared capabilities and uses
  `Message.withImage(...)` / `Message.imageOnly(...)`. flutter_gemma's image error/OOM paths map to
  a typed failure surfaced as a clear message (Principle V).
- **Capabilities as data (Principle III).** The single-model `ModelCatalog` declares
  `supportsImage: true`; capabilities flow catalog → `loadModel` → `GemmaService.capabilities` →
  `modelCapabilitiesProvider`. The composer **already** gates the attach button on
  `capabilities.image` — this feature wires that stub to a real pick/preview/send flow and makes
  the gate flip live on model switch.
- **Acquisition behind new seams.** `MediaPickerService` (camera + library) and
  `MediaPermissionService` (status + open-settings) are domain interfaces with thin infrastructure
  implementations over `image_picker` / `permission_handler`, so the composer and a small
  attachment controller stay unit-testable with fakes.
- **Persistence.** Images are written as files in app-private `images/` (never BLOBs in SQLite);
  the `messages` table gains a nullable `imagePath` (+ `imageMimeType`) via a real drift
  **schemaVersion 1 → 2 migration** (001 has shipped). Deleting a conversation deletes its image
  files (the DB rows cascade; the files are cleaned explicitly).
- **UI.** The composer shows a monochrome preview (hairline border, no shadow) with a remove/replace
  control; `MessageBubble` renders the stored image in place inside the user turn; loading uses the
  dot-matrix pulse. Streaming, stop/cancel, sliding-window memory, and resource release all reuse
  the existing chat plumbing.

Library specifics (exact `flutter_gemma 0.15.3` image API, `image_picker`/`permission_handler`
versions and the Android permission model, off-isolate image preparation) are pinned in
[research.md](research.md). Entities, the schema migration, and state changes are in
[data-model.md](data-model.md); seam contracts and fakes in [contracts/](contracts/).

## Technical Context

**Language/Version**: Dart 3.x on Flutter (stable channel, 3.2x+). Matches 001.

**Primary Dependencies** (added by this feature, on top of the 001 stack):
- `image_picker` — camera capture + photo-library selection, behind `MediaPickerService`.
- `permission_handler` — camera/photo permission status and `openAppSettings()` for the
  permanently-denied path, behind `MediaPermissionService`.
- `flutter_gemma` **0.15.3** (already present) — image API now exercised: `createChat(supportImage:
  true)` (`enableVisionModality`), `Message.withImage` / `Message.imageOnly`, `addQueryChunk`, the
  built-in `ImageProcessor` (decode/validate/resize). Still confined to `lib/infrastructure/gemma/`.
- Image preparation (resize/normalize) uses the plugin's processor and/or an off-isolate path; a
  standalone `image` package is added only if research shows it is needed. Versions pinned in
  [research.md](research.md).

> **Version note**: the installed/verified runtime is `flutter_gemma 0.15.3` (pubspec.lock + the
> seam's own header comment + auto-memory), **not** the `0.16.4` named in the 001 docs/CLAUDE.md.
> This plan and CLAUDE.md are aligned to 0.15.3; the discrepancy is recorded in research R1.

**Storage**: unchanged backbone — `drift` over app-private SQLite (OS file-based encryption,
FR-024). Schema bumps to **v2**: `messages.imagePath TEXT?`, `messages.imageMimeType TEXT?`. Image
**bytes** live as app-private files under `…/images/` (not in the DB). Picked-image temp files from
`image_picker` are copied into app-private storage on send.

**Testing**: `flutter_test` unit + widget. New seams (`MediaPickerService`,
`MediaPermissionService`) get fakes alongside `FakeGemmaService`; `FakeGemmaService` is extended to
record the image passed to `generate` and the replayed history images. Repository/migration tests
use `NativeDatabase.memory()` plus a v1→v2 migration test. No device, plugin, or network in tests
(Principle VII).

**Target Platform**: Android, `arm64-v8a`, Android 10+ (API 29) baseline (unchanged). Photo-library
acquisition prefers the Android Photo Picker (permissionless on modern Android); camera requires the
`CAMERA` permission. New `AndroidManifest` entries: `CAMERA` (and the photo-picker/media access the
plugins require) — confirmed in research.

**Project Type**: Mobile application — single Flutter module, Android-first (unchanged).

**Performance Goals**: streaming token-by-token (FR-013); image-grounded first reply text within
20 s on the reference baseline device (SC-003 — higher than text's 5 s because the image is prepared
and encoded before prefill); UI gesture response within 100 ms while streaming (SC-010); image
decode/resize MUST NOT block the UI isolate (Principle IV).

**Constraints**: on-device only — image bytes, derived data, and analysis never leave the device,
and no new network call is introduced (Principle I); fully offline after install (Principle II);
exactly one model active with explicit release (Principle VIII); generation cancellable
(Principle IV); single image per message, input-only (Lean Scope IX); dark-first M3 with the
monochrome design identity and AA/48dp floor (Principles VI, X).

**Scale/Scope**: single local user; one image per image-bearing message; a handful of new
files/seams + one composer flow + one bubble change + one schema migration. ~1 new sub-feature
(attachment) layered onto the existing chat screen.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

Constitution version **1.2.0**. Status legend: ✅ satisfied by design · ⚠ implementation caution
(carried into research/tasks, not a deviation).

| # | Principle | Gate — how this plan satisfies it | Status |
|---|-----------|-----------------------------------|--------|
| I | Privacy Is the Product | No new network call. Image acquisition (`image_picker`), preparation, inference, and storage are all on-device; the only egress remains the one-time model download (untouched). The network-seam guard (`tool/check_network_seam.sh`) still covers the codebase. | ✅ |
| II | Offline-First | Attach, preview, send, image-grounded generation, history, and persistence all work with no connectivity. | ✅ |
| III | Capability-Driven UX | Attach affordance is rendered from `ModelCapabilities.image` (data from catalog→seam), never a per-model `if`. Control appears/disappears live on model switch; a pending image is cleared if the new model can't take it (FR-008). | ✅ (this feature realizes III for image) |
| IV | Responsive & Cancellable | Image decode/resize runs off the UI isolate; inference stays native/off-isolate; streaming + stop/cancel reuse the existing path. | ⚠ verify image prep is off-isolate (no jank); confirm stop during image-grounded gen |
| V | Graceful Degradation | Unprocessable/oversized/corrupt image and model/device limits surface a clear message — no hang, OOM, or crash (FR-020/FR-021). Permission-denied paths guide the user (FR-009/FR-010). | ⚠ map plugin image errors + OOM to typed, user-facing failures |
| VI | Dark-First & Accessible | New controls (attach, camera/library options, preview remove/replace, permission-prompt actions) meet 48dp + WCAG AA; the floor prevails over tokens. | ⚠ audit attach/remove control size + contrast; in-bubble image alt semantics |
| VII | Testable Through a Plugin Seam | All new `flutter_gemma` image usage stays in `lib/infrastructure/gemma/`. Picker/permission live behind their own domain interfaces with fakes; the chat/attachment controllers unit-test without plugins. | ✅ |
| VIII | Resource Hygiene | Pending image bytes released on send/clear; large bitmaps not retained; image files deleted when their conversation is deleted; single active model unchanged. | ⚠ ensure pending-bytes release + file cleanup on delete |
| IX | Lean Scope | Exactly the spec slice: one image, input-only. No generation/editing, multi-image, audio, files, annotation, function calling, or thinking — all explicit non-goals. | ✅ |
| X | Design Identity | Monochrome preview + in-bubble image, hairline borders, no gradients/shadows; dot-matrix pulse for image-prep/loading; red reserved for stop/error (remove is monochrome, not a destructive confirmation). Centralized tokens. | ✅ |

**Gate result**: PASS. No principle is violated; four ⚠ items are implementation cautions carried
into research and tasks. **Complexity Tracking is therefore empty.**

## Project Structure

### Documentation (this feature)

```text
specs/002-image-input-vision/
├── plan.md              # This file (/speckit-plan output)
├── research.md          # Phase 0 output — resolved technology decisions (image API, picker, perms)
├── data-model.md        # Phase 1 output — entity + schema-migration changes, state transitions
├── quickstart.md        # Phase 1 output — runnable validation guide
├── contracts/           # Phase 1 output — new/extended seam contracts
│   ├── gemma_service.md          # image extensions to the seam + FakeGemmaService
│   ├── media_picker.md           # MediaPickerService (camera + library)
│   ├── media_permission.md       # MediaPermissionService (status + open settings)
│   └── conversation_repository.md# image persistence extensions + file cleanup
├── checklists/
│   └── requirements.md  # spec quality checklist (from /speckit-specify)
└── tasks.md             # Phase 2 output (/speckit-tasks — NOT created here)
```

### Source Code (repository root) — changes layered on the existing tree

```text
lib/
├── core/
│   └── model_catalog.dart            # + supportsImage (and the ModelCapabilities it implies) as DATA
├── domain/
│   ├── entities/
│   │   ├── image_attachment.dart     # NEW — a persisted image bound to a message (path + mimeType)
│   │   ├── image_input.dart          # NEW — transient image bytes handed to the seam (pure Dart)
│   │   ├── chat_turn.dart            # + optional image (so follow-ups replay the image as context)
│   │   └── message.dart              # + optional ImageAttachment
│   ├── services/
│   │   ├── gemma_service.dart        # generate(... ImageInput? image); ChatTurn carries image
│   │   ├── media_picker_service.dart # NEW — pickFromCamera() / pickFromLibrary()
│   │   └── media_permission_service.dart # NEW — status + request + openSettings
│   └── repositories/
│       └── conversation_repository.dart  # appendUserMessage(... image); delete cleans files
├── data/
│   ├── db/
│   │   ├── tables.dart               # Messages + imagePath, imageMimeType (nullable)
│   │   ├── app_database.dart         # schemaVersion 2 + onUpgrade(addColumn)
│   │   └── daos/conversation_dao.dart# write/read the new columns
│   ├── images/
│   │   └── image_file_store.dart     # NEW — copy picked file → app-private images/, delete, read bytes
│   └── repositories/
│       └── drift_conversation_repository.dart # persist imagePath; delete image files on conv delete
├── infrastructure/                   # the ONLY place flutter_gemma is imported
│   ├── gemma/flutter_gemma_service.dart   # supportImage chat; Message.withImage; image-error mapping
│   ├── media/image_picker_service.dart    # NEW — image_picker impl of MediaPickerService
│   └── media/permission_handler_service.dart # NEW — permission_handler impl of MediaPermissionService
└── features/chat/
    ├── attachment_controller.dart    # NEW — pending attachment state (pick/preview/remove/replace) + perm flow
    ├── chat_controller.dart          # send(text, image?): persist image, pass ImageInput to generate
    ├── chat_providers.dart           # modelCapabilitiesProvider exists; wire picker/perm providers
    └── widgets/
        ├── composer.dart             # wire the existing capability-gated attach stub → real flow + preview
        ├── attachment_preview.dart   # NEW — composer preview (image + remove/replace), monochrome
        └── message_bubble.dart       # render the in-message image in place

test/
├── unit/                             # attachment_controller (fakes), chat_controller with image,
│                                     #   context_assembler with image turns, image_file_store, catalog caps
├── widget/                           # composer attach/preview/remove, gating flip on capability,
│                                     #   permission-explainer, bubble renders image
├── data/                             # drift v1→v2 migration test; repository image persistence + cleanup
└── helpers/                          # FakeMediaPickerService, FakeMediaPermissionService, extended FakeGemmaService

android/                             # CAMERA permission; photo-picker/media entries the plugins need
```

**Structure Decision**: Keep the 001 layered architecture (`domain` → `data`/`infrastructure` →
`features`) and extend it. Three new seams keep all platform plugins (`flutter_gemma`,
`image_picker`, `permission_handler`) out of domain/presentation so the new logic is unit-testable.
The plugin-seam guard (Principle VII) is unchanged: `flutter_gemma` stays only in
`lib/infrastructure/gemma/`; `image_picker`/`permission_handler` are confined to
`lib/infrastructure/media/`. No new layer or pattern is introduced.

## Complexity Tracking

No constitution violations — this section is intentionally empty. The design adds the minimum
needed (image-bearing seam, two acquisition seams, one schema column-add migration, a file store,
and the composer/bubble UI) and reuses the existing streaming, memory, persistence, capability, and
resource-management machinery rather than duplicating it.

## Post-Design Constitution Re-Check

After Phase 1 (research + data model + contracts), the gate is re-evaluated. **Result: PASS.** The
four implementation-caution (⚠) items now have concrete designs and no new violation was introduced.

- **IV — Responsive & Cancellable (⚠ → ✅)**: image decode/resize runs off the UI isolate (the
  plugin's `ImageProcessor` and/or an isolate; see research R1/R4); inference remains native and
  streams; stop = existing `stopGeneration()` + subscription cancel, which works identically for an
  image-grounded turn (the partial reply is retained, FR-014).
- **V — Graceful Degradation (⚠ → ✅)**: the seam maps flutter_gemma image/decoding/OOM errors to a
  typed `ImageProcessingException`; the chat controller catches it, finalizes the assistant turn
  cleanly, and surfaces a clear message (FR-020). Oversized/corrupt picks are rejected at the store
  with a "pick another" message (FR-021). Permission paths route to an explainer / settings
  (FR-009/FR-010) — see [media_permission.md](contracts/media_permission.md).
- **VI — Dark-First & Accessible (⚠ → ✅)**: attach + camera/library + remove/replace controls are
  wrapped to ≥48dp and use AA-passing tokens (icons on `#000000`/surfaces meet the icon 3:1 floor;
  any text label uses `textSecondary`, never `textMuted`); the in-bubble image carries a semantic
  label. Reuses the 001 contrast rule (001 research R6).
- **VIII — Resource Hygiene (⚠ → ✅)**: the attachment controller holds only a file reference (not
  decoded bytes) for the preview; bytes are read just-in-time for `generate` and not retained; the
  repository deletes a conversation's image files before/with the cascade delete
  ([conversation_repository.md](contracts/conversation_repository.md)).

**New-artifact compliance:**

| Principle | Honored by design artifacts |
|-----------|-----------------------------|
| I Privacy | No service performs network I/O; image stays on-device ([contracts](contracts/)) |
| III Capability-Driven | `ModelCapabilities.image` flows catalog→seam→`modelCapabilitiesProvider`; UI gates on data — [gemma_service.md](contracts/gemma_service.md) |
| V Graceful Degradation | `ImageProcessingException` + permission states drive honest messages — [gemma_service.md](contracts/gemma_service.md), [media_permission.md](contracts/media_permission.md) |
| VII Plugin Seam | `flutter_gemma`→`infrastructure/gemma/`, picker/permission→`infrastructure/media/`; all seams have fakes — [contracts](contracts/) |
| VIII Resource Hygiene | file-backed images, just-in-time byte reads, delete-time file cleanup — [conversation_repository.md](contracts/conversation_repository.md), [data-model.md](data-model.md) |
| X Design Identity | monochrome preview/bubble, dot-matrix loading, red reserved — tokens centralized |

Gate clear → ready for `/speckit-tasks`. Complexity Tracking remains empty.
