# Quickstart — 004 Function Calling: build, run, validate

## Prerequisites

- Samsung A34 (or any arm64-v8a / 8 GB device) with the app installed and the Gemma 4 E2B model
  already downloaded (the 2.4 GB `.litertlm` survives upgrades — `adb install -r` / `flutter run`
  only).
- Device reachable: `adb devices` → use `-d 192.168.9.2:45295` if the A34 enumerates twice.
- **NEVER `flutter test integration_test/...` on a device** — it uninstalls the app and wipes the
  model + DB. Device runs are `flutter run` / `flutter drive` only. For long unattended runs,
  raise the screen timeout first (the 004 spike's run-1 hang):
  `adb shell settings put system screen_off_timeout 2400000` (restore to `600000` after).

## Static gates (host, no device)

```bash
flutter analyze                     # zero issues
flutter test                        # full plugin-free suite green
tool/check_plugin_seam.sh           # now also guards battery_plus / android_intent_plus
tool/check_network_seam.sh          # tools add ZERO egress (Principle I)
```

## Launch

```bash
flutter run -d 192.168.9.2:45295 --release   # SC timing measurements are --release only
```

## Validation script (V1–V11)

**V1 — Core loop (US1, SC-001/003/005).** Ask, in separate turns: "what's my battery level?",
"what device am i running on?", "how much free storage is left?". ✅ Expected: each turn renders
a `TOOL · GET_DEVICE_INFO` chip (running → success) followed by a streamed reply whose figures
match reality (cross-check battery in system settings); full round trip < 20 s; **no raw JSON
ever visible** (watch the streaming bubble closely during the call — SC-003).

**V2 — No-call prompts (SC-002).** "write a haiku about rain", "what is 17 times 23?".
✅ Expected: plain prose, zero chips, behavior identical to 003.

**V3 — set_theme (US2, SC-009).** "switch to light theme". ✅ Expected: theme flips immediately
(no confirmation — spec Q1), chip records success, reply acknowledges. Ask again for light theme
→ idempotent success ("already light"). Kill the app, relaunch → still light. Switch back via
settings screen → no conflict.

**V4 — set_timer (US4).** "set a timer for 5 minutes". ✅ Expected: NO app switch (skip-UI
hand-off, spec Q2); chip records `5:00` + success; reply confirms; the system clock app shows the
running timer (verify in notification shade). Then the word-phrased duration (US4/AS2 — the
story's core claim): "set a timer for a quarter of an hour" → chip records `15:00`, clock app
holds a 15-minute timer (optionally also "90 seconds" → `1:30`). Then "set a timer for zero
seconds" → error chip (out of bounds), honest reply, no timer.

**V5 — summarize_clipboard (US5).** Copy a long paragraph in another app, return, "summarize my
clipboard". ✅ Expected: chip success; summary clearly derived from the copied text; the OS
clipboard-read toast may appear (expected). Clear the clipboard (copy a single space or reboot),
ask again → error chip ("clipboard empty or not text"), honest reply, no fabricated summary.

**V6 — Persistence + replay fidelity (US6, SC-006).** After V1–V5, kill the app, relaunch, reopen
the conversation. ✅ Expected: every chip renders in place with terminal states (never
"running"). Then ask "what was my battery level when you checked earlier?" ✅ Expected: the
answer cites the earlier tool result from context WITHOUT a new chip (replay fidelity — this is
the one seam input unit tests can't fully verify; if the model acts confused about prior tool
turns, the raw-JSON replay reconstruction needs adjustment).

**V7 — Failure honesty (US7, SC-004).** Probes: "set an alarm for 7am" (no such tool — expect
prose decline or an unknown-tool error chip, never a crash), "switch the backend to cpu"
(excluded tool — expect prose, no chip). With a debug hook or `FakeGemmaService` device build if
needed: force an invalid-args call → error chip + text reply. Tap stop mid-tool-turn → turn ends
consistently; chip terminal (skipped or its real outcome); reopening shows no stuck state.

**V8 — Offline (SC-008, Principle II).** Airplane mode ON. Repeat one V1 prompt, V3, V4, V5.
✅ Expected: all four tools work identically; zero network errors. (Clipboard + timer + theme +
device info are all local.)

**V9 — Responsiveness (Principle IV).** During a tool turn (call → chip → resume), scroll the
conversation and type in the composer. ✅ Expected: no frozen frames beyond the known ~1 s
prefill windows; stop responds immediately.

**V10 — Accessibility + identity gate (Principle VI/X, SC-010).** Accessibility Scanner over a
conversation with all four chip states (success, error, skipped, running-if-catchable): AA
contrast on chip text (`textSecondary` floor), no sub-48dp interactive targets (the v1 chip is
non-interactive — verify it exposes no tap affordance), TalkBack reads the chips' semantic
labels. Visual: chips are monochrome, mono uppercase tags, hairline borders; red appears ONLY on
the error state.

**V11 — Capability-off regression (SC-007).** Flip `ModelCatalog.supportsFunctionCalling` to
`false` in a scratch build. Repeat V1 prompts PLUS one image turn and one audio turn (the
existing 002/003 flows). ✅ Expected: prose answers, zero chips, zero tool declarations (verify
via plugin debug logs if needed); image/audio behavior unchanged; V2 behavior byte-identical.
SC-007's suite-level "zero tool calls" claim is satisfied by zero declarations — with no tools
declared, the model cannot call (spike §1.2); the full 20-prompt suite need not be re-run
flag-off. Old conversations' chips still render (FR-010). Restore the flag.

## Reliability gate (SC-001/SC-002 formal measurement)

Re-run the spike's 20-prompt suite against the SHIPPED pipeline (registry + dispatcher + system
instruction — not the spike harness) via `flutter drive` with the throwaway driver pattern from
the spike, or manually score the 20 prompts from quickstart prompts above. PASS: ≥ 80%
correct-call on the 12 should-call prompts, 0 hallucinated tools, 0 spurious calls, 0 crashes.
Record the run in the feature's audit notes before merge.
