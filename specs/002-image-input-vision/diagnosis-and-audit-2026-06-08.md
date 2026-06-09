# diagnosis & audit — "image removed — this model does not accept images"

feature: 002-image-input-vision · date: 2026-06-08 · branch: 002-image-input-vision
working tree on top of commit `0a956ed` (uncommitted changes present)

---

## 1. direct answer — is it the model or the code?

it is the **code/plugin layer, not the model**. the downloaded Gemma 4 E2B `.litertlm`
artifact *is* vision-capable — on flutter_gemma 0.15.3 its native vision encoder demonstrably
ran on this exact device (stb_image_preprocessor resize, 2394 patches, `vision_280` signatures,
recorded in the `image-grounding-litertlm-015` memory note), and a text-only artifact cannot run a
vision encoder. the new "image removed — this model does not accept images" message is **not from
the model** — it is a hardcoded client-side string (`AttachmentController.clearedOnModelSwitchNote`)
fired by app dart code when the model *session* reports text-only capabilities. the prime suspect is
the uncommitted **`flutter_gemma ^0.15.0 → ^0.16.0` bump (lock now resolves 0.16.4, was 0.15.3)**:
it compiles clean but most likely fails to *load* the vision-enabled model at runtime on the A34,
which flips capabilities to text-only and trips the note. fix: revert the bump to confirm.

---

## 2. root cause of the note

the literal string `'image removed — this model does not accept images'` lives at
`lib/features/chat/attachment_controller.dart:74-75`. it is emitted by the `ref.listen` registered in
`AttachmentController.build()` (`attachment_controller.dart:84-88`):

```dart
ref.listen(modelCapabilitiesProvider, (previous, next) {
  if (!next.image && state.pending != null) {
    state = const AttachmentState(note: clearedOnModelSwitchNote);
  }
});
```

so the note fires **only** when `modelCapabilitiesProvider` emits a value whose `.image == false`
*while a pending image exists*. `modelCapabilitiesProvider`
(`lib/features/chat/chat_providers.dart:47-53`) returns `ModelCapabilities.textOnly` (image:false) in
three cases:

- **(A) session is loading** → `maybeWhen` `orElse` → textOnly (transient)
- **(B) session is in `AsyncError`** → `orElse` → textOnly  ← **the live cause**
- **(C) session has `data` but `gemma.isLoaded` is false, or the loaded model reports image:false**

case (C) is unreachable for this build: the catalog hardcodes `supportsImage = true`
(`lib/core/model_catalog.dart:16`), and capabilities flow as **data** into `loadModel`
(`chat_providers.dart:34`) and are stored verbatim (`flutter_gemma_service.dart:93`); a successfully
loaded model therefore reports image:true. case (A) is normally impossible to hit because the attach
affordance is itself capability-gated and hidden during load (`composer.dart:192`). that leaves **(B):
the model session ends in `AsyncError`**.

### the mechanism (why 0.16.4 is the prime suspect)

`modelSessionProvider` (`chat_providers.dart:25-41`) calls `gemma.loadModel(path,
capabilities: ModelCatalog.capabilities)` with image:true. inside `loadModel`
(`flutter_gemma_service.dart:60-101`):

```dart
_model = await _activate(PreferredBackend.gpu, supportImage: capabilities.image) ??
         await _activate(PreferredBackend.cpu, supportImage: capabilities.image);
if (_model == null) {
  throw const ModelLoadException('could not initialize a backend for the model');
}
```

and `_activate` (`flutter_gemma_service.dart:104-118`) calls
`FlutterGemma.getActiveModel(supportImage: true, maxNumImages: 1)` and **catches every exception,
returning null**:

```dart
try {
  return await FlutterGemma.getActiveModel(maxTokens: _maxTokens, preferredBackend: backend,
      supportImage: supportImage, maxNumImages: supportImage ? 1 : null);
} catch (_) {
  return null;   // ← discards the real error
}
```

if `getActiveModel(supportImage:true)` throws on 0.16.4 for **both** gpu and cpu, `_model` is null →
`ModelLoadException` → `modelSessionProvider` becomes `AsyncError` → `modelCapabilitiesProvider`
falls back to textOnly → the moment the user attaches an image, the listener drops it and shows the
note. the `catch (_) { return null; }` masks the underlying cause, so a **load failure surfaces as
the misleading "this model does not accept images" note** rather than a backend error.

**why this is a runtime regression, not a compile break.** the seam compiles clean against 0.16.4
(`flutter analyze` = "No issues found!"). a byte-diff of the two cached plugin sources confirms the
dart surface the seam touches is effectively unchanged:

- `getActiveModel` differs only by an additive optional `maxConcurrentSessions` param (the seam never
  passes it) — signature-compatible.
- `core/model.dart`, `core/message.dart`, `core/chat.dart` are **byte-identical** (matching md5).
- the entire dart vision path (`vision_encoder_validator.dart`, `multimodal_image_handler.dart`,
  `image_processor.dart`) is byte-identical, including the wire format
  `{'type':'image','blob':base64(bytes)}`.
- the GPU/CPU vision-enable block in the FFI client (`enableVision` + `set_max_num_images` +
  `engine_create`) is byte-identical; the only new code is an android-NPU-only dispatch path the seam
  never reaches.

the **one substantive runtime change** is the bundled native LiteRT-LM library:
`native-v0.11.0-b` (0.15.3) → `native-v0.12.0-a` (0.16.4) (`hook/build.dart`). vision-encoder
acceptance for a Gemma 4 E2B `.litertlm` is decided inside that opaque `.so` at `engine_create`.
0.16.x also added a brand-new FFI backend-init pipeline (`core/ffi/backend_preference.dart` +
`BackendInitException` — both **absent** in 0.15.3) that throws on init failure instead of silently
degrading. the 0.15.0 CHANGELOG already documents this exact failure family: "multi-signature vision
encoder rejected by native (engine_create error)" for post-MTP Gemma 4. so a native `engine_create`
vision-load rejection on 0.12.0-a for both backends is a well-grounded mechanism for the note.

confirmed working-tree facts: `pubspec.yaml:32` = `flutter_gemma: ^0.16.0` (with an "EXPERIMENT (002
audit)" comment); `pubspec.lock` resolves `version: "0.16.4"` (sha256 `aea63ed9…`, previously
`b1491d0c…`/0.15.3) — a real, non-stale lock change.

---

## 3. two distinct problems — keep them separate

these are different failures at different layers, and conflating them will waste a device cycle.

| | (a) grounding gap (OLD, on 0.15.3) | (b) "image removed" note (NEW, after 0.16.4 bump) |
|---|---|---|
| **symptom** | model replies "Please provide the image…" | composer shows "image removed — this model does not accept images" |
| **when** | *after* a successful load + encode, at generation time | *before* any `generate()` call, at composer capability-gate time |
| **image reaches model?** | yes — encoder ran (2394 patches, vision_280) | no — the pending image is dropped before send |
| **layer** | native LiteRT-LM 0.11.0-b chat-templating / image-token splicing (or artifact) | model-LOAD failure on native 0.12.0-a → `AsyncError` → textOnly → client note |
| **dart code involved** | none (002 dart plumbing verified correct) | none defective; the note is correct behavior given a load failure it can't see |
| **tracked in** | `image-grounding-litertlm-015` memory note | this report |

key point: **(b) is strictly worse than (a)** for the user — on 0.15.3 the image was at least sent
and the encoder ran; on 0.16.4 (if the load-failure hypothesis holds) the image never even leaves the
composer. the 0.16.x CHANGELOG contains **no entry claiming a Gemma 4 vision-grounding fix** (its
image-relevant deltas are multi-image input in 0.15.1 and an unrelated embedding-isolate fix in
0.16.4), so the bump has no evidence of fixing (a) and has likely introduced (b).

a third, version-independent way to see the *same* note: attaching+sending during the transient
`AsyncLoading` window (case A above) would show it on 0.15.3 too. the revert test below
disambiguates this from the load-failure hypothesis.

---

## 4. remediation plan — ordered & concrete

### step 1 — revert the experimental bump (isolate the regression)

per the experiment's own in-file rollback note and CLAUDE.md's pin, revert first:

```bash
# in pubspec.yaml change line 32 back to:
#   flutter_gemma: ^0.15.0
flutter pub get          # lock re-resolves flutter_gemma → 0.15.3 (sha256 b1491d0c…),
                         # and drops the 0.16.x transitives (mutex, uuid; large_file_handler 0.4.0→0.3.1)
flutter analyze --no-pub # expect: No issues found!
flutter test             # expect: All tests passed! (88/88)
```

then rebuild on the A34. **expected outcome if the hypothesis is correct:** the model loads,
`modelCapabilitiesProvider` reports image:true, the attach control stays enabled, the "image removed"
note no longer fires, and the symptom reverts to the prior (a) grounding gap ("Please provide the
image…"). if the note *persists* on 0.15.3, the transient-loading path (case A) is implicated
instead — not the version.

### step 2 — capture the real on-device load error (confirm the load-failure hypothesis)

the `.so` is opaque to static analysis, so the native rejection can only be *proven* on device. with
the 0.16.4 build still installed (or a temporary throwaway build), watch logcat at model-load time:

```bash
adb logcat | grep -Ei 'FlutterGemmaMobile|LiteRtLmFfi|BackendInit|engine_create|vision'
```

look for a `BackendInitException` or an `engine_create` vision error on **both** the gpu and cpu
attempts. that confirms `getActiveModel(supportImage:true)` is what throws and that
`_activate`'s catch-all is masking it. (the test suite cannot show this — see §6.)

### step 3 — the grounding problem's real levers (do NOT chase it with a version bump)

grounding (problem a) breaks **below** the dart seam, in native LiteRT-LM / the artifact. the dart
image path is byte-identical across 0.15.3 and 0.16.4, so a plugin version bump is the wrong lever.
pursue grounding via:

- confirm the downloaded `.litertlm` is the intended multimodal artifact and try pinning a specific
  HF revision (the 0.15.0 CHANGELOG workaround for the post-MTP encoder-rejection family).
- try a corrected image-prompt / chat-template or an upstream/native LiteRT-LM fix.
- only re-test a 0.16.x bump as a **deliberate, device-verified experiment on a throwaway branch**,
  gated by a full quickstart V1–V9 re-run (load + text chat + image attach/send + follow-up) on the
  A34 *before* it touches the feature branch — and re-verify the 001 android gotchas (Impeller-off,
  FGS `dataSync`) still hold against the new native binary.

### step 4 — code hardening (independent of version; prevents the false signal recurring)

the current design makes a **load failure indistinguishable from a vision-less model**, producing a
misleading note. two cheap, scoped fixes:

- **stop swallowing the error in `_activate`** (`flutter_gemma_service.dart:115-117`): log /
  propagate the caught exception (e.g. keep the last error and include it in the `ModelLoadException`
  cause) so a future load failure is diagnosable instead of silent.
- **distinguish "load failed" from "genuinely text-only"** in `modelCapabilitiesProvider` /
  `AttachmentController`: when `modelSessionProvider` is in `AsyncError` (or still `AsyncLoading`),
  the composer should surface a model-load/availability state, **not** drop the image with "this
  model does not accept images." the capability-flip note should fire only on a real
  loaded-but-text-only model (e.g. an actual model switch), matching its FR-008 intent.

these two are good follow-up tasks regardless of which plugin version ships.

---

## 5. task / spec audit summary

### M1 / M2 / M3 fixes — all still hold (re-verified at source, locked by tests)

- **M1 (FR-014 stop-delta retention):** `chat_controller.dart:107-114` now writes the delta and
  persists it *before* honoring stop (break moved to the bottom of the await-for loop). locked by
  `FakeGemmaService.trailingDeltaAfterStop` + the "delta produced concurrently with stop is retained"
  test. holds.
- **M2 (image_file_store oversized/at-limit/empty/round-trip coverage):** new
  `test/data/image_file_store_test.dart` exercises all four guards (>maxBytes, ==maxBytes, empty,
  round-trip) against `image_file_store.dart:45-54`. holds.
- **M3 (composer note typography):** `composer.dart:177` renders the note as `bodyMedium` (lowercase
  guidance prose) instead of `labelSmall` (the uppercase Space Mono spec face). holds.

baseline against the now-resolved 0.16.4: `flutter analyze` clean, `flutter test` = **88/88** passing.
the working-tree diff to the five lib/test files is correct and aligned with FR-004/012/014/020/021
(it also fixes a real prior bug: persist-before-create now avoids orphaning an empty conversation on
an oversized image, and surfaces "pick another" via the `ArgumentError → rejectPending` early return).

### stale task / doc statuses to update (all due to the 0.15.3 → 0.16.4 bump)

1. **`tasks.md` T001 (line 41):** records "flutter_gemma 0.15.3" and "keep `^0.15.0`" — now false
   (`^0.16.0` / 0.16.4). image_picker 1.2.2 and permission_handler 12.0.3 are still accurate.
2. **`tasks.md` header (line 27):** "(flutter_gemma 0.15.3 installed)" — stale.
3. **`research.md` R1:** the "0.15.3 installed/verified" framing (lines 6, 16, 28, 44, 58, 70-73, 260)
   is now false; its pre-registered risk ("if the team later bumps to 0.16.x, re-verify
   `Message.withImage`/`createChat` signatures") **has fired** and should be discharged — signatures
   re-verified present/unchanged in 0.16.4 (`Message.text/withImage/imageOnly`,
   `clearHistory`, `addQueryChunk`, `generateChatResponseAsync`→`Stream`, `TextResponse`;
   `getActiveModel` still carries `maxNumImages`). also fix the pre-existing L1 error: `maxNumImages`
   belongs to `getActiveModel`, **not** `createChat` (true in both versions).
4. **`audit-report.md`:** its 0.15.3 references and its "83 passing" baseline are stale (current tree
   = 88). its L1 reasoning (createChat has no `maxNumImages`) is re-confirmed correct on 0.16.4.
5. **`CLAUDE.md`:** still asserts "0.15.3 … the installed/verified version; the 001 docs' 0.16.4 is
   superseded" — now self-contradictory with the resolved 0.16.4. update to reflect the experiment, or
   (preferred) revert the bump so the doc becomes true again.

> note: the US6 task flips (T047–T051 → [X], T052–T056 → [~]) are *accurate* completion records
> backed by passing tests — they were just authored under the 0.15.3 assumption while the surrounding
> version pins were not correspondingly updated, leaving `tasks.md` internally inconsistent.

### T022 / seam comment — verified accurate, no action

the seam comment "maxNumImages lives on getActiveModel (createChat has no such param, even in 0.16.x)"
is **correct** against the 0.16.4 source. no change needed.

### new diff findings

- **DF-1 (the bump itself):** uncommitted, self-described EXPERIMENT, recorded by no task, and the
  most likely cause of the user's NEW symptom. **recommend revert** (step 1) or device-confirm before
  merge.
- **DF-2 (low — `chat_controller.dart:80`):** the send-time guard catches only `on ArgumentError`.
  `ImageFileStore.persist` (and `readBytes`) can throw `FileSystemException` if the picker temp file
  is unreadable/vanished — that escapes uncaught as an unhandled async error with no "pick another"
  shown. consider broadening the catch to also route `FileSystemException` → `rejectPending()`.
  (FR-021 arguably covers an unreadable file.)
- **DF-3 (low — `attachment_controller.dart:141-146`):** pick-time size check was removed; oversized
  images are now rejected at send instead of at pick (later feedback, but the authoritative send-time
  guard still enforces FR-021). recommend a one-line note in `tasks.md` that this was an intentional
  consolidation so a future reviewer doesn't read it as a missing requirement.
- **DF-4 (info — `chat_controller.dart` / `image_file_store.dart`):** `_extensionOf` is duplicated
  verbatim; the controller could let `persist` infer the extension. pre-existing, out of scope.

---

## 6. what can only be confirmed on-device

the automated suite **cannot** detect this symptom by design (Principle VII seam isolation):

- `FakeGemmaService.loadModel` always succeeds and reports image:true, so
  `modelCapabilitiesProvider` never flips to textOnly in tests; the load-fail → textOnly → "image
  removed" path is never exercised.
- `attachment_capability_test.dart` overrides `modelCapabilitiesProvider` with a hand-driven
  provider, stubbing out the real session-error derivation and the real `getActiveModel` native path.
- `flutter_gemma` is imported in exactly one file (the seam), and tests never load it.

so the green 88/88 baseline gives **no assurance** about the user's symptom. two things require an
on-device run on the A34:

1. **direct confirmation of the failure layer** — that `getActiveModel(supportImage:true,
   maxNumImages:1)` actually throws for *both* gpu and cpu at native 0.12.0-a `engine_create` /
   vision-init (logcat, step 2). the `.so` is opaque to static analysis.
2. **disambiguating the bump from the transient-loading path** — revert to `^0.15.0`, `pub get`,
   rebuild, and observe: if the note clears and the symptom reverts to the (a) grounding gap, the
   0.16.4 bump is confirmed as the cause; if the note persists on 0.15.3, the `AsyncLoading` window
   (case A) is implicated instead.
