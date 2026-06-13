# 006-web-research — Phase 0 Device Spike Harness

**Status**: spike artifact — NOT shipped into the app.

This directory contains the throwaway integration harness for the Phase 0 device
spike of the `006-web-research` feature.  It measures three things that can only
be determined by running the real Gemma 4 E2B model on the A34 device:

| Measurement | What it answers |
|---|---|
| **(A) Multi-step tool-chain reliability** | Does E2B reliably call `web_search` for search-worthy prompts?  Does it chain to `fetch_page`?  Does it stall or loop? |
| **(B) On-device summarization latency** | How long does E2B take to summarize ~500 / ~1 kB / ~2 kB of extracted page text?  This feeds the snippets-only vs fetch+summarize budget decision. |
| **(C) End-to-end latency** | Total wall-clock time: query → search call → fetch call → grounded answer (stub network — model-only). |

All tool calls are answered with **FAKE/STUB canned data** (defined at the top of
the harness file) so the harness measures model inference behavior, not live
network latency.

---

## CRITICAL: never use `flutter test` for device-stateful runs

```
NEVER:  flutter test integration_test/spike_web_research_test.dart
```

`flutter test integration_test/...` **uninstalls the app** and wipes the
2.4 GB model file and the drift database from the device.  After that you need
to re-download the model from scratch (20-30 minutes on typical mobile data).

Always use `flutter drive` as shown below.

---

## Before you run

### 1. Raise the screen timeout

The full suite takes ~45 minutes on the A34 (GPU backend).  Without a raised
timeout the screen will lock mid-run and the `flutter drive` VM connection will
hang (the 004 spike documented this exact failure in its incident log).

```bash
adb shell settings put system screen_off_timeout 1800000   # 30 min
adb shell svc power stayon true
```

Restore after the run:

```bash
adb shell settings put system screen_off_timeout 30000     # 30 s
adb shell svc power stayon false
```

### 2. Verify the model is on device

The harness expects the model at the same path the app uses:

```
getApplicationDocumentsDirectory()/models/gemma-4-e2b.litertlm
```

Run the app at least once and let it complete the one-time model download before
running the spike.  If you have the model file on your machine you can push it
directly:

```bash
# Find the app documents path first:
adb shell run-as ai.assistant.app sh -c 'echo $EXTERNAL_STORAGE'
# Then push to the app-private documents dir (typical path):
adb push gemma-4-e2b.litertlm \
  /data/user/0/ai.assistant.app/app_flutter/models/gemma-4-e2b.litertlm
```

### 3. Find your device ID

```bash
adb devices
flutter devices
```

The A34 typically appears twice (`192.168.x.x:port` for Wi-Fi ADB and
`RF8X...` for USB).  Pass `-d <device-id>` explicitly to target the right one.

---

## Run commands

### Step 1: Copy the harness into the integration test directory

The harness lives in `specs/006-web-research/spike-harness/` and is NOT wired
into the app's `integration_test/` directory.  Copy it before running:

```bash
cp specs/006-web-research/spike-harness/spike_web_research_test.dart \
   integration_test/spike_web_research_test.dart
```

### Step 2: Run via flutter drive

```bash
flutter drive \
  --driver=test_driver/integration_test.dart \
  --target=integration_test/spike_web_research_test.dart \
  -d <device-id>
```

Replace `<device-id>` with the output from `adb devices` / `flutter devices`.

To capture the full output for post-processing:

```bash
flutter drive \
  --driver=test_driver/integration_test.dart \
  --target=integration_test/spike_web_research_test.dart \
  -d <device-id> \
  2>&1 | tee flutter_drive_web_spike.txt
```

### Step 3: Extract results

Every measurement emits a `@@WEB@@`-prefixed JSON line.  Extract and
pretty-print them:

```bash
grep '@@WEB@@' flutter_drive_web_spike.txt \
  | sed 's/.*@@WEB@@ //' \
  | python3 -c "import sys,json; [print(json.dumps(json.loads(l),indent=2)) for l in sys.stdin]"
```

Or filter to just the summary lines:

```bash
grep '@@WEB@@' flutter_drive_web_spike.txt \
  | grep '"stage": "AC-summary\|B-summary-result\|B-done'
```

### Step 4: Remove the harness file

```bash
rm integration_test/spike_web_research_test.dart
```

---

## Expected runtime (A34, GPU backend)

| Section | Approximate time |
|---|---|
| Model load | ~7–10 s |
| (B) Summarization latency (3 probes) | ~5–10 min |
| Second model load (for A+C) | ~7–10 s |
| (A)+(C) Tool-chain suite (25 trials, up to 3 rounds each) | ~35–45 min |
| **Total** | **~45–55 min** |

The suite runs (B) first (text-only, shorter), then (A)+(C) (tool-calling, longer).

---

## Result tables

Fill these from the real run output.  Leave them empty until then.

### (B) Summarization latency

| Text length | Prompt chars | Output chars | First-token ms | Total ms | Notes |
|---|---|---|---|---|---|
| short (~125 tok) | | | | | |
| medium (~250 tok) | | | | | |
| long (~500 tok, full page) | | | | | |

**Budget decision input**: if `long (~500 tok)` total ms > 20 s, the
fetch+summarize path will feel too slow for an interactive assistant and
snippets-only becomes the default.  Fill in the real number.

### (A) Tool-chain reliability (20 search-worthy prompts)

| Metric | Count | Rate | Notes |
|---|---|---|---|
| Emitted 1st tool call (web_search) | / 20 | % | |
| Chained to 2nd call (fetch_page) | / (calls that searched) | % | |
| Stalled (no final answer) | / 20 | % | |
| Looped (>2 tool calls) | / 20 | % | |
| Final answer present | / 20 | % | |
| Grounded answer (sentinel in reply) | / (chains to fetch) | % | |
| False positives on junk prompts | / 5 | % | target: 0 |
| Raw-JSON leak in text stream | / calls | % | secondary signal |

### (C) End-to-end latency (search → fetch → answer)

| Metric | Value | Notes |
|---|---|---|
| Median e2e ms (full chain, text answer present) | | |
| P90 e2e ms | | |
| Step 1 typical (search call emitted) | | |
| Step 2 typical (fetch call emitted) | | |
| Step 3 typical (final text answer) | | |

### Memory / hardware

| Metric | Value |
|---|---|
| Backend | GPU / CPU |
| Model load time | s |
| Peak RSS (MB) | |
| A34 Android version | |

---

## Decision gate (to be filled after the run)

The spike gate is deliberately loose — this is exploratory measurement, not a
shipped reliability test.  The numbers feed the `/specify` and `/plan` decisions
for 006.

| Question | Threshold | Result | Decision |
|---|---|---|---|
| Does E2B call `web_search` at all? | ≥ 1 call across 20 prompts | | PASS / FAIL |
| 1st-call rate | ≥ 60% | | proceed / explicit-only fallback |
| Chain rate (search → fetch) | ≥ 40% of 1st calls | | automatic chaining / prompt only |
| Loop rate | ≤ 10% | | safe / add loop-break guard |
| Long-text summarization latency | ≤ 20 s total | | fetch+summarize viable / snippets-only default |
| False positives on junk | 0 | | clean / instruction tuning needed |

---

## Files in this directory

| File | Purpose |
|---|---|
| `spike_web_research_test.dart` | The Dart harness (copy to `integration_test/` to run) |
| `README.md` | This file: run instructions + result tables |

The canned fixture HTML files live in `../fixtures/` (raw pages captured for
reference; not used by this harness — the harness uses inline stub text).
