---

description: "Task list for Image Input — Visual Understanding"
---

# Tasks: Image Input — Visual Understanding

**Input**: Design documents from `/specs/002-image-input-vision/`
**Prerequisites**: [plan.md](plan.md), [spec.md](spec.md), [research.md](research.md),
[data-model.md](data-model.md), [contracts/](contracts/), [quickstart.md](quickstart.md)

**Tests**: INCLUDED. The constitution (Principle VII + the Test Quality Gate) makes
domain/presentation unit-testability mandatory, and capability-gating (Principle III) must be
unit-tested against representative capability data. Every story carries test tasks built on the seam
fakes (`FakeGemmaService` extended for images, `FakeMediaPickerService`, `FakeMediaPermissionService`,
`FakeConversationRepository`) + an in-memory `drift` DB + a temp-dir image store — no native plugin,
no device, no network.

**Organization**: Tasks are grouped by user story (US1–US6 from the spec, in priority order). This
feature **extends** the shipped 001 codebase; most foundational tasks edit existing files.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependency on an incomplete task)
- **[Story]**: US1–US6 (user-story phases only)
- All paths are repository-relative. Stack & versions: see [research.md](research.md)
  (**flutter_gemma 0.15.3** installed).

## Path Conventions

Single Flutter module: app code under `lib/`, tests under `test/`, Android config under `android/`.
Seam rules are structural: **`flutter_gemma` only in `lib/infrastructure/gemma/`**; the new
`image_picker`/`permission_handler` only in `lib/infrastructure/media/`.

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Add image-input dependencies and Android permissions.

- [X] T001 Add and pin dependencies in `pubspec.yaml` per [research.md](research.md): `image_picker` (^1.2.0, highest SDK-compatible) and `permission_handler` (^12.0.0, highest SDK-compatible); keep `flutter_gemma: ^0.15.0`. Run `flutter pub get` and record the resolved versions. — RESOLVED: image_picker 1.2.2, permission_handler 12.0.3, flutter_gemma 0.15.3.
- [X] T002 [P] Configure Android image access in `android/app/src/main/AndroidManifest.xml`: add `<uses-permission android:name="android.permission.CAMERA"/>` (and, only if a legacy non-PhotoPicker gallery fallback is kept, `READ_MEDIA_IMAGES`); confirm the merged manifest after `image_picker` is added (R3). — Added CAMERA only; library uses the permissionless Photo Picker (no READ_MEDIA_IMAGES).
- [X] T003 [P] Extend the plugin-seam guard `tool/check_plugin_seam.sh` (or add a sibling rule) so `image_picker`/`permission_handler` imports are forbidden outside `lib/infrastructure/media/`, mirroring the `flutter_gemma` rule (Principle VII).

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Entities, seam-interface extensions, capability-as-data wiring, the drift v1→v2
migration + image file store, and the extended test harness — everything every story depends on.

**⚠️ CRITICAL**: No user story work can begin until this phase is complete.

### Domain entities & seam interfaces (pure Dart)

- [X] T004 [P] Add `lib/domain/entities/image_input.dart` (`ImageInput { Uint8List bytes; String? mimeType }`) and `lib/domain/entities/image_attachment.dart` (`ImageAttachment { String path; String? mimeType }`) per [data-model.md](data-model.md).
- [X] T005 Extend `lib/domain/entities/message.dart`: add `final ImageAttachment? image;` and include it in `copyWith`/`==`/`hashCode` (user turns only) per [data-model.md](data-model.md).
- [X] T006 [P] Extend `lib/domain/entities/chat_turn.dart`: add `final ImageInput? image;` (+ named-arg + convenience ctors) so follow-ups can replay a prior image (FR-015/FR-016).
- [X] T007 Extend the seam interface `lib/domain/services/gemma_service.dart` per [contracts/gemma_service.md](contracts/gemma_service.md): `generate(... ImageInput? image)`, `loadModel(path, {ModelCapabilities capabilities})`, and add `class ImageProcessingException`.
- [X] T008 [P] Add seam interface `lib/domain/services/media_picker_service.dart` (`MediaPickerService` + `PickedImage` + `MediaAccessException`) per [contracts/media_picker.md](contracts/media_picker.md).
- [X] T009 [P] Add seam interface `lib/domain/services/media_permission_service.dart` (`MediaPermissionService` + `MediaPermissionStatus`) per [contracts/media_permission.md](contracts/media_permission.md).
- [X] T010 Extend the repository interface `lib/domain/repositories/conversation_repository.dart` per [contracts/conversation_repository.md](contracts/conversation_repository.md): `appendUserMessage(id, text, {ImageAttachment? image})` and the documented delete-cleans-files behavior.

### Capability as data (Principle III)

- [X] T011 Update `lib/core/model_catalog.dart` to declare image capability as DATA — add `static const bool supportsImage = true;` (and/or a `ModelCapabilities` constant for the catalog model) so the value flows catalog → `loadModel` → `capabilities` (no per-model `if` anywhere) (FR-005/FR-006, R1).

### Persistence (drift v1 → v2) & image file store

- [X] T012 Add the new columns in `lib/data/db/tables.dart`: `Messages.imagePath` (`text().nullable()`) and `Messages.imageMimeType` (`text().nullable()`) per [data-model.md](data-model.md).
- [X] T013 Bump `lib/data/db/app_database.dart` to `schemaVersion => 2` and add `MigrationStrategy.onUpgrade` that, `if (from < 2)`, `addColumn`s `messages.imagePath` and `messages.imageMimeType` (keep `beforeOpen` `PRAGMA foreign_keys = ON`); then run `dart run build_runner build --delete-conflicting-outputs` to regenerate `app_database.g.dart` (depends on T012, R5).
- [X] T014 Update `lib/data/db/daos/conversation_dao.dart` to read/write the new image columns (insert + read paths through the existing message CRUD) (depends on T013). — Satisfied by the generic `MessagesCompanion`/`MessageRow` CRUD; the regenerated columns round-trip automatically, no DAO edit needed.
- [X] T015 Add `lib/data/images/image_file_store.dart` (`persist(tempPath)→storedPath` into app-private `images/`, `readBytes(path)`, `deleteAll(paths)`) using `path_provider` + `dart:io`, and expose a Riverpod provider per [contracts/conversation_repository.md](contracts/conversation_repository.md). — Documents dir injectable for temp-dir tests; size/empty guard included (also serves T050).
- [X] T016 Extend `lib/data/repositories/drift_conversation_repository.dart`: map `imagePath`/`imageMimeType` ↔ `Message.image`, accept `ImageAttachment?` in `appendUserMessage` (allow text-only / image-only / both — FR-004; image-only first-message title fallback), and in `deleteConversation` delete the conversation's image files via `ImageFileStore.deleteAll` before the cascade delete (depends on T014, T015, T010, T005).

### Test harness

- [X] T017 [P] Extend `test/helpers/fake_gemma_service.dart`: record the `image` passed to `generate` and the images on `history` turns; configurable `capabilities` (default `image: true`); scriptable to throw `ImageProcessingException`; honor `stop` (partial retained) per [contracts/gemma_service.md](contracts/gemma_service.md).
- [X] T018 [P] Add `test/helpers/fake_media_picker_service.dart` and `test/helpers/fake_media_permission_service.dart` (scriptable returns/statuses + call recorders) per the contracts' test-double sections.

**Checkpoint**: Entities, seams, capability data, the v2 migration + file store, and fakes ready —
user stories can begin.

---

## Phase 3: User Story 1 — Attach an image and get a reply about it (Priority: P1) 🎯 MVP

**Goal**: With an image-capable model, attach one image (camera or library), preview it, send it
alone or with text, and see it in the user message while the assistant streams a reply about it.

**Independent Test**: With access granted, attach from library and from camera, confirm the preview,
send (±text), and verify the image renders in the user bubble and the reply streams incrementally.

### Tests for US1

- [X] T019 [P] [US1] Unit test `test/unit/features/attachment_controller_test.dart` with `FakeMediaPickerService`: pick-from-library and pick-from-camera set a pending attachment; remove clears it; picking another replaces it (single image, FR-002/FR-003); cancel leaves no attachment.
- [X] T020 [P] [US1] Unit test `test/unit/features/chat_controller_image_test.dart` with extended `FakeGemmaService` + in-memory repo + temp `ImageFileStore`: sending with an image persists the image on the user message and passes a non-null `ImageInput` to `generate`; sending image-only (empty text) is allowed (FR-004); reply deltas append as before.
- [X] T021 [P] [US1] Widget test `test/widget/composer_attachment_test.dart`: with `capabilities.image == true` the attach control shows; tapping offers camera/library; a pending image renders an `AttachmentPreview` with a remove control; send is enabled with an image and no text (FR-001/FR-004). Plus `test/widget/message_bubble_image_test.dart`: a user message with an `imagePath` renders the image in place.

### Implementation for US1

- [X] T022 [US1] Implement the image path in `lib/infrastructure/gemma/flutter_gemma_service.dart` (the only `flutter_gemma` import): create the chat with `supportImage: capabilities.image, maxNumImages: 1`; return the catalog `capabilities` from `capabilities`; in `generate`, send `Message.withImage`/`Message.imageOnly` for the prompt and map image turns in `clearHistory(replayHistory:)`; accept `capabilities` in `loadModel` (FR-005/FR-012/FR-013, R1, Principle VII). — `maxNumImages: 1` set on `getActiveModel` (0.15.3's `createChat` has no such param; vision modality is enabled via `supportImage` on both model + chat).
- [X] T023 [P] [US1] Implement `lib/infrastructure/media/image_picker_service.dart` (implements `MediaPickerService` via `image_picker`: `pickFromCamera`/`pickFromLibrary` with `maxWidth/maxHeight 1536, imageQuality 90`) + Riverpod provider (FR-001/FR-002, R2).
- [X] T024 [P] [US1] Implement `lib/features/chat/attachment_controller.dart` (Notifier holding the optional `PendingAttachment`: `pickFromCamera`/`pickFromLibrary`/`remove`/`clear`) + provider; pick errors surface for US4 to handle (FR-001/FR-002/FR-003).
- [X] T025 [US1] Build `lib/features/chat/widgets/attachment_preview.dart` (monochrome thumbnail from the pending temp path, hairline border, no shadow, a monochrome remove "×", tap-to-replace) per design system (Principle X, R6).
- [X] T026 [US1] Wire the existing capability-gated stub in `lib/features/chat/widgets/composer.dart`: the attach `IconButton` opens a camera/library chooser via `attachmentController`; show `AttachmentPreview` above the field when pending; enable send when there is an image OR text; pass the pending image to `send` (depends on T024, T025).
- [X] T027 [US1] Extend `lib/features/chat/chat_controller.dart` `send(String text, {PendingAttachment? image})`: persist the image via `ImageFileStore.persist` → `appendUserMessage(..., image: ImageAttachment(...))`, read bytes for `ImageInput`, call `generate(history:, prompt:, image:)`, clear the pending attachment on success (FR-004/FR-012, depends on T016, T022, T024).
- [X] T028 [US1] Render the image in `lib/features/chat/widgets/message_bubble.dart`: when `message.image != null`, show `Image.file` (rounded, hairline border, contained, height-capped) above any text, with a `Semantics(label: 'attached image')` and a quiet placeholder if the file is missing (FR-012, R6, depends on T005).

**Checkpoint**: US1 independently demoable — attach (camera/library) → preview → send → image in
bubble → streaming reply about it.

---

## Phase 4: User Story 2 — Attach control reflects the active model (Priority: P2)

**Goal**: The attach control appears only when the active model supports images, flips live on model
switch, clears a pending image when switching to a text-only model, and never hides already-sent
images.

**Independent Test**: Toggle `capabilities.image` (catalog/text-only model or fake) → control shows/
hides without restart; a pending image is cleared on switch to text-only; an already-sent image still
renders under a text-only model.

### Tests for US2

- [X] T029 [P] [US2] Widget test `test/widget/composer_capability_gating_test.dart`: attach control present when `capabilities.image == true`, absent (text chat still works) when false, and updates when the capability value changes — no restart (FR-005/FR-006/FR-007, SC-002).
- [X] T030 [P] [US2] Unit test `test/unit/features/attachment_capability_test.dart`: a pending attachment is cleared (with a note flag) when capabilities flip to image-unsupported (FR-008); and `test/widget/history_under_text_only_test.dart`: a persisted image message still renders when `capabilities.image == false` (FR-017).

### Implementation for US2

- [X] T031 [US2] Ensure capability data flows live: in `lib/features/chat/chat_providers.dart`, pass the catalog `capabilities` into `loadModel` and keep `modelCapabilitiesProvider` deriving from `GemmaService.capabilities` so the composer re-renders on model change (FR-006/FR-007, depends on T011, T022). — `modelCapabilitiesProvider` now derives from the live `modelSessionProvider`, so the gate flips on model switch with no restart.
- [X] T032 [US2] In `lib/features/chat/attachment_controller.dart`, watch `modelCapabilitiesProvider` and clear a pending attachment (surfacing a brief note) when `image` becomes false (FR-008, depends on T024, T031).
- [X] T033 [US2] Confirm `lib/features/chat/widgets/message_bubble.dart` renders a persisted image independent of current `capabilities` (history retention) — add/adjust only if T028 coupled rendering to capabilities (FR-017). — Confirmed: the bubble renders from `message.image` (the stored file), never from `capabilities`.

**Checkpoint**: US1 + US2 — image chat with an honest, capability-driven attach affordance.

---

## Phase 5: User Story 3 — Follow-up questions that keep referring to the image (Priority: P2)

**Goal**: Text-only follow-ups in the same conversation are answered with the earlier image in
context, without re-attaching.

**Independent Test**: Inspect the assembled context for a follow-up turn — the prior image turn is
present (verified in a unit test, independent of reply quality).

### Tests for US3

- [X] T034 [P] [US3] Unit test `test/unit/features/context_assembler_image_test.dart`: a prior user turn with an image yields a `ChatTurn` carrying its image; sliding-window trimming still drops oldest turns; stored history untouched (FR-015/FR-016).
- [X] T035 [P] [US3] Unit test extension in `test/unit/features/chat_controller_image_test.dart`: a text-only follow-up replays the earlier image to `generate` via the `history` (asserted on the extended `FakeGemmaService`).

### Implementation for US3

- [X] T036 [US3] Extend `lib/features/chat/context_assembler.dart` to carry each prior message's image onto its `ChatTurn` (set `image` from `Message.image`), preserving the existing token-budget sliding window (FR-015/FR-016, depends on T006). — Assembler takes an injected `Map<int, ImageInput>` (bytes read by the controller); stays pure/sync.
- [X] T037 [US3] In `lib/features/chat/chat_controller.dart`, read image bytes just-in-time for image-bearing history turns (via `ImageFileStore.readBytes`) and pass them on the assembled `history` to `generate`; do not retain bytes between turns (FR-016, Principle VIII, depends on T036, T015).

**Checkpoint**: Follow-ups remain grounded in the previously shown image.

---

## Phase 6: User Story 4 — Clear guidance when access is not granted (Priority: P2)

**Goal**: Camera/photo access that is missing is explained with a path to enable it (or system
settings); declining never breaks text chat.

**Independent Test**: Script each permission status via the fake → the controller routes to an
explainer (denied), to settings (permanently denied), and leaves text chat usable when declined.

### Tests for US4

- [X] T038 [P] [US4] Unit test `test/unit/features/attachment_permission_test.dart` with `FakeMediaPermissionService`: `denied`→request→proceed-or-explain; `permanentlyDenied`/`restricted`→explainer + `openSettings()` invoked; decline→text chat still usable (FR-009/FR-010/FR-011).
- [X] T039 [P] [US4] Widget test `test/widget/permission_explainer_test.dart`: the camera path with no grant shows an explainer with grant + "open settings" actions and a dismiss that returns to a working composer.

### Implementation for US4

- [X] T040 [P] [US4] Implement `lib/infrastructure/media/permission_handler_service.dart` (implements `MediaPermissionService` via `permission_handler`: `cameraStatus`/`requestCamera`/`openSettings`) + provider (FR-009/FR-010, R3).
- [X] T041 [US4] Extend `lib/features/chat/attachment_controller.dart` camera flow with the permission lifecycle: check status, request when askable, emit an explainer/settings state when denied/permanently-denied; library path attempts directly and falls back to the explainer on a legacy denial (FR-009/FR-010/FR-011, depends on T040, T024).
- [X] T042 [US4] Surface the permission explainer in `lib/features/chat/widgets/composer.dart` (a monochrome dialog/sheet with grant + "open settings" + dismiss); ensure dismiss/decline leaves text input fully functional (FR-011, depends on T041).

**Checkpoint**: Access is always explained with a next action; text chat never dead-ends.

---

## Phase 7: User Story 5 — Image conversations persist across restarts (Priority: P3)

**Goal**: Conversations containing images survive restart (and a v1→v2 upgrade) with each image shown
in place; deleting a conversation removes its image files.

**Independent Test**: Persist an image message, reopen the DB/app, confirm the image renders in place;
delete the conversation and confirm the file is gone; upgrade a v1 DB and confirm old data survives.

### Tests for US5

- [X] T043 [P] [US5] Migration test `test/data/migration_v1_to_v2_test.dart`: seed a v1 `NativeDatabase.memory()` with conversations+messages, open at v2, assert rows survive and `imagePath`/`imageMimeType` exist and default to null (R5, FR-017). — Seeds a real v1 file DB via `sqlite3` (user_version=1) + a fresh-install onCreate check.
- [X] T044 [P] [US5] Repository test `test/data/drift_conversation_repository_image_test.dart` (real in-memory drift + temp-dir `ImageFileStore`): persist a user message with an image, read it back with `image` populated, then `deleteConversation` and assert the file is deleted and rows cascade (FR-018/FR-019, SC-005).

### Implementation for US5

- [X] T045 [US5] Confirm restore path end-to-end: `watchMessages`/`loadTurns` populate `Message.image` from the columns and `message_bubble.dart` renders from the stored file on relaunch; add the image-only-first-message title fallback in `drift_conversation_repository.dart` if not already covered by T016 (FR-018, depends on T016, T028). — Confirmed: `_toMessage` maps the columns (T016) and the bubble renders from the file (T028); image-only title fallback covered by T016 and asserted in T044.
- [X] T046 [US5] Verify `ImageFileStore` writes only under app-private `images/` and that `deleteConversation` cleanup is wired for every delete entry point (history delete) (FR-019/FR-024, depends on T016). — `ImageFileStore` writes only under `<documents>/images/`; the sole delete entry point (`HistoryController.deleteConversation` → `repo.deleteConversation`) cleans files (T044 asserts the file is removed).

**Checkpoint**: Image history is durable across restart and upgrade; no orphaned files.

---

## Phase 8: User Story 6 — Honest handling when an image cannot be processed (Priority: P3)

**Goal**: An unprocessable/oversized/corrupt image yields a clear message, not a hang or crash; stop
works during image-grounded generation.

**Independent Test**: Force an `ImageProcessingException` (fake) → a clear message appears, the
conversation stays usable, no hang/crash; an oversized/corrupt pick is rejected with "pick another".

### Tests for US6

- [ ] T047 [P] [US6] Unit test `test/unit/features/chat_controller_image_error_test.dart`: `FakeGemmaService` throws `ImageProcessingException` → the assistant turn is finalized cleanly, `isGenerating` resets, and an error message state is surfaced (no hang) (FR-020, SC-008).
- [ ] T048 [P] [US6] Widget test `test/widget/image_error_message_test.dart`: the unprocessable-image path shows a clear, dismissible message and the composer remains usable; stop during an image-grounded reply retains partial text (FR-014/FR-020).

### Implementation for US6

- [ ] T049 [US6] Map plugin image failures in `lib/infrastructure/gemma/flutter_gemma_service.dart`: wrap the image-bearing generate in try/catch and throw `ImageProcessingException` on decode/validation/OOM errors (FR-020, R4, depends on T022).
- [ ] T050 [US6] Reject oversized/corrupt images in `lib/data/images/image_file_store.dart` (size/decoder guard, e.g. > the 10 MB plugin cap) and surface a "pick another" path through the attachment controller (FR-021, depends on T015, T024).
- [ ] T051 [US6] Handle `ImageProcessingException` in `lib/features/chat/chat_controller.dart`: catch it around `generate`, finalize the assistant turn without a hang, and expose a clear error message; confirm stop during image generation reuses the existing `stop()` path (FR-014/FR-020, depends on T027, T049).

**Checkpoint**: All six stories independently functional; failures degrade honestly.

---

## Phase 9: Polish & Cross-Cutting Concerns

**Purpose**: Release gates and on-device validation.

> Status marker convention (from 001): `[~]` = the automatable portion is done (tests / seam guards),
> but a part needs a **physical baseline device** (Accessibility Scanner, airplane-mode capture,
> `--release` timing, on-device memory). Those remain for an on-device pass.

- [ ] T052 [P] Accessibility pass for the new controls (attach, camera/library chooser, preview remove/replace, permission explainer actions, in-bubble image): ≥48dp targets + WCAG AA; labels use `textSecondary` (never `textMuted`); image carries a semantic label (FR-026, SC-011, quickstart V9) — _device-pending: Android Accessibility Scanner run._
- [ ] T053 [P] Offline & privacy validation: confirm `tool/check_network_seam.sh` stays green (no new egress) and run the airplane-mode flow (attach + send + 3 follow-ups) with a network monitor (FR-022/FR-023, SC-009, quickstart V8) — _device-pending: airplane-mode + live capture._
- [ ] T054 [P] Performance validation in `--release`: image-grounded first reply text within 20 s on the reference baseline device and 100 ms gesture response while streaming (SC-003/SC-010, quickstart V1) — _device-only._
- [ ] T055 [P] Resource-hygiene check: pending image bytes are not retained after send/clear, history image bytes are read just-in-time and released, and image files are deleted on conversation delete (FR-019, Principle VIII) — _automatable parts via unit tests; device-pending: on-device memory profile._
- [ ] T056 Execute the full [quickstart.md](quickstart.md) V1–V9 (including the v1→v2 upgrade-over-install check) on a baseline device with an image-capable model and record results — _device-only._

---

## Dependencies & Execution Order

### Phase dependencies

- **Setup (Phase 1)**: no dependencies — start immediately.
- **Foundational (Phase 2)**: depends on Setup — **blocks all user stories**.
- **User Stories (Phases 3–8)**: each depends on Foundational. Then:
  - US1 (P1) is the MVP and the concrete seam/UI base.
  - US2 (P2) builds on US1's composer/seam (capability flow). US3 (P2) builds on US1's chat
    controller + assembler. US4 (P2) is largely independent (permissions) but shares the composer.
  - US5 (P3) verifies the foundational persistence/migration. US6 (P3) extends US1's seam + chat
    controller with honest failure.
- **Polish (Phase 9)**: depends on the targeted stories being complete.

### Story dependency notes

- US1 → foundational only. US2 → US1 (composer/seam) + capability data (T011/T031).
- US3 → US1 (chat controller) + assembler (T036). US4 → foundational + US1 composer; permission impl
  is independent ([P]).
- US5 → foundational persistence (T012–T016). US6 → US1 seam (T022) + chat controller (T027).

### Within each story

- Tests are written against fakes and should fail before implementation.
- Interfaces (Foundational) before concretes; entities/columns before repository; controller before
  screen wiring; seam impl before the controller that calls it.
- Same-file edits across phases are sequential (e.g. `composer.dart`: T026→T042; `chat_controller.dart`:
  T027→T037→T051; `flutter_gemma_service.dart`: T022→T049; `attachment_controller.dart`:
  T024→T032→T041).

---

## Parallel Opportunities

- **Setup**: T002 ∥ T003 after T001.
- **Foundational**: entities T004 ∥ T006 ∥ interfaces T008 ∥ T009 (T005, T007, T010 touch shared
  files / depend on entities); persistence chain T012→T013→T014→T016 is sequential (T015 ∥ it);
  harness T017 ∥ T018.
- **US1**: tests T019 ∥ T020 ∥ T021; impl T023 ∥ T024 in parallel, then T022/T025/T026/T027/T028.
- **US2**: T029 ∥ T030 (tests).
- **US3**: T034 ∥ T035 (tests).
- **US4**: T038 ∥ T039 (tests); T040 [P] independent of the controller wiring.
- **US5**: T043 ∥ T044 (tests).
- **US6**: T047 ∥ T048 (tests).
- **Polish**: T052–T055 all [P]; T056 last.

```bash
# Example — Foundational fan-out (after Setup):
Task: "T004 image_input.dart + image_attachment.dart in lib/domain/entities/"
Task: "T006 extend chat_turn.dart with optional image"
Task: "T008 MediaPickerService interface in lib/domain/services/media_picker_service.dart"
Task: "T009 MediaPermissionService interface in lib/domain/services/media_permission_service.dart"
Task: "T017 extend FakeGemmaService for images in test/helpers/fake_gemma_service.dart"
Task: "T018 FakeMediaPickerService + FakeMediaPermissionService in test/helpers/"
```

---

## Implementation Strategy

### MVP first (US1)

1. Phase 1 Setup → Phase 2 Foundational (CRITICAL — blocks everything; includes the v1→v2 migration).
2. Phase 3 US1 → **STOP & VALIDATE**: attach (camera/library) → preview → send → image in bubble →
   streaming reply (quickstart V1/V2). This is the demoable MVP.

### Incremental delivery

US2 (capability gating + history retention) → US3 (follow-up memory) → US4 (permissions) → US5
(persistence/upgrade) → US6 (honest failure) → Polish. Each story is a checkpoint that adds value
without breaking earlier ones.

### Parallel team strategy

After Foundational: Dev A → US1; once US1's composer/seam land, Dev B → US2 + US4 (composer/permission),
Dev C → US3 + US6 (chat controller/seam), Dev D → US5 (persistence). Coordinate shared-file edits
(composer, chat_controller, flutter_gemma_service) in phase order.

---

## Notes

- [P] = different files, no incomplete dependency. [USn] maps a task to its story for traceability.
- Tests use the seam fakes + in-memory drift + temp image store — no device, no native plugin, no
  network (Principle VII).
- Seam invariants must hold: `flutter_gemma` only in `lib/infrastructure/gemma/`;
  `image_picker`/`permission_handler` only in `lib/infrastructure/media/` (T003 guard).
- Run `dart run build_runner build --delete-conflicting-outputs` after T012/T013 (schema v2).
- Commit after each task or logical group; validate at each checkpoint.
- Total: **56 tasks** (T001–T056).
