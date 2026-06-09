# Audit Report — 002-image-input-vision (single-image visual understanding)

**Date:** _2026-06-08 (placeholder — update on finalization)_

## Executive summary

**OVERALL VERDICT: PASS-WITH-NOTES.**

The `002-image-input-vision` feature is fully and faithfully implemented across all 56 tasks. The
automatable baseline is genuinely green and independently re-verified during this audit: `flutter
analyze` is clean, `flutter test` passes all 83 tests, and both `tool/check_plugin_seam.sh` and
`tool/check_network_seam.sh` exit 0 (the plugin-seam guard was correctly extended this branch to
confine `image_picker`/`permission_handler` to `lib/infrastructure/media/`). Contracts match the
implemented seams, the drift schema is at v2 with the v1→v2 additive migration exercised off-device,
and scope is held to exactly one image, input-only. T001–T051 are correctly `[X]`; T052–T056 are
correctly `[~]` (automatable portions done; on-device passes pending a physical baseline device).
The verdict is PASS-**WITH-NOTES** rather than clean PASS because three medium-severity items
remain: one genuine runtime correctness bug (the last streamed delta can be dropped on stop,
contradicting FR-014's "retain text produced so far"), one real test-coverage gap (the >10 MB image
rejection path is never exercised), and one design-system typography deviation (essential
attachment guidance rendered in the Space Mono spec face). None is a release blocker, but the
stop-delta bug and the oversized-image test should be addressed before merge. The remaining
constitution gates (Accessibility VI, Privacy/no-egress I, Resource VIII) are satisfied in
code/CI but their **runtime** confirmation is legitimately outstanding behind the device-pending
T052–T056 — these should be treated as a pre-release gate, per the constitution's own
"before merge"/"before release" wording, not post-merge polish.

## Remediation (post-audit)

All three medium findings were fixed immediately after the audit and locked in by tests
(`flutter analyze` clean; **88 tests pass**, up from 83):

- **M1 — FIXED.** `chat_controller.dart` now writes each delta and persists it *before* honoring
  `_stopRequested` (break moved to the bottom of the stream loop), so a token delivered concurrently
  with stop is retained (FR-014). Locked in by a new test
  (`chat_controller_test.dart` → "a delta produced concurrently with stop is retained, not dropped"),
  backed by a `FakeGemmaService.trailingDeltaAfterStop` mode that emits one final token at `stop()`.
- **M2 — FIXED.** New `test/data/image_file_store_test.dart` exercises `persist`'s >10 MB rejection
  (no partial copy left), the at-limit (`== maxBytes`) accepted boundary, the empty-file rejection,
  and a bytes round-trip + idempotent delete.
- **M3 — FIXED.** The composer attachment note/error now renders with `bodyMedium` (matching the
  chat error banner) instead of the Space Mono `labelSmall` spec face.

The low/info findings below are left as recorded (not yet addressed); the device-pending T052–T056
remain a pre-release gate.

## Per-task status (T001–T056)

| Task | Status | Verdict | Note |
|------|--------|---------|------|
| T001 | implemented | PASS | image_picker ^1.2.0 / permission_handler ^12.0.0 / flutter_gemma ^0.15.0 declared; lock resolves 1.2.2 / 12.0.3 / 0.15.3 (matches RESOLVED note). |
| T002 | implemented | PASS (note) | Source manifest adds only `CAMERA`; READ_MEDIA_IMAGES deliberately omitted (Photo Picker permissionless). Merged-manifest confirmation step unverified on disk (info finding). |
| T003 | implemented | PASS | `check_plugin_seam.sh` extended with second `check_seam` rule for media plugins; exit 0; enforcement confirmed empirically. |
| T004 | implemented | PASS | `ImageInput{bytes,mimeType}` + `ImageAttachment{path,mimeType}` per data-model; `==`/`hashCode` present. |
| T005 | implemented | PASS | `Message.image` added to copyWith/==/hashCode; user-turns-only documented. |
| T006 | implemented | PASS | `ChatTurn.image` with `.user(image:)`/`.assistant()` ctors; image in ==/hashCode. |
| T007 | implemented | PASS | `generate(...ImageInput? image)`, `loadModel(path,{capabilities})`, `ImageProcessingException` per contract deltas #8–#13. |
| T008 | implemented | PASS | `MediaPickerService` + `PickedImage` + `MediaAccessException`; single-image only. |
| T009 | implemented | PASS | `MediaPermissionService` + status enum; camera-only as documented. |
| T010 | implemented | PASS | `appendUserMessage(...,{ImageAttachment? image})`; delete doc specifies image-file cleanup before cascade. |
| T011 | implemented | PASS | `supportsImage`/`ModelCapabilities` declared as DATA; catalog→loadModel→capabilities flow, no per-model `if`. |
| T012 | implemented | PASS | `Messages.imagePath`/`imageMimeType` nullable text columns added with docs. |
| T013 | implemented | PASS | schemaVersion=>2; onUpgrade `if(from<2)` addColumn both; FK pragma retained; `.g.dart` regenerated. |
| T014 | implemented | PASS | No DAO edit needed; generic `MessagesCompanion` round-trips the new columns. |
| T015 | implemented | PASS | `ImageFileStore` persist/readBytes/deleteAll over path_provider+dart:io; documentsDirectory injectable; empty/>10 MB guard. |
| T016 | implemented | PASS | `_toMessage` maps columns↔`Message.image`; allows text-only/image-only/both (rejects both-empty); image-only title fallback; delete reads paths then deleteAll. |
| T017 | implemented | PASS | FakeGemmaService records lastImage/lastHistoryImages; configurable capabilities; throwImageProcessing; stop partial retention. |
| T018 | implemented | PASS | Scriptable media fakes + call recorders per contract test-double sections. |
| T019 | implemented | PASS | 5 attachment-controller tests (set/remove/replace/cancel). |
| T020 | implemented | PASS | chat-controller image persist + ImageInput to generate; image-only allowed; deltas append; pending cleared; text-only regression. |
| T021 | implemented | PASS | Composer attach control + chooser + preview/remove; send-by-image-alone; bubble renders image with/without text. |
| T022 | implemented | PASS (note) | Vision enabled via supportImage; `maxNumImages:1` on `getActiveModel` (createChat in 0.15.3 has no such param — documented divergence from contract example; low finding). |
| T023 | implemented | PASS | `ImagePickerService` via image_picker (maxW/H 1536, quality 90); provider exposed (concrete seam, no direct unit test by policy). |
| T024 | implemented | PASS | `AttachmentController` Notifier with pick/remove/clear; pick errors surfaced. |
| T025 | implemented | PASS | `AttachmentPreview` monochrome thumbnail + 48dp remove + tap-to-replace + Semantics + broken-image placeholder. |
| T026 | implemented | PASS | Capability-gated attach button; preview above field; send enabled image OR text; pending passed to send(). |
| T027 | implemented | PASS | `send(text,{image})` persist→appendUserMessage→read bytes→generate; ArgumentError → rejectPending. |
| T028 | implemented | PASS | `_BubbleImage` Image.file rounded + Semantics + placeholder; rendered from message.image independent of capabilities. |
| T029 | implemented | PASS | Attach control present at image:true, absent at image:false, flips live (no restart). |
| T030 | implemented | PASS | Pending cleared with note on flip to image:false; persisted image renders under text-only model. |
| T031 | implemented | PASS | `modelSessionProvider` passes capabilities into loadModel; `modelCapabilitiesProvider` derives live. |
| T032 | implemented | PASS | `build()` ref.listen resets to note-only state when capabilities flip & pending != null (FR-008). |
| T033 | implemented | PASS | Bubble renders from message.image, never from capabilities; no coupling. |
| T034 | implemented | PASS | Context-assembler image-turn carry/null/sliding-window trim; stored history not mutated. |
| T035 | implemented | PASS | Text-only follow-up replays prior image (lastImage==null, lastHistoryImages has bytes). |
| T036 | implemented | PASS | `assemble(prior,{images})` injects bytes by message id; pure/sync; token window kept. |
| T037 | implemented | PASS | `_assembleHistory` reads history bytes JIT into a local map released after generate. |
| T038 | implemented | PASS | 6 permission tests (request flows + settings + dismiss + legacy library). |
| T039 | implemented | PASS | Permission explainer widget (grant/settings/dismiss; permanentlyDenied hides grant). |
| T040 | implemented | PASS | `PermissionHandlerService` maps statuses; provider exposed. |
| T041 | implemented | PASS | pickFromCamera full lifecycle; pickFromLibrary direct + explainer fallback. |
| T042 | implemented | PASS | Monochrome AlertDialog explainer routed via ref.listen; dismiss leaves input usable. |
| T043 | implemented | PASS (note) | Hand-seeded v1→v2 migration test (rows survive, cols null) + onCreate round-trip; seeded v1 omits the shipped index (info finding). |
| T044 | implemented | PASS | In-memory drift + temp-dir store: persist/read-back, image-only title, reject empty+no-image, delete cascades + file removed. |
| T045 | implemented | PASS | Confirmed: column mapping (T016) + bubble render (T028) + title fallback; no new code. |
| T046 | implemented | PASS | Files only under `<documents>/images/`; deleteConversation removes files (asserted in T044). |
| T047 | implemented | PASS | ImageProcessingException → stoppedPartial + imageErrorMessage; dismiss keeps usable; empty→pickAnother; stop retains partial. |
| T048 | implemented | PASS | UI-driven error-banner test; dismiss removes; composer usable. |
| T049 | implemented | PASS | generate wraps inference; image-involved non-StateError remapped to domain ImageProcessingException; plugin type hidden via import-hide. |
| T050 | implemented | PASS (note) | persist rejects empty + >10 MB → chat controller rejectPending. Only empty branch is tested (medium finding: oversized untested). |
| T051 | implemented | PASS | send catches ImageProcessingException, finalizes stoppedPartial, errorMessage; dismissible `_ErrorBanner`; reuses stop(). |
| T052 | device-pending `[~]` | PASS (automatable done) | 48dp controls + Semantics + textSecondary/textPrimary done. Pending: Android Accessibility Scanner on device. |
| T053 | device-pending `[~]` | PASS (automatable done) | `check_network_seam.sh` exit 0 (no new egress). Pending: airplane-mode attach+send+follow-ups with live monitor (SC-009). |
| T054 | device-pending `[~]` | PASS (nothing automatable) | Pending: image-grounded first reply <20s + 100ms gesture response in --release on A34. |
| T055 | device-pending `[~]` | PASS (automatable done) | Byte-retention/file-deletion verified in code/tests. Pending: on-device memory profile. |
| T056 | device-pending `[~]` | PASS (automatable done) | quickstart V1–V9 present; migration off-device by T043. Pending: V1–V9 on baseline device. |

## Confirmed findings by severity

### Critical
none

### High
none

### Medium

**M1. [RESOLVED] The last streamed delta is discarded on stop (contradicts FR-014 "retains text produced so far").**
- Files: `lib/features/chat/chat_controller.dart:107-116`, `lib/features/chat/chat_controller.dart:162-166`; test gap in `test/helpers/fake_gemma_service.dart:119-126`.
- Evidence: In the stream loop, `if (_stopRequested) break;` (line 109) runs at the TOP of the
  iteration, BEFORE `buffer.write(delta)` (110) and the `updateAssistantContent` write (111).
  `stop()` sets `_stopRequested = true` then calls `gemma.stop()`. With the real flutter_gemma
  plugin, `stopGeneration()` does not synchronously terminate the Dart stream (the seam never
  cancels the `StreamSubscription` — `flutter_gemma_service.dart` consumes via `await for` with no
  subscription handle), so the `await for` can still receive one already-produced token after the
  flag is set; that token is dropped (loop breaks before writing it). FR-014 requires retaining the
  text the model produced so far; the 001 GemmaService contract's concrete mapping also specifies
  "stop → stopGeneration() + cancel the Dart StreamSubscription" with deltas kept by the caller.
  The unit tests don't catch this because `FakeGemmaService.stop()` closes the StreamController,
  ending the loop naturally rather than via the `_stopRequested` break — the break-before-write
  path is exercised only on-device. (Note: the finding's "SC-005" gloss is imprecise; SC-005 is
  about persistence-across-relaunch. The load-bearing requirement is FR-014.)
- Recommendation: Write the delta before honoring stop — `buffer.write(delta); await repo.updateAssistantContent(...); if (_stopRequested) break;` — or move `if (_stopRequested) break;` to the bottom of the loop body. Add a fake mode that emits one more delta after `stop()` is observed to lock this in.

**M2. [RESOLVED] The oversized (>10 MB) image rejection path is never tested — only the empty-file branch is covered.**
- Files: `lib/data/images/image_file_store.dart:48-54`; `test/unit/features/chat_controller_image_error_test.dart:85-101`; `specs/002-image-input-vision/tasks.md:223`.
- Evidence: `ImageFileStore.persist` has two distinct guards — empty (`length == 0`, lines 45-47)
  and oversized (`length > maxBytes`, lines 48-54). The only test driving the rejection path writes
  a ZERO-byte file, hitting only the empty branch. A grep across `test/` for
  `maxBytes`/`exceeds`/`oversized`/`10 * 1024` returns nothing, and there is no dedicated
  `ImageFileStore` unit test. The 10 MB boundary — the case FR-021 / the "Very large or
  high-resolution image" edge case is actually about — has zero coverage, so a regression (flipping
  `>` to `>=`, removing the check, or a wrong constant) would pass the suite. Note also that the
  T050 task note's claim that "the attachment controller validates at pick time" is inaccurate:
  the sole size enforcement is `persist()` at send time.
- Recommendation: Add a temp-dir-backed `ImageFileStore` unit test that writes a file just over
  `maxBytes`, asserts `persist` throws `ArgumentError` and leaves no partial copy in `images/`, plus
  an at-limit (`== maxBytes`) accepted case. Optionally add a chat-controller test where persist
  rejects an oversized file and asserts `attachmentControllerProvider.error == pickAnotherError`
  and that nothing is sent.

**M3. [RESOLVED] Attachment error/note rendered in the Space Mono spec face (labelSmall) instead of a body style.**
- Files: `lib/features/chat/widgets/composer.dart:169-177` (style at :175); `lib/features/chat/attachment_controller.dart:74-78`; `.specify/memory/design-system.md:69-85`.
- Evidence: `composer.dart:175` renders the attachment error/note with
  `style: theme.textTheme.labelSmall?.copyWith(color: colors.textSecondary)`. `labelSmall` maps to
  `AppText.label` — the Space Mono spec face at 11sp, letterSpacing +1.5. Per design-system §3 the
  Label/Spec role is reserved for "Status readouts, metadata, tags, technical labels — uppercase,
  letter-spaced." The strings carried here are essential lowercase prose sentences:
  "image removed — this model does not accept images" (FR-008) and "that image can't be used — pick
  another" (FR-021). Rendering full lowercase sentences in 11sp wide-tracked monospace is a
  typography-role mismatch that hurts readability of essential, user-facing guidance. Color is fine
  (`textSecondary` #A0A0A0 is 8.03:1, AA-pass) — this is purely the face/size. The codebase's own
  patterns confirm the fix: `chat_screen.dart` renders the error-banner message with `bodyMedium`,
  and `message_bubble.dart:66` correctly uses `AppText.spec('stopped')` (uppercased) for a genuine
  status tag.
- Recommendation: Render the note/error with a body style (e.g.
  `theme.textTheme.bodyMedium?.copyWith(color: colors.textSecondary)`), matching the error banner.
  Reserve `labelSmall` (Space Mono) for genuine uppercase spec/metadata; if a mono treatment is
  intentional here, route the copy through `AppText.spec(...)` to uppercase it per §3 — but body is
  the better fit for an essential sentence.

### Low

**L1. Contract/research specify `maxNumImages` on `createChat`, but the seam sets it on `getActiveModel` (FR-002/FR-006).**
- Files: `lib/infrastructure/gemma/flutter_gemma_service.dart:85`, `:108`; `specs/002-image-input-vision/contracts/gemma_service.md:64`; `specs/002-image-input-vision/research.md:49`.
- Evidence: gemma_service.md guarantee #8 and research R1 both state the chat is created with
  `createChat(... maxNumImages: 1)`. The code's `createChat` passes `supportImage` but NOT
  `maxNumImages`; instead `maxNumImages: supportImage ? 1 : null` is passed to `getActiveModel`
  (line 112). The 0.15.3 `createChat` has no `maxNumImages` parameter at all — the contract text is
  literally unsatisfiable on that API surface — so the code's placement is the only API-valid spot.
  The single-image cap (FR-002) is still configured; T022 openly documents the deviation. This is a
  documented doc-vs-code divergence, no missing behavior.
- Recommendation: Update gemma_service.md #8 and research R1 to attribute `maxNumImages` to model
  activation (`getActiveModel`) and `supportImage` to `createChat`, or add a one-line note pointing
  at the T022 deviation. No code change.

**L2. FR-008 "told why" note is unit-tested at the controller but never exercised end-to-end through the composer on a model switch.**
- Files: `lib/features/chat/attachment_controller.dart:80`; `lib/features/chat/widgets/composer.dart:144`; `test/unit/features/attachment_capability_test.dart:37`.
- Evidence: FR-008 requires a previewed-but-unsent image be cleared AND the user "told why" on
  switch to text-only. Clearing + note is unit-tested at the controller (state.note ==
  clearedOnModelSwitchNote), and the composer renders it (mapped via `s.error ?? s.note` →
  attachmentMessageKey). But no widget test drives a capability flip while a preview is mounted and
  asserts the note text appears in the UI — `composer_capability_gating_test.dart` only toggles
  capability with no pending image. The display half of FR-008 is unverified by an automated test;
  the implementation is present and correct.
- Recommendation: Add a widget test — mount composer with image:true, set a pending attachment, flip
  `modelCapabilitiesProvider` to image:false, pump, assert `AttachmentPreview` disappears and the
  attachmentMessageKey text equals `AttachmentController.clearedOnModelSwitchNote`.

**L3. FR-025 background resource-release path (AppLifecycleListener → close model) has no automated test.**
- Files: `lib/features/chat/chat_screen.dart:36`; `specs/002-image-input-vision/spec.md:312`.
- Evidence: FR-025 requires resources released "on navigation away or backgrounding." The
  backgrounding branch (chat_screen.dart:36-49: `AppLifecycleListener` closes the service on
  paused/detached/hidden, invalidates on resume) has no test — a grep of `test/` for
  `AppLifecycleState`/`handleAppLifecycleStateChanged`/`paused` finds nothing. The autoDispose
  navigation-away path IS covered (model_session_test asserts closeCount), but the
  backgrounding-closes-service unit assertion is absent though automatable. Production code is
  correct.
- Recommendation: Add a widget test that pumps ChatScreen with a FakeGemmaService and dispatches
  `AppLifecycleState.paused` to assert `closeCount` increments, or explicitly scope FR-025's
  automatable portion into T055's `[~]` note. No production change.

**L4. Image-involved generation maps every non-StateError failure to ImageProcessingException, including non-image errors on a text-only follow-up that merely has image history.**
- Files: `lib/infrastructure/gemma/flutter_gemma_service.dart:134`, `:155-157`.
- Evidence: `involvesImage = image != null || history.any((t) => t.image != null)`; then
  `if (involvesImage && error is! StateError) throw ImageProcessingException(...)`. On a TEXT-ONLY
  follow-up in a conversation with an earlier image (FR-015/FR-016 replays it), `involvesImage` is
  true, so a generic runtime/OOM error surfaces as "couldn't process this image — try another, or
  send without it." Principle V is still met (clear, non-crashing, dismissible), but the "try
  another image" hint is misleading for a text-only turn where nothing was attached.
- Recommendation: Narrow the remap to `image != null` (current prompt carries an image), or use a
  neutral message for the history-replay case. Honest-degradation is met either way; this improves
  the honest/actionable quality.

**L5. Stored image file extension can mislabel content type for an extension-less picker temp path.**
- Files: `lib/features/chat/chat_controller.dart:153-158`; `lib/data/images/image_file_store.dart:42-86` (helper at :79-86).
- Evidence: `_extensionOf` is duplicated in the controller and the store; both default to `.jpg`.
  `image_picker` on Android can return content-resolver temp files lacking a meaningful extension
  while the image is actually PNG/WEBP/HEIC, so the persisted file is named `*.jpg` regardless. The
  true MIME is preserved separately in `imageMimeType`, rendering uses `Image.file` (content
  sniffing), and the model gets raw bytes — so behavior is unaffected — but the on-disk extension
  misleads debugging/any future code trusting it. The chat controller always passes an explicit
  `extension:`, so the store's own `_extensionOf` fallback is effectively dead from that call site.
- Recommendation: Derive the extension from `pickedImage.mimeType` (already threaded through) with
  path inference as fallback; consolidate the single `_extensionOf` helper into `ImageFileStore` and
  drop the controller copy.

**L6. Contract guarantee #12 (generate(image:) must throw StateError when capabilities.image == false) is unmodeled by the fake and untested.**
- Files: `specs/002-image-input-vision/contracts/gemma_service.md:68`; `lib/infrastructure/gemma/flutter_gemma_service.dart:130-131`; `test/helpers/fake_gemma_service.dart:77-116`.
- Evidence: The contract mandates passing an image while `capabilities.image == false` throws
  StateError (caller must gate first). The real seam enforces it (lines 130-131), but
  `FakeGemmaService.generate` accepts an image unconditionally and no test asserts the StateError.
  The guard is defended only in the plugin-bound (unit-untestable) seam. `ChatController.send` does
  not re-check capabilities before `generate(image:)` — it relies on UI gating (which IS tested), so
  the risk is bounded (defense-in-depth, not a live regression).
- Recommendation: Model #12 in FakeGemmaService (throw StateError when an image is passed but
  `capabilitiesData.image` is false) and add a one-line assertion, or explicitly document in the
  fake that #12 is a seam-only invariant out of scope for the fake.

**L7. message_bubble image widget tests assert tree shape, not that an image actually renders (fake paths hit the errorBuilder placeholder).**
- Files: `test/widget/message_bubble_image_test.dart:26-44`; `test/widget/history_under_text_only_test.dart:24-46`; `lib/features/chat/widgets/message_bubble.dart:106-114`.
- Evidence: Both tests pass non-existent paths (`/tmp/fake-bubble.jpg`, `/tmp/persisted.jpg`).
  `_BubbleImage` uses `Image.file(...)` with an `errorBuilder` swapping in a broken-image Icon; the
  `Image` widget stays in the tree and `Semantics(label:'attached image')` wraps it unconditionally.
  So `find.byType(Image)` and `find.bySemanticsLabel('attached image')` pass whether or not the file
  decodes — the tests can't distinguish a rendered image from the failure placeholder. They do
  correctly verify the layout/a11y contract (image slot + label, FR-012; history renders under a
  text-only model, FR-017), but not decode.
- Recommendation: Acceptable widget-test boundary, but make it explicit — point the path at a tiny
  real fixture written to a temp dir in setUp so a successful decode is asserted, or add a comment
  noting the test asserts the image *slot* and semantics, not decode.

**L8. Composer "tap-to-replace" thumbnail gesture and dismissPrompt note-clearing have no test.**
- Files: `lib/features/chat/widgets/attachment_preview.dart:43-66`; `lib/features/chat/attachment_controller.dart:159-160`; `test/widget/composer_attachment_test.dart:87-99`.
- Evidence: `AttachmentPreview` exposes an `onReplace` tap on the thumbnail (`thumbnailKey`) for
  FR-003 replacement; no widget test taps it (replacement is only covered at the controller level
  via a second pickFromLibrary). Separately, `dismissPrompt` clears the note (`clearNote: true`),
  but a grep for `clearNote` across `test/` returns nothing, so that side effect is unverified.
- Recommendation: Add a composer widget test that pumps a pending preview and taps `thumbnailKey`
  to confirm the chooser reopens; add one assertion that `dismissPrompt` clears a pre-set note.

**L9. Composer renders a speculative, unreachable audio (mic) affordance — out-of-scope UI scaffolding.**
- Files: `lib/features/chat/widgets/composer.dart:197-201`; `lib/core/model_catalog.dart:20`.
- Evidence: The composer gates a no-op mic button on `capabilities.audio`
  (`IconButton(onPressed: () {}, icon: Icon(Icons.mic_none_outlined, ...))`). It is currently
  unreachable: the catalog only ever sets the image flag (`ModelCapabilities(image: supportsImage)`),
  leaving audio at its default false. Audio is explicitly Out of Scope (spec.md:415). Carrying the
  audio field on the value object is fine; the issue is the composer actually rendering a dead audio
  control.
- Recommendation: Remove the `if (capabilities.audio)` mic IconButton block from the composer until
  an audio slice is in scope; keep the capability field on the data model.

### Info (non-blocking observations)

**I1. Plan's Constitution Check marks IV/V/VI/VIII as fully resolved (✅) while the device-dependent
guarantees remain unverified (`[~]` T052–T056).**
- Files: `specs/002-image-input-vision/plan.md:208`; `specs/002-image-input-vision/tasks.md:238`.
- The Post-Design Re-Check declares "Result: PASS" and flips IV/V/VI/VIII to ✅, but T052–T056 are
  `[~]`: Accessibility Scanner (VI), airplane-mode + live capture (Principle I / SC-009 no-image
  egress), first-reply-<20s + 100ms gesture (SC-010), on-device memory profile (VIII), and full
  quickstart incl. real v1→v2 upgrade-over-install. The ✅ follows standard Spec Kit
  design-gate convention, but the runtime confirmation the constitution's gates ultimately call for
  is outstanding.
- Recommendation: Keep T052–T056 open and treat the on-device pass (especially T053 airplane-mode
  monitor for Principle I/SC-009 and T052 Accessibility Scanner for VI) as a **pre-release gate**,
  per the constitution's "Accessibility is a release gate"/"Privacy gate" language. No code change.

**I2. Principle IV (off-UI-isolate image prep / no-jank) is asserted resolved in the plan but is not
verifiable in code; the only Dart-side step is unmeasured.**
- Files: `plan.md:213`; `chat_controller.dart:137`; `flutter_gemma_service.dart:120`.
- The heavy decode/resize is delegated to native (image_picker pick-time downscale + flutter_gemma's
  native ImageProcessor) — sound, off the Dart UI isolate. But the only Dart-side handling is
  `ImageFileStore.readBytes` (async, non-blocking); there is no `compute()`/isolate. Whether the
  plugin's prefill keeps the UI isolate free (SC-010, 100ms gesture) is device-pending (T054/T055).
- Recommendation: Soften the plan's IV ✅ to note the off-isolate guarantee depends on the native
  plugins and is confirmed only by the device pass, not by code.

**I3. A crash between image file write and DB row commit can orphan an image file (Resource Hygiene
VIII), accepted by design with no startup sweep.**
- Files: `chat_controller.dart:74`; `research.md:219`.
- `send()` calls `imageStore.persist(...)` (writes file) before `repo.appendUserMessage(...)`
  (writes the path-bearing row). research R5 explicitly accepts "a crash between file-write and
  row-commit could orphan a file" and defers a startup sweep as out of scope. `deleteConversation`
  cleanup only removes files referenced by surviving rows, so an orphan from this window is never
  reclaimed. Documented and consistent with Lean Scope — not a violation.
- Recommendation: No action for this slice; if/when a startup orphan-sweep is added, reference
  Principle VIII.

**I4. send() persists the image file before DB writes that are outside any try/catch — a routine
appendUserMessage failure orphans the file (and propagates uncaught).**
- Files: `chat_controller.dart:74-128`; `drift_conversation_repository.dart:76-115`; `research.md:219-221`.
- The file is persisted at line 77 inside a try that catches only `ArgumentError`; the DB calls
  (`appendUserMessage`, `loadTurns`, `beginAssistantMessage`) run with NO surrounding try/catch (the
  generate try starts at line 106). A throw from any of those after the file write leaves an
  orphaned file with no referencing row (unreclaimable by path-based cleanup), and the exception
  surfaces uncaught to the fire-and-forget caller with no error-state handling and `isGenerating`
  never reset. This widens the accepted-orphan window slightly beyond R5's "crash-only" wording.
  Low-probability for local SQLite, hence low/info.
- Recommendation: Extend the try/catch to cover `appendUserMessage`/`beginAssistantMessage` and, on
  pre-commit failure, call `imageStore.deleteAll([storedPath])`; or defer `persist()` until
  immediately around the row write. At minimum, document that this widens the orphan window so the
  future sweep is sized correctly.

**I5. Stale merged AndroidManifest could not confirm the post-002 permission surface; only the source
manifest was verifiable (CAMERA only, no media/storage permission).**
- Files: `android/app/src/main/AndroidManifest.xml:17`; `tasks.md:42`.
- The source manifest adds only `CAMERA` (Photo Picker is permissionless; no READ_MEDIA_IMAGES) —
  exactly the Principle I minimal-surface posture. But the only merged manifest on disk predates this
  branch (no CAMERA), so the actual merged result of image_picker 1.2.2 + permission_handler 12.0.3
  contributions could not be inspected. T002's "confirm the merged manifest" step is not evidenced.
- Recommendation: Run a clean build and inspect the merged manifest (or `aapt dump permissions`) to
  confirm no unexpected media/storage permissions are injected, satisfying the T002 step. No code
  change expected.

**I6. Stored image files are reclaimed only on whole-conversation delete — by design (FR-019).**
- Files: `image_file_store.dart:42-76`; `drift_conversation_repository.dart:154-167`.
- `deleteAll`'s only caller is `deleteConversation`; there is no per-message delete and no orphan
  sweep. Per data-model/contract the image lifecycle is tied to its conversation, so the happy and
  delete paths are leak-free (asserted in T044). The only gap is the accepted persist-then-fail
  window (I3/I4).
- Recommendation: No action for this scope; if the deferred startup sweep (R5) lands, have it diff
  `images/` against `messages.imagePath` and delete the difference (`deleteAll` is already idempotent).

**I7. Migration test's hand-rolled v1 schema omits the `idx_messages_conversation` index that shipped
in real v1.**
- Files: `test/data/migration_v1_to_v2_test.dart:28-53`; `lib/data/db/app_database.g.dart:1539-1540`; `lib/data/db/tables.dart:21`.
- Real shipped v1 creates `CREATE INDEX idx_messages_conversation ON messages (conversation_id,
  sequence)`; the hand-seeded v1 DDL never creates it, so the post-upgrade state is not byte-identical
  to a real device DB. Because onUpgrade is purely additive `addColumn`, migration correctness is
  unaffected — but the file comment "seeds a real v1 schema by hand" overstates fidelity, and there
  is no drift schema-export/verify harness to auto-detect drift.
- Recommendation: Add the `CREATE INDEX` to the seeded v1 schema and assert it survives upgrade;
  consider drift's schema-export + generated migration tests for future bumps.

**I8 (positive). Plugin seams hold and are machine-enforced.** `flutter_gemma`,
`image_picker`, `permission_handler` imports appear only in `lib/infrastructure/{gemma,media}/`;
`check_plugin_seam.sh` (extended this branch) enforces both groups and exits 0; no plugin symbols
leak into domain/presentation/data or tests. No action.

**I9 (positive). The plugin's `ImageProcessingException` is correctly hidden via `import ... hide
ImageProcessingException`** so the unprefixed throw resolves to the pure-Dart domain type; the
`hide` is load-bearing (without it, ambiguous-import). No action.

**I10 (positive). Scope is held to exactly one image, input-only** — no multi-image, generation,
editing, audio pipeline, function calling, or thinking (all hardcoded off / ignored; no multi-pick
method; spec Out-of-Scope list fully respected). No action (aside from the L1 doc fix).

## To investigate

none — no findings were left at uncertain verdict.

## Verification baseline

- `flutter analyze`: clean (No issues found) — re-confirmed.
- `flutter test`: 83 passing (unit + widget + data; seam fakes + in-memory drift + temp image
  store) — implementer-verified.
- `tool/check_plugin_seam.sh`: exit 0 (re-run during audit). Extended this branch to confine
  `image_picker`/`permission_handler` to `lib/infrastructure/media/` in addition to `flutter_gemma`.
- `tool/check_network_seam.sh`: exit 0 (re-run during audit) — image_picker/permission_handler add
  no egress.
- Drift schema at v2; v1→v2 additive migration exercised off-device (T043).

**Device-pending (T052–T056, correctly `[~]`):** Android Accessibility Scanner on a physical device
(T052/VI); airplane-mode attach+send+3-follow-ups with a live network monitor (T053/Principle I/
SC-009); image-grounded first reply <20 s + 100 ms gesture response in `--release` on the baseline
A34 (T054/SC-010); on-device memory profile (T055/VIII); full quickstart V1–V9 on a baseline device
with an image-capable model (T056). These should be treated as a **pre-release gate**, not
post-merge polish, per the constitution's "before merge"/"before release" wording.

## Refuted candidates

Three additional candidate findings were generated during the audit and **adversarially refuted**
(verdict = false-positive); they are excluded from this report.
