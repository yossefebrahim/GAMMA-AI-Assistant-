# Phase 0 Spike Findings — Audio Input via flutter_gemma on Gemma 4 E2B

**Feature**: 003-audio-input | **Date**: 2026-06-10 | **Device**: Samsung A34 (SM-A346E, Dimensity 1080, 7.3 GiB usable RAM) | **Stack under test**: flutter_gemma 0.15.3 (installed, pinned `^0.15.0`) + `litert-community/gemma-4-E2B-it.litertlm` (2,588,147,712 bytes, the artifact already on the device)

**Question**: does Gemma 4 E2B support audio input through flutter_gemma on Android — verified empirically, not from docs?

**DECISION GATE STATUS**: ✅ **PASS** — audio input works end-to-end on the A34: word-perfect transcription of a 7.3 s speech clip, correct multi-turn follow-up from audio context, GPU LM backend, ~3.0 GB peak RSS (no OOM headroom concerns), no fallback needed. Full evidence in section 3; gate reasoning in section 4.

---

## 1. flutter_gemma ^0.15.0 audio API (source inspection, pub cache `flutter_gemma-0.15.3`)

### 1.1 Exact API

Audio is a first-class `Message` part, mirroring images exactly:

| Surface | API | Evidence |
|---|---|---|
| Message | `Message.withAudio({text, audioBytes, isUser})`, `Message.audioOnly({audioBytes, ...})`, `Uint8List? audioBytes`, `bool get hasAudio` | `lib/core/message.dart:18,27,32,116-138` |
| Model activation | `FlutterGemma.getActiveModel(..., bool supportAudio = false)` | `lib/core/api/flutter_gemma.dart:233-240` |
| Chat/session | `createChat(..., bool? supportAudio)` → `enableAudioModality` | `lib/flutter_gemma_interface.dart:142,157,174,181` |
| Platform channel (MediaPipe path only) | `PlatformService.addAudio(Uint8List)` | `lib/pigeon.g.dart:349-357` |

There is **no separate public setAudio** — the flow is `Message.withAudio/audioOnly` → `chat.addQueryChunk` → `generateChatResponseAsync()`, identical in shape to the 002 image flow.

### 1.2 ModelType gating — `gemma4` passes

**There is no ModelType-based audio gate anywhere in the package.** The `ModelType` enum (`lib/core/model.dart:1-12`) is `{general, gemmaIt, gemma4, deepSeek, qwen, qwen3, llama, hammer, functionGemma, phi}` — **no `gemma3n` value exists at all**. The "Gemma 3n E4B only" wording is stale doc comments (`lib/flutter_gemma_interface.dart:43,56,134,142`), never code. Audio is gated only by:

1. the developer-supplied booleans `supportAudio` (createModel/getActiveModel) and `enableAudioModality` (session/chat) — `lib/mobile/flutter_gemma_mobile.dart:130-135` throws `ArgumentError('This model does not support audio')` if the flag is off (MediaPipe path); the FFI path **silently drops** audio instead (`lib/core/ffi/ffi_inference_model.dart:247` — a mis-set flag fails quietly, a seam-design hazard for 003);
2. the engine path: MediaPipe (`.task`) declares `supportsAudio = false // Audio is LiteRT-LM only` (`android/.../MediaPipeEngine.kt:29`); **LiteRT-LM (`.litertlm`) is the designed audio path**.

`ModelType.gemma4` not only passes — the FFI session has an **explicit gemma4 branch** that forwards `audioBytes` into `ffiClient.chatRaw(...)` (`lib/core/ffi/ffi_inference_model.dart:268-277`). README:103 explicitly claims "Gemma 4 E2B — text, image, audio".

### 1.3 Android native path for `.litertlm`

The `.litertlm` path **bypasses the Kotlin layer entirely** (the Kotlin LiteRT engine was dropped in 0.14.0): Dart FFI `LiteRtLmFfiClient.initialize(..., enableAudio: supportAudio)` sets the LiteRT-LM **audio executor backend to `'cpu'` — hardcoded** (`lib/core/ffi/litert_lm_client.dart:299`: `enableAudio ? 'cpu'.toNativeUtf8() : nullptr`, into `engine.h:164-169` `audio_backend_str`). Audio bytes travel as `{'type': 'audio', 'blob': base64}` content parts in the Conversation-API JSON (`litert_lm_client.dart:528-543`); the C enum has `kInputAudio`/`kInputAudioEnd` (`engine.h:143-144`).

**Answer to "does GPU handle audio": the audio encoder always runs on CPU by plugin design; only the LM itself is GPU/CPU-selectable.** This is not configurable from the app.

### 1.4 Expected audio format

**No format validators, sample-rate constants, or max-duration/size caps exist anywhere in the plugin** — bytes pass through opaquely and a wrong format fails only at inference time. The contract is documented/demonstrated, not enforced:

- **WAV container, 16 kHz, 16-bit PCM, mono** — `lib/web/flutter_gemma_web.dart:82` ("PCM audio (16kHz, 16-bit, mono)"); the bundled example records exactly this via the `record` package (`example/lib/chat_input_field.dart:166-174`: `encoder: AudioEncoder.wav, sampleRate: 16000`, sent unconverted) and `example/lib/utils/audio_converter.dart:8,11` (`targetSampleRate = 16000`, PCM16, mono downmix).
- **Max duration: none enforced by the plugin.** 003 must impose its own clip cap (memory + context-token budget driven, not plugin driven). Gemma audio encoders consume ~6.25 tokens/sec of audio (per Google's Gemma 3n documentation), so clip length interacts with the 2048-token context.

### 1.5 0.16.4 comparison (fallback context)

0.16.4's audio surface is **identical** — the CHANGELOG shows zero audio changes between 0.15.3 and 0.16.4 (audio landed in 0.12.3, Gemma 4 audio claims in 0.13.0). Upgrading to 0.16.4 buys no audio capability and re-introduces the known model-load regression on the A34. **Conclusion: stay on `^0.15.0` for 003.**

## 2. Does the Gemma 4 E2B `.litertlm` include the audio encoder/adapter? — YES, verified two ways

### 2.1 On-device artifact (the actual downloaded file)

Read-only header parse of `/data/data/com.example.ai_assistant/app_flutter/models/gemma-4-e2b.litertlm` (first 8 MB + tail via `adb exec-out run-as ... dd`; LITERTLM magic, version 1; 12 sections tiling the 2,588,147,712-byte file exactly):

| Section | Size | Relevance |
|---|---|---|
| `tf_lite_audio_encoder_hw` | ~94.1 MB | **audio encoder present** (dense weight data confirmed at its offset, not padding) |
| `tf_lite_audio_adapter` | ~8.5 MB | **audio adapter present** |
| `tf_lite_end_of_audio` | ~6.6 KB | audio end-marker model |
| `tf_lite_vision_encoder` / `tf_lite_vision_adapter` / `tf_lite_end_of_vision` | ~230 MB | vision stack (002) |
| `tf_lite_prefill_decode`, `tf_lite_embedder`, `tf_lite_per_layer_embedder`, `tf_lite_mtp_drafter`, tokenizer, llm_metadata | ~2.25 GB | text stack |

The `llm_metadata` proto section additionally defines `<|audio>` / `<audio|>` special-token delimiters alongside the image tokens. Note the `_hw` suffix and `backend_constraint` metadata on the audio encoder (hardware/delegate-targeted build) — flagged as a residual unknown for the CPU audio executor until the runtime test passes.

### 2.2 Hugging Face repo (control experiment)

Same header parse via HTTP Range request on `litert-community/gemma-4-E2B-it-litert-lm` → identical 10 TFLite sections including audio encoder+adapter. **Methodology control**: the repo's `gemma-4-E2B-it-web.litertlm` ("currently text-only" per the model card) shows *only* `tf_lite_artisan_text_decoder` — the section listing reliably discriminates modalities. Model card prose: "the Vision and Audio models are loaded on demand to further reduce memory consumption." The repo's `chat_template.jinja` emits `<|audio|>` for `type == 'audio'` parts.

## 3. On-device empirical test (the decisive evidence)

**Why mandatory**: this project's own history proves API-plumbing-correct ≠ modality-works — on this exact stack, 002's image plumbing is verified correct and the vision encoder demonstrably runs, yet Gemma 4 E2B replies "please provide the image" (native chat-templating/token-splicing gap). Audio could fail identically, so sections 1–2 alone cannot pass the gate.

**Method**: throwaway `integration_test/spike_audio_grounding_test.dart` (committed on this branch, marked DO NOT SHIP) mirroring `FlutterGemmaService`'s exact load recipe (`installModel(gemma4, litertlm)` → `getActiveModel(maxTokens: 2048, GPU-first/CPU-fallback, supportAudio: true)` → `createChat(supportAudio: true)`), driving three turns:

1. text-only baseline ("capital of france") — RAM/latency reference;
2. `Message.withAudio` with a 7.3 s synthesized-speech WAV (16 kHz mono PCM16, 238 KB, distinctive nonsense sentence: "the yellow elephant danced on a purple piano at midnight, while seven green turtles sang quietly under the old wooden bridge") + "transcribe exactly" prompt;
3. text follow-up ("which animal was mentioned first in that audio?") — multi-turn audio-context retention.

RSS sampled every 200 ms (`ProcessInfo.currentRss`) with per-stage peaks; `MemAvailable` snapshots; `addQueryChunk` (where prefill/encode happens on this plugin version) timed separately from streaming. Debug-build Dart harness; inference itself runs in the release-built native engine, so latency numbers are indicative, not release-grade (002's formal SCs were measured `--release`).

### Results (run of 2026-06-10, `flutter drive`, GPU backend activated first try, exit 0)

| Stage | RSS | MemAvailable | addQueryChunk | first token | total gen | reply |
|---|---|---|---|---|---|---|
| baseline (pre-load) | 382 MB | 3423 MB | — | — | — | — |
| model loaded (GPU, 12.07 s) | 2804 MB | 1721 MB | — | — | — | — |
| text baseline | 2829 MB | 1786 MB | 7 ms | 826 ms | 1548 ms (7 tok) | "The capital of France is Paris." |
| **audio turn (7.3 s clip)** | 2976 MB (peak 3007) | 1833 MB | 1 ms | **3907 ms** | **6483 ms (22 tok)** | **"The yellow elephant danced on a purple piano at midnight while seven green turtles sang quietly under the old wooden bridge."** |
| follow-up (text-only) | 2979 MB | 1829 MB | 1 ms | 667 ms | 1418 ms (7 tok) | "The yellow elephant was mentioned first." |
| after close() | 2314 MB | 1995 MB | — | — | — | — |

**Answers to the three spike measurements:**

1. **Peak RAM, audio vs text baseline**: +147 MB RSS for the audio turn over the post-text-turn level (2829 → 2976 MB, peak 3007 MB) — consistent with the lazy-loaded ~103 MB audio encoder+adapter plus activations. Peak total ~3.0 GB RSS on the 7.3 GiB device with ~1.8 GB still available: **no OOM risk at this clip length**; headroom comfortably absorbs it.
2. **Latency for the ~7 s clip**: first token 3.9 s, full 22-token reply in 6.5 s (vs 0.8 s / 1.5 s text baseline). The audio encode + prefill cost lands inside the time-to-first-token (addQueryChunk itself returned in 1 ms — encoding happens at generation start on the FFI path, *not* at addQueryChunk like the MediaPipe image path). Numbers from a debug-harness run (native engine is release-built regardless); treat as indicative, re-measure `--release` for formal SCs.
3. **GPU vs CPU**: the GPU LM backend activated first-try **with `supportAudio: true`** (no fallback, no load regression — load 12.07 s, in line with text-only loads). The audio **encoder** itself always runs on CPU by plugin design (hardcoded `'cpu'` executor backend, section 1.3); this is invisible to the app and adequately fast (within the 3.9 s first-token figure).

**Grounding verdict — the question that killed images, answered for audio**: transcription was **word-perfect** across all 21 words of a deliberately nonsensical sentence (zero hallucination, zero "please provide the audio"), and the follow-up turn answered correctly from session context without re-sending the clip. On the same plugin version, same model file, and same device where image grounding fails, **audio grounding fully works** — the image gap is vision-path-specific (token-splicing at the native layer), not a general multimodal defect.

## 4. Decision gate

**PASS.** All three gate conditions hold on the A34:

1. **Supported**: flutter_gemma 0.15.3 exposes a complete audio API with no ModelType gate; `ModelType.gemma4` + `.litertlm` is the designed path (section 1).
2. **Model has the capability**: the deployed artifact bundles the audio encoder/adapter and audio special tokens (section 2, verified on the actual on-device file).
3. **Usable**: empirically grounded, word-perfect, multi-turn, GPU backend, ~3.0 GB peak RSS with ~1.8 GB headroom, ~4 s to first token for a 7 s clip (section 3).

No fallback (Gemma 3n catalog entry / STT pipeline) is needed. **Proceed to /specify.**

### Incident log (for reproducibility)

- First run failed at gradle: the dependabot AGP 9.2.1 / Kotlin 2.4.0 bumps had broken `android/app/build.gradle.kts` script compilation on main (error-level DSL deprecations) — nothing had been built since they merged. Temporarily suppressed, then properly fixed via the Flutter-template-shaped migration (kotlin `compilerOptions` block; `newDsl=false` stays, flutter#180137).
- Second run (`flutter test integration_test/...`) **uninstalled the app and wiped its data** — including the downloaded 2.4 GB model and the drift DB (conversations). That command treats the app as a hermetic test artifact. Recovered by: `adb install -r` of the built APK + re-download of the `.litertlm` on the host + `adb push` to `/data/local/tmp` + on-device pipe-copy into `app_flutter/models/` as the app uid. **Rule for 003's manual test script: device-stateful integration runs use `flutter drive` (test_driver/integration_test.dart), never `flutter test`.** Note: the app's `model_install` DB row was also wiped, so the app UI will re-prompt for download on next launch even though the file is present — re-syncing that row (or re-downloading through the app once) is a known post-spike cleanup for the device.

## 5. Implications for the 003 design (carried into /specify and /plan regardless of gate outcome)

- **Recorder package**: the format the plugin expects (WAV 16 kHz mono PCM16) is exactly what the `record` package emits natively (`AudioEncoder.wav, sampleRate: 16000, numChannels: 1`) — flutter_gemma's own example uses it with **zero transcoding**. Strong prior for `record` over `flutter_sound` in Phase 2.
- **Silent-drop hazard**: the FFI path drops audio without error if `supportAudio` wasn't set at load — the 003 seam must gate on `capabilities.audio` *before* calling the plugin (StateError, mirroring the 002 image contract) rather than relying on plugin errors.
- **Audio encoder is CPU-only by plugin design** (hardcoded `'cpu'` executor); plus the known 0.15.3 issue that prefill/encode runs on the **Android main thread** — expect the audio-encode blocking window to behave like the ~1 s image-encode freeze, scaled by clip length. Clip caps are a UX/memory decision 003 must own (the plugin enforces none).
- **No new model artifact**: audio encoder+adapter (~103 MB, lazy-loaded) ship inside the existing 2.4 GB download — 001's download machinery is untouched.
- `ModelCapabilities.audio` already exists (default false) and the composer already gates a (dead, audit-L9) mic stub on it — 003 wires data through the established catalog → loadModel → capabilities → provider flow.
