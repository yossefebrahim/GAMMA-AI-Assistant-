# Phase 0 Spike Findings — Function Calling via flutter_gemma on Gemma 4 E2B

**Feature**: 004-function-calling | **Date**: 2026-06-10 | **Device**: Samsung A34 (SM-A346E, Dimensity 1080, 7.3 GiB usable RAM) | **Stack under test**: flutter_gemma 0.15.3 (installed, pinned `^0.15.0`) + `litert-community/gemma-4-E2B-it.litertlm` (the artifact already on the device)

**Question**: does Gemma 4 E2B support **reliable** function calling through flutter_gemma on Android — verified empirically over ~20 varied prompts, not from docs?

**DECISION GATE STATUS**: ✅ **PASS** — 83.3% correct-call rate (10/12 should-call prompts) with a
clean failure profile: **zero** hallucinated tools, **zero** malformed args, **zero** spurious
calls on plain-text prompts, **zero** calls against unregistered-tool probes, and 10/10 grounded
round-trip answers. The two misses were conservative (answered in prose instead of calling). GPU
backend, ~2.9 GB peak RSS. Full evidence in section 3; gate reasoning in section 4. One
systematic hazard confirmed empirically: raw SDK JSON leaks into the text stream on **every**
tool call (10/10) — a hard design requirement for the seam, not an edge case.

---

## 1. flutter_gemma ^0.15.0 function-calling API (source inspection, pub cache `flutter_gemma-0.15.3`)

All claims below were independently re-derived and adversarially verified against the installed
source; the two load-bearing claims (the ModelType gate and the response path) survived dedicated
refutation passes.

### 1.1 Exact API — tools are declared at chat creation, never per-message

| Surface | API | Evidence |
|---|---|---|
| Tool declaration | `Tool({required String name, required String description, Map<String, dynamic> parameters = const {}})` — `parameters` is a standard JSON-Schema object map | `lib/core/tool.dart` (whole file, 23 lines) |
| Call policy | `enum ToolChoice { auto, required, none }` | `lib/core/tool.dart` |
| Chat creation | `createChat(..., List<Tool> tools = const [], bool? supportsFunctionCalls, ToolChoice toolChoice = ToolChoice.auto, int? maxFunctionBufferLength, String? systemInstruction)` | `lib/flutter_gemma_interface.dart:149-165` |
| Session creation (FFI) | `createSession(..., List<Tool> tools = const [])` → tools serialized into the native conversation config | `lib/core/ffi/ffi_inference_model.dart:81-93` |
| Typed responses | sealed `ModelResponse`: `TextResponse(token)`, `FunctionCallResponse({name, args})`, `ParallelFunctionCallResponse({calls})`, `ThinkingResponse(content)` | `lib/core/model_response.dart` |
| Tool result | `Message.toolResponse({required String toolName, required Map<String, dynamic> response})` (`isUser: true`, `type: MessageType.toolResponse`) | `lib/core/message.dart:140-151` |

`addQuery`/`addQueryChunk` carry **no** tools parameter — declarations are fixed per chat/session.

### 1.2 ModelType gating — `gemma4` passes; the gate is caller-supplied booleans

**There is no per-ModelType allowlist.** Function calling activates iff the caller passes all
three of `tools: [...]` (non-empty) + `supportsFunctionCalls: true` + `toolChoice != ToolChoice.none`
to `createChat`. `ModelType` selects only the *mechanism/format*, not eligibility
(`lib/core/chat.dart:151-155, 277-279, 395-399`).

`ModelType.gemma4` is annotated "Gemma 4 E2B/E4B with **native function calling tokens**"
(`lib/core/model.dart:1-12`) and gets a unique, SDK-native mechanism on our exact path
(Android + `.litertlm` → FFI, routed at `lib/mobile/flutter_gemma_mobile.dart:381-431`):

- **Prompt side**: gemma4 is explicitly **exempt** from Dart-side tools-prompt injection
  (`chat.dart:84-91` — "SDK renders `<|tool>declaration:...<tool|>` from tools_json passed at
  conversation creation, so a Dart-side prompt injection would double-wrap the tools"). Tools are
  serialized to OpenAI Chat-Completions format by `SdkResponseParser.serializeToolsForSdk`
  (`sdk_response_parser.dart:163-173`) and passed as `tools_json` into
  `litert_lm_conversation_config_create` (`litert_lm_client.dart:485-495`); the native SDK renders
  Gemma 4's tool tokens via its chat template.
- **Parse side**: the text-stream parser is a deliberate no-op for gemma4
  (`SdkPassthroughFunctionCallFormat`, factory at `function_call_format_factory.dart:20`); calls
  are instead extracted from the session's raw SDK JSON (`RawSdkResponseSession.lastRawResponse`,
  mixed into `FfiInferenceModelSession` at `ffi_inference_model.dart:188-189`) by
  `SdkResponseParser.extractToolCalls` (`sdk_response_parser.dart:34-121` — handles top-level
  `tool_calls`, `content[].type=="tool_call"`, concatenated multi-document JSON, and strips
  Gemma 4 `<|"|>` escape tokens).

Other model types for contrast: `functionGemma` gets a proprietary `<start_function_call>` format
+ developer-turn prompt + forced single-turn sessions; deepSeek/qwen/qwen3/llama/phi get per-model
text-parsing formats; gemmaIt/hammer/general fall back to a generic JSON prompt + parser. All pass
the same boolean gate.

### 1.3 How tool calls arrive — typed event at END of stream (gemma4 path)

`generateChatResponseAsync()` returns `Stream<ModelResponse>`. On the gemma4/FFI path:

1. Text tokens stream as `TextResponse` immediately (passthrough format never buffers).
2. The `FunctionCallResponse` (or `ParallelFunctionCallResponse` for multiple calls) is parsed
   from the raw SDK JSON **after the native stream ends** and yielded as the **final stream
   element** (`chat.dart:395-414`). **No mid-stream tool calls on this path** — "pause/resume"
   does not exist; the stream simply completes after the call event.
3. The sync `generateChatResponse()` behaves equivalently (`chat.dart:151-173`).

**Parallel calls**: supported in the type system and parser (`ParallelFunctionCallResponse`,
concatenated-JSON handling). Single call is the dominant observed shape; the spike measures what
E2B actually emits.

**Verified hazards on this path** (adversarial pass findings):

- **Raw-JSON text leak**: `extractTextFromResponse` (`litert_lm_client.dart:576-583`) returns a
  chunk **verbatim** into the text channel when the SDK chunk has no `content` key (the
  `{role, tool_calls:[...]}` shape) — so raw tool-call JSON **can appear as visible streamed
  text** before the typed event arrives. The consumer must tolerate/suppress this. (Empirical
  frequency measured in section 3.)
- **History omission**: the streaming gemma4 branch never writes the assistant's tool-call turn
  to the plugin-side chat history (`chat.dart:395-414` vs the sync path's `Message.toolCall` add
  at `165-168`) — multi-turn tool conversations degrade **if the consumer relies on plugin
  history**. Irrelevant for this app *by construction*: the seam replays history from the app DB
  every turn (`clearHistory(replayHistory:)`), so 004 must persist tool-call/tool-result turns in
  the app DB and include them in replay — which the feature requires anyway.
- **Silent no-op trap** (the audio lesson repeats): with `tools:` passed but
  `supportsFunctionCalls: false` (the default — exactly what the app passes today at
  `flutter_gemma_service.dart:141`), the FFI path **still injects the tool declarations natively**
  (`ffi_inference_model.dart:81` checks only `gemma4 && tools.isNotEmpty`) while the read side is
  gated off — the model can emit a tool call that is never surfaced (or leaks as raw JSON text).
  `chat.dart:106-110` only `debugPrint`s a warning. **The 004 seam must gate seam-side with a
  `StateError`** (mirroring the 002/003 image/audio gates) rather than trusting plugin errors.

### 1.4 Returning tool results — manual loop, plain-text `<tool_response>` wrapper

There is **no automatic re-invocation**. The consumer's loop (canonical pattern:
`example/lib/chat_screen.dart:211-219`; README documents it only partially):

```dart
// 1. receive FunctionCallResponse(name, args) as the final stream event
// 2. execute the tool yourself
// 3. return the result:
await chat.addQuery(Message.toolResponse(toolName: call.name, response: {...}));
// 4. resume by calling generate again (sync or async — fresh manual call):
final followUp = chat.generateChatResponseAsync();
// 5. loop if it returns another call
```

On Android/`.litertlm` the result reaches Gemma 4 as a **user-role plain-text block**
`<tool_response>\nTool Name: $toolName\nTool Response:\n$json\n</tool_response>`
(`extensions.dart:61-72, 91-99`). The native `role:"tool"` serializer
(`SdkResponseParser.buildToolResponseJson`, `sdk_response_parser.dart:182-196`) is **dead code in
0.15.3** — defined, never called. The model also re-sees its own tool-call turn only if the
consumer replays it (see history omission above).

### 1.5 FunctionGemma sidecar assessment (changelog/source)

- **What it is**: "Google's specialized function calling model" (CHANGELOG 0.11.14), 270M params,
  **284 MB** on disk (q8), `maxTokens: 1024`, FC ✅ / Thinking ❌ / Vision ❌. Example-catalog
  entries point at the plugin author's personal HF repo (`sasha-denisov/function-gemma-270M-it`),
  main mobile entry is a `.task` (MediaPipe path).
- **Single-turn mode** (CHANGELOG 0.11.15): `_isSingleTurnModel => modelType == functionGemma`
  (`chat.dart:42`) — history + session wiped after every text response; kept only across a
  pending tool response. No multi-turn conversational context, by design.
- **Co-residency: impossible through this plugin.** The plugin enforces a strict one-inference-
  model singleton (`flutter_gemma_mobile.dart:270-273, 321-334` — creating a different model
  **closes the old one first**; single `initializedModel` slot in the interface). The only
  sanctioned pairing is one inference + one *embedding* model.
- **Swap economics (estimate)**: FunctionGemma load ~1-3 s; the expensive direction is reloading
  E2B (2.4 GB re-mmap + GPU upload, ~12 s measured in the 003 spike) **plus** a full history
  re-prefill on the recreated session (main-thread prefill on 0.15.3). A router-sidecar round
  trip is realistically **10-20+ s of swap+replay latency per use** — not viable as an
  interactive fallback. RAM is not the binding constraint (284 MB weights + overhead would
  arithmetically fit next to E2B's ~3.0 GB peak in 7.3 GiB); the **plugin's singleton
  architecture is**.

**Conclusion**: the FunctionGemma option is effectively **off the table** for 004 unless E2B
fails the gate so badly that a single-model *replacement* (not sidecar) for tool turns would be
considered — a product decision, not a spike decision.

### 1.6 0.16.4 comparison (fallback context)

Not re-audited in depth for tools; 0.16.4 remains a known model-LOAD regression on the A34 (003
research R1) and is excluded as a path regardless of any tool-layer differences. The
`buildToolResponseJson` dead-code observation is 0.15.3-specific — do not assume it for 0.16.x.

## 2. What the app must add (seam shape, from the app-side audit)

Confirmed inert touchpoints today: `ModelCapabilities.functionCalling` exists (default false,
never set), `supportsFunctionCalls: false` hardcoded at `flutter_gemma_service.dart:141`, and the
generate loop already drops non-`TextResponse` events with an explicit "ignored this slice"
comment (`flutter_gemma_service.dart:239`). The 003-established pattern 004 copies:

- catalog: `ModelCatalog.supportsFunctionCalling` → `capabilities` (data, Principle III);
- seam: thread `supportsFunctionCalls: capabilities.functionCalling` + `tools:` into
  `createChat`; **seam-side synchronous `StateError`** when tools are requested while
  `!capabilities.functionCalling` (the silent-drop hazard, §1.3);
- stream: surface `FunctionCallResponse` through the seam as a typed event (the seam's `generate`
  currently yields bare `String` tokens — needs a richer event type or a parallel channel);
- persistence: tool-call/tool-result turns must live in the app DB and be included in
  `clearHistory(replayHistory:)` replays (plugin history can't be trusted for them, §1.3).

## 3. On-device empirical test (the decisive evidence)

**Method**: throwaway `integration_test/spike_function_calling_test.dart` (committed on this
branch, marked DO NOT SHIP) mirroring `FlutterGemmaService`'s exact load recipe
(`installModel(gemma4, litertlm)` → `getActiveModel(maxTokens: 2048, GPU-first/CPU-fallback)` →
`createChat(supportsFunctionCalls: true, tools: [get_device_info], toolChoice: auto)`). One
registered tool: `get_device_info` returning static sentinel JSON (`sm-a346e`, `7.4 GB`, `83%`…),
declared with one **optional** enum arg (`section`) so malformed args are measurable. 20 prompts —
12 should-call, 5 should-answer-in-text, 3 hallucination probes against unregistered tools
(timer / theme / weather) — each in a fresh single-turn context (`chat.clearHistory()`; the FFI
sessionCreator re-applies tools_json). Correct calls got the full round trip
(`Message.toolResponse` → resume) plus a sentinel-grounding check. No system instruction — raw
plugin-default behavior. Run via `flutter drive` (debug harness; native engine is release-built),
exit 0.

### Results (run of 2026-06-10, GPU backend first try, load 9.4 s, peak RSS 2904 MB)

| Metric | Result |
|---|---|
| **Correct-call rate (should-call set)** | **10/12 = 83.3%** — call + valid args |
| Missed calls (answered in prose instead) | 2/12 (trials 5, 6) |
| Malformed args | **0** across all 20 |
| Hallucinated tool names | **0** across all 20 |
| Spurious calls on plain-text prompts | **0**/5 (haiku, capital, binary search, translation, arithmetic — all prose) |
| Calls on unregistered-tool probes | **0**/3 (timer, theme, weather — all declined in prose) |
| Grounded round-trip answers | 10/10 (9 by automated marker + trial 10 verified manually, see below) |
| Raw-JSON leaks into the text stream | **10/10 calls** — systematic (§1.3 hazard confirmed) |
| Multi-call turns (`ParallelFunctionCallResponse`) | 0 — every call turn was a single call |
| Extra call on resume (looping) | 0/10 — every round trip terminated in text |

**Latency profile**: call turns reached the typed `FunctionCallResponse` in ~1.8–2.7 s
(first leaked token ~2.5 s); resumed answers took 1.6–15.4 s depending on length. No-call prose
answers started in ~0.6 s. Memory: 2749 MB RSS post-load → 2904 MB peak across all 20 trials +
round trips — same envelope as plain chat (003 measured ~3.0 GB peak); function calling adds no
meaningful RAM.

**Arg quality was a positive surprise**: the model used the *optional* `section` enum correctly
and idiomatically (`battery` for battery prompts, `hardware`, `storage`, `all` for "show me
everything", `{}` when unspecified) — schema-valid in 10/10 calls, with Gemma's `<|"|>` escape
tokens stripped cleanly by `SdkResponseParser`.

**The two misses (trials 5, 6)** — "give me a quick spec readout of this phone" and "what's the
exact model name of this handset?" — the model replied *"Please provide me with an image, a link,
or some other information"*: it failed to connect "this phone" to the available tool and went
text-first (~0.6 s first token, i.e. it never considered calling). Conservative failure: a
visible, recoverable prose reply — never a wrong call. A brief system instruction ("you run on
the user's phone; use get_device_info for questions about this device") is the obvious
reliability lever and was deliberately NOT used in the spike (raw baseline); treat ~83% as the
floor.

**Trial 10 nuance** ("which android version…"): the model passed `section: "memory"` (schema-
valid, semantically off) yet the resumed answer — "This device is running **Android 14**" — was
correct, because the executed tool returned the full info map regardless. Lesson for tool design:
prefer returning a superset over strict section filtering; the model extracts what it needs.

**Hallucination probes in detail**: "set a timer" → prose offer to help another way; "switch the
app to light theme" → prose explanation it can't control settings (no invented `set_theme` call —
relevant since 004 will *add* such a tool: the model calls only what is declared); "weather" →
prose decline. This is the strongest possible probe outcome: tool selection is driven entirely by
the declared registry.

## 4. Decision gate

**PASS.** All gate conditions hold on the A34:

1. **Supported**: flutter_gemma 0.15.3 has a complete, native function-calling path for
   `ModelType.gemma4` + `.litertlm` + Android FFI — no ModelType gate, SDK-native declarations,
   typed call events, working round trip (section 1, adversarially verified).
2. **Reliable**: 83.3% correct-call rate ≥ the 80% bar, with the *right kind* of failures —
   misses are conservative prose answers; zero hallucinated tools, zero malformed args, zero
   spurious calls across 20 varied prompts (section 3). The no-system-instruction baseline means
   headroom, not ceiling.
3. **Usable**: ~2 s to a parsed call, no RAM regression, grounded follow-up answers 10/10,
   no looping pathology.

No fallback needed (prompt-engineered JSON parsing and the FunctionGemma sidecar are both
unnecessary; the sidecar is architecturally impossible anyway, §1.5). **Proceed to /specify.**

### Carried into /specify and /plan (design consequences)

- **Leak suppression is mandatory**: every tool call leaks its raw SDK JSON through the text
  channel before the typed event. The seam must withhold/discard text deltas for a turn that
  resolves into a tool call (or filter the JSON shape) so the UI never flashes raw JSON.
- **Seam-side `StateError` gate** for tools-while-ungated (the silent no-op trap, §1.3),
  mirroring 002/003.
- **Tool-call + tool-result turns must persist in the app DB** and join the
  `clearHistory(replayHistory:)` replay — the plugin's own history omits streamed tool-call turns
  (§1.3), and the app replays from DB anyway.
- **System instruction as reliability lever**: ship a short tool-use system instruction with the
  registry; the spike's 83% is the no-instruction floor.
- **Tool results should be supersets** (trial 10): static structured maps beat narrow filtered
  responses.
- **One call per turn is the observed norm**; design the dispatcher for single-call turns but
  tolerate `ParallelFunctionCallResponse` defensively (execute sequentially or take the first +
  surface an error chip — a /specify decision).

### Incident log (for reproducibility)

- Run 1 hung before any trial: the A34's 10-minute screen timeout backgrounded the activity
  mid-run and the `flutter drive` VM connection never completed (`VMServiceFlutterDriver: It is
  taking an unusually long time to connect…`). Fix for device-stateful runs: raise
  `settings put system screen_off_timeout` (+ `svc power stayon true`) for the run and restore
  after. Run 2 completed cleanly (exit 0) with the model/DB intact — `flutter drive` again
  confirmed safe for device-stateful runs (`flutter test integration_test/...` remains forbidden;
  it uninstalls the app and wipes the model + DB).
