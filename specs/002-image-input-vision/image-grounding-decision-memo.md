# Image-Grounding Decision Memo — 002-image-input-vision

**Date:** 2026-06-14 · **Branch:** 006-device-validation · **Phase:** v1 release-validation
**Author:** engineering · **Status:** DECISION PENDING (recommendation below; human decides, follow-up applies)

This memo reviews the evidence for the image-grounding failure, lays out the options with their
trade-offs, and gives a single recommendation. It deliberately **stops at the recommendation** —
no code, pubspec, pin, or doc is changed here. A separate follow-up applies whichever option the
human picks.

---

## 1. Current state

The app is on **flutter_gemma 0.15.3** (`pubspec.yaml` line 34 = `^0.15.0`; `pubspec.lock` resolves
`0.15.3`, sha256 `b1491d0c…`). On the verified baseline device (Samsung Galaxy A34, SM-A346E,
Mali-G68), **everything works except one thing.**

**What works on 0.15.3 / A34 (verified on device):**

- **Text chat + streaming** — the 001 foundation; the shipped baseline.
- **Audio grounding** — VERIFIED word-perfect: Gemma 4 E2B transcribes a 7.3 s 16 kHz mono PCM16
  WAV and answers a text-only follow-up from session context, GPU LM backend first try
  (`specs/003-audio-input/spike-findings.md`; memory note `audio-grounding-works-litertlm-015`).
- **Function calling** — VERIFIED: 83.3% no-instruction floor, end-of-stream typed call event
  (memory note `function-calling-works-litertlm-015`).
- **Memory (remember/forget facts)** — VERIFIED: 005 gate passed, 80% auto-capture, 0 false-pos
  (memory note `memory-capture-works-litertlm-015`).
- **Web research (006)** — host-side complete; device validation is the *only* remaining 006 item.

**The one broken thing — image grounding:**

The model answers as if **no image were attached** ("Please provide the image you are referring
to…"), even though the image demonstrably reaches the model. This is a **native-layer gap, not a
code bug and not a missing-vision model:**

- The 002 **Dart plumbing is correct end-to-end** and is independently audited: capability gate →
  pick → preview → persist → in-bubble render → `GemmaService` seam passes image bytes →
  `Message.withImage`. The audit (`audit-report.md`) is **PASS-WITH-NOTES** with all three medium
  findings already fixed (88/88 then 89/89 tests; `flutter analyze` clean; both seam guards exit 0).
  No finding implicates the image-send path itself.
- The **native vision encoder actually runs** on the A34: `stb_image_preprocessor` resize
  1536×1152 → 912×672, 2394 patches, `vision_280` / `vision_adapter_280` signatures — a text-only
  artifact cannot run a vision encoder, so the downloaded `.litertlm` **is** multimodal
  (memory note `image-grounding-litertlm-015`; reproduced 3×).
- The **exact mechanism is captured in logcat** (release build, 2026-06-09): the plugin logs
  `[transformToChatPrompt] litertlm non-iOS, using raw text` and `messageType=MessageType.text`
  **even though the seam sent `Message.withImage`**. The Android `.litertlm` path templates the
  prompt as plain text and delegates image-token splicing to native LiteRT-LM, which never inserts
  the image placeholder → the decoder attends to no image. This is **below the Dart seam**, in
  flutter_gemma's `.litertlm` non-iOS templating / native LiteRT-LM runtime.

**Why this is the vision path specifically, not a general multimodal defect:** audio grounding
works on the *same* plugin, model, and device. Only the vision token-splicing path is broken.

**Evidence files:**
`specs/002-image-input-vision/diagnosis-and-audit-2026-06-08.md` (root-cause analysis),
`specs/002-image-input-vision/audit-report.md` (task-by-task audit, PASS-WITH-NOTES),
`specs/002-image-input-vision/research.md` R1 (pre-registered the "verify grounding on the A34"
risk that has now fired), and memory notes `image-grounding-litertlm-015`,
`audio-grounding-works-litertlm-015`, `flutter-gemma-0164-image-removed-regression`.

> Note on a *second, worse* symptom: the uncommitted 0.15.3 → 0.16.4 "EXPERIMENT" bump produced a
> client-side note "image removed — this model does not accept images" because the model **failed
> to load** on 0.16.4 (capabilities flipped text-only). That bump was **reverted + hardened** on
> 2026-06-08; the current tree is clean on 0.15.3. That regression is the central constraint for any
> re-pin option (§2). Do not conflate it with the grounding gap — on 0.16.4 the image never even
> left the composer; on 0.15.3 it is at least sent and encoded.

---

## 2. Constraints

1. **The 0.16.x A34 model-LOAD regression.** On the A34, `getActiveModel(supportImage:true)` most
   likely throws at native `engine_create` on the LiteRT-LM **v0.12.0** binary (bundled by every
   0.16.x release), for both GPU and CPU → `ModelLoadException` → capabilities flip to text-only.
   The one substantive runtime change between 0.15.3 and 0.16.4 is the native LiteRT-LM library
   (`native-v0.11.0-b` → `native-v0.12.0-a`); the Dart vision path is byte-identical across the two.
   **Any re-pin to 0.16.x re-introduces this load regression unless it is proven gone on device.**
2. **`flutter_riverpod` is pinned exact `3.3.1`** (not a caret) on purpose — orthogonal to this
   decision but a reminder that pins here are deliberate, not incidental.
3. **Constitution: on-device-only, offline-first.** Any model swap (option c) must keep a fully
   on-device, offline-capable Gemma/LiteRT artifact; nothing about the fix may add egress.
4. **Device-verification cost.** Tests cannot detect any of this by design (Principle VII seam
   isolation: `FakeGemmaService` always loads and reports `image:true`). The host suite gives **zero
   assurance** about grounding or native load. Every plugin/model change therefore costs a full
   on-device session on the A34: model load + image grounding + a regression sweep of
   text/audio/tools/memory/web, plus re-confirming the 001 Android gotchas (Impeller-off,
   FGS `dataSync`, release-build R8 `isMinifyEnabled=false`). That device cost is the dominant
   factor in every option below.
5. **The A34 is the only verified baseline device available to validation right now** — and this
   task explicitly has no device and may not run `flutter drive` or `flutter test integration_test`.
   So any option requiring device re-verification is **out of this validation pass's hands** and
   becomes a scheduled human/device task.

---

## 3. Changelog / pub.dev findings (network check performed)

**Network access was available.** Checked the pub.dev changelog and the GitHub README/repo for
flutter_gemma (June 2026). Findings:

- **Latest version is 0.16.5**, published ~3 days ago (2026-06-10). Versions after 0.15.3:
  0.15.4, 0.16.0, 0.16.1, 0.16.2, 0.16.3, 0.16.4, 0.16.5.
- **No release after 0.15.3 claims a Gemma 4 image / vision / grounding fix.** The image/vision/
  multimodal-relevant deltas are unrelated to the grounding gap:
  - **0.16.1** — *"LiteRT-LM v0.12.0 native bump"* (this is exactly the native binary the diagnosis
    pinned as the A34 model-load regression cause; it is present in **all** 0.16.x).
  - **0.16.2** — `activeBackend` getter + NPU→GPU→CPU fallback with `BackendInitException` on the
    FFI path (the new init pipeline the diagnosis flagged; surfaces load failures rather than fixing
    them); web `.litertlm` early preview, **text-only**.
  - **0.16.3** — Qualcomm NPU dispatch; **fix Android GPU sampler CPU fallback** (perf, ~3× decode —
    matches the `libLiteRtTopKOpenClSampler.so`/`…WebGpuSampler.so` missing → CPU-sampling
    perf-only note already seen on the A34; **not** a grounding fix).
  - **0.16.4** — fix embedding freezing the UI thread (background isolate) — unrelated.
  - **0.16.5** — fix `getActiveModel()` StateError on startup (single-flight init); fix KV-cache
    bleed between sequential chats — **both load/session correctness, neither a vision-grounding
    fix.** (The 0.16.5 `getActiveModel` startup fix is *load-path adjacent* but is about a
    single-flight init StateError, not the A34 native `engine_create` vision rejection on
    LiteRT-LM v0.12.0; there is no evidence it addresses the A34 load regression, and 0.16.5 still
    ships the v0.12.0 native binary.)
- **0.15.4** — no image/vision/load entries; it is the last release on the **v0.11.0** native binary
  before the 0.16.x v0.12.0 bump. It is the *only* post-0.15.3 version that does **not** carry the
  suspected-regression native binary — but its changelog shows **no grounding fix** either, so it is
  unlikely to fix the gap.
- The GitHub README confirms Gemma 4 E2B "multimodal vision and audio support" but documents **no**
  troubleshooting for vision grounding, no LiteRT-LM-version-for-vision requirement, and no
  A34/Mali/Samsung device note. 14 open issues exist (not individually triaged here).

**Conclusion of the network check:** there is **no published flutter_gemma release that fixes native
image grounding without also shipping the LiteRT-LM v0.12.0 binary tied to the A34 model-load
regression** (0.16.x), and the only non-v0.12.0 post-0.15.3 release (0.15.4) advertises no grounding
fix. A re-pin is therefore a *speculative* fix, not an evidence-backed one.

Sources: [flutter_gemma changelog](https://pub.dev/packages/flutter_gemma/changelog),
[flutter_gemma on pub.dev](https://pub.dev/packages/flutter_gemma),
[DenisovAV/flutter_gemma (GitHub)](https://github.com/DenisovAV/flutter_gemma).

---

## 4. Options

### (a) Accept-and-document for v1 — ship image input degraded, with an honest note

Keep 0.15.3. Keep the (correct, audited) Dart plumbing. Because the model attends to no image, the
*honest* user-facing posture is one of:
- **(a1)** ship with the attach control present but an honest "image understanding is limited on
  this model" disclosure when an image is sent, **or**
- **(a2)** gate the attach affordance off for v1 via the existing capability-as-data path (set
  `supportsImage: false` in the catalog so the composer simply doesn't offer attach — the same
  mechanism that already hides it for text-only models), and re-enable when grounding is fixed.

Option (a2) is the cleaner honest degradation: capability-driven UX (Principle III) says don't offer
an input the active model can't truly handle. (a1) keeps the surface but risks reading as broken.

- **Effort:** very low. (a2) is a one-line catalog data change + a doc note; (a1) is a small copy/UX
  change. No new device session strictly required to *ship* (the failure is already characterized),
  though a quick on-device sanity pass is advisable.
- **Risk:** lowest. No plugin bump → **no chance of re-introducing the model-load regression**; all
  verified capabilities (text/audio/tools/memory/web) are untouched and byte-identical. Risk is
  purely product/expectation (users wanted vision).
- **Re-verify on device:** none mandatory for (a2) beyond confirming the attach control is absent
  and the other capabilities still pass a smoke test (already known-good).
- **v1-timeline impact:** none — unblocks v1 immediately.

### (b) Re-pin to a newer flutter_gemma that *might* fix grounding (0.16.x / 0.16.5)

- **Effort:** medium for the bump itself; **high once the mandatory device session is counted.**
- **Risk:** **high.** Per §2/§3, all 0.16.x ship LiteRT-LM v0.12.0 — the exact binary tied to the
  A34 `engine_create` model-load failure that already bit us once (and was reverted). And the
  changelog shows **no Gemma 4 grounding fix**, so the upside is *speculative*: the most likely
  outcome is re-introducing the worse "model fails to load → text-only" regression while **not**
  fixing grounding. Net could be strictly worse than today.
- **Must be re-verified on device (A34), gated before it touches a feature branch:** model **load**
  (GPU then CPU; watch logcat for `BackendInitException` / `engine_create` vision errors) → image
  grounding (does the model finally attend to the image?) → **full regression sweep**: text chat,
  audio grounding, function calling, memory capture/forget, web research → 001 Android gotchas
  (Impeller-off, FGS `dataSync`, release R8 keep rules) against the new native binary →
  re-validate the riverpod/drift/sqlite3 transitive set. This is a full quickstart V1–V9 run plus
  the 003/004/005/006 device sweeps.
- **v1-timeline impact:** **large.** Blocks v1 on a multi-hour device session with a real chance of
  a revert cycle. Highest-variance option.

### (c) Swap the model (different Gemma / LiteRT build whose vision path works on this stack)

Pursue grounding at the artifact layer (the diagnosis' actual recommended lever): confirm the
intended multimodal `.litertlm`, try pinning a specific HF revision, or a corrected
image-prompt/chat-template, per the 0.15.0 CHANGELOG workaround family for the post-MTP
encoder-rejection issue.

- **Effort:** **high and uncertain.** Requires sourcing/validating an alternate vision artifact that
  is on-device + offline-capable, fits the 8 GB A34 budget, and works through 0.15.3's `.litertlm`
  templating path — none of which is guaranteed to exist. May also re-trigger the model-download
  pipeline + public-storage handling.
- **Risk:** medium-high and **open-ended.** The grounding break is in the plugin's `.litertlm`
  non-iOS templating ("using raw text", image placeholder never spliced) — a *different* artifact
  may hit the same plain-text templating path and still fail to ground, because the defect is at the
  splicing layer, not necessarily the artifact. Could burn device cycles with no fix.
- **Must be re-verified on device:** model download/adoption → load → image grounding → the same
  full regression sweep as (b), plus re-confirming text/audio/tools/memory/web on the new artifact
  (a new model can regress any capability, not just vision).
- **v1-timeline impact:** **large and unpredictable** — research-shaped, not a known landing.

### (d) Defer image input entirely past v1

Remove image input from the v1 surface (same capability-off mechanism as (a2)), and formally move
002 to a post-v1 milestone — i.e. (a2) but stated as a roadmap decision rather than a "degraded
feature" disclosure.

- **Effort:** very low (functionally identical to (a2): catalog `supportsImage: false` + docs).
- **Risk:** lowest (same as (a)). No plugin/model change.
- **Re-verify on device:** none mandatory beyond a smoke test.
- **v1-timeline impact:** none — unblocks v1.
- **Difference from (a):** (d) is a *scope* statement (vision is not a v1 feature); (a) is a
  *quality* statement (vision ships but is honestly limited). The code change is essentially the
  same; the difference is product framing and what the v1 changelog/marketing claims.

---

## 5. Recommendation

**Recommended: Option (a2) — accept-and-document for v1 by hiding the attach affordance via the
existing capability-as-data path, framed per option (d) as "image input deferred past v1," and keep
the audited Dart plumbing in place behind the gate.**

In practice this is the (a2)/(d) convergence: a one-line, low-risk catalog data change
(`supportsImage: false`) that uses the *already-built, already-tested* capability gate to stop
offering an input the model cannot honestly handle (Principle III), while preserving every line of
the correct, audited 002 implementation so re-enabling later is trivial.

**Reasoning:**

- **The fix is not in our hands, and not in any shipping plugin version.** The network check is
  unambiguous: no release through 0.16.5 fixes Gemma 4 grounding, and every 0.16.x re-introduces the
  A34 load regression we already reverted once. Re-pinning (b) is a speculative bet with a
  known, severe downside and no changelog-backed upside.
- **It protects everything that works.** Text, audio, function calling, memory, and web research are
  all verified on 0.15.3/A34. Options (b) and (c) put *all* of them back into a regression sweep to
  chase one feature; (a2) touches none of them.
- **It is honest and on-constitution.** Hiding the affordance is exactly what capability-driven UX
  prescribes when the active model can't truly handle the input — better than shipping an attach
  button that produces "please provide the image."
- **It unblocks v1 now** with no device-session dependency on the critical path, while the device
  validation pass (006) and the harder grounding work (b/c) continue off the release path.
- **It is fully reversible.** The plumbing stays; re-enabling is flipping one catalog flag once a
  real grounding fix (artifact or a future plugin release with an actual Gemma 4 vision fix **and** a
  confirmed-clean A34 load) is verified on device.

Pursue the *real* grounding fix (option c, artifact/templating layer — the diagnosis' recommended
lever) and any future plugin re-pin (option b) as **post-v1, device-gated experiments on a throwaway
branch**, never on the v1 release path.

---

### If the human instead chooses option (b) — the exact next verification step

Do **not** change the pin in this validation pass. The actionable, device-gated procedure (for a
throwaway branch, A34, screen timeout raised: `adb shell svc power stayon true`) is:

1. On a throwaway branch, set `pubspec.yaml` `flutter_gemma:` to the candidate (e.g. `^0.16.0` →
   resolves 0.16.5), `flutter pub get`, commit `pubspec.lock`, `flutter analyze
   --fatal-infos --fatal-warnings`, `flutter test`.
2. Build and install on the A34 (`flutter run -d <a34-id>`; the A34 can appear twice in
   `adb devices`, so pass `-d` explicitly; release builds need R8 `isMinifyEnabled=false`).
3. **Watch model load** — the make-or-break gate:
   `adb logcat | grep -Ei 'FlutterGemmaMobile|LiteRtLmFfi|BackendInit|engine_create|vision'`
   at load time. If `getActiveModel(supportImage:true)` throws `BackendInitException` /
   `engine_create` on **both** GPU and CPU, the A34 load regression is back → **stop and revert**
   (this is the known failure; the bump is dead on arrival).
4. **Only if it loads:** send an image + "what's in this picture?" and confirm the reply actually
   attends to the image (no "please provide the image"; check logcat does **not** say
   `[transformToChatPrompt] … using raw text` / `messageType=MessageType.text` for the image turn).
5. **Only if grounding works:** run the full regression sweep — text chat, audio grounding
   (003), function calling (004), memory capture/forget (005), web research (006) — plus the 001
   Android gotchas (Impeller-off, FGS `dataSync`). Any regression → revert.
6. Merge the bump to a feature branch **only** after steps 3–5 all pass on the A34.

Do **not** run `flutter test integration_test/...` at any point — it wipes the on-device model + DB
(use `flutter drive` for device-stateful runs).

**End of memo — recommendation stands; no code, pubspec, pin, or doc is changed by this document.**
