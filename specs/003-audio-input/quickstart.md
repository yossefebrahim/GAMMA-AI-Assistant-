# Quickstart — validating 003 Audio Input

**Prerequisites**: Samsung A34 (or any arm64-v8a / 8 GB device) with the app installed and the
Gemma 4 E2B model downloaded; mic permission state reset where a step needs it
(`adb shell pm reset-permissions com.example.ai_assistant` or reinstall — **note**: reinstalling
via `flutter test integration_test/...` WIPES app data including the 2.4 GB model; see V0).

## V0 — Ground rules for device runs (spike incident log)

- Launch/verify with `flutter run` (or `flutter drive --driver=test_driver/integration_test.dart`
  for scripted runs). **NEVER use `flutter test integration_test/... -d <device>`** — it treats
  the app as a hermetic artifact and uninstalls it, destroying the downloaded model and the DB.
- If the model is ever lost, the restore recipe is in the spike findings incident log
  ([spike-findings.md](spike-findings.md) §4).

## V1 — Automated gates (no device)

```bash
flutter analyze                      # clean
flutter test                         # all unit/widget/data tests green, incl. v2→v3 migration
tool/check_plugin_seam.sh            # flutter_gemma / picker+permission / record+audioplayers confined
tool/check_network_seam.sh           # no new egress (audio adds zero network code)
```

## V2 — Record → send → grounded reply (US1 / SC-001)

`flutter run --release` on the device. In a new chat: tap the mic (grant permission), speak a
distinctive sentence (~5–10 s), tap stop. Verify: recording state showed elapsed time + red
pulsing indicator; chip appears with correct duration; chip playback plays the clip; send with
the text "transcribe this exactly". **Expected**: streamed reply transcribing/describing the
clip's actual content (the grounding bar: content-specific, not generic).

## V3 — Follow-up memory (US3 / SC-006)

After V2, send text-only: "which words came first in that audio?" **Expected**: answer reflects
the clip without re-attaching. Then stop a generation mid-stream and confirm the partial reply is
retained (FR-015) and the next send still works (session resync).

## V4 — Caps and edge recording states (FR-002/FR-021)

- Record past 30 s → auto-stops at the cap, clip kept, "limit reached" note.
- Tap mic then stop immediately (<0.5 s) → clip discarded, "too short" note.
- Start recording, background the app → recording stops; ≥0.5 s captured → chip + note.
- Start recording, trigger an incoming call (or `adb shell am start -a android.intent.action.CALL`
  on a second device / simulate audio-focus loss) → same stop-and-keep behavior.
- While a clip is pending, attach an image → clip replaced with the one-attachment note (Q3).

## V5 — Permission states (US4 / SC-007)

Reset permissions. Tap mic → system prompt appears (not at launch). Deny → tap again → explainer
with re-request. Deny with "don't ask again" → tap → explainer with **open settings** (no grant
button); follow it, grant, return → recording works. Throughout: text chat fully usable.

## V6 — Capability gating (US2 / SC-002)

`flutter test test/widget/composer_audio_gating_test.dart` covers the data-driven flip (mic
visible iff `capabilities.audio`, pending-clip clear **only** when a genuinely loaded
audio-incapable model is active — never during loading/error). On device: kill + relaunch mid-load
and confirm the mic button's absence during load does not produce the "model does not accept
audio" note.

## V7 — Persistence & upgrade-over-install (US5 / SC-005, FR-019)

- Send clips (audio-only and audio+text), force-quit, relaunch → chips in place with durations,
  order intact; continue the conversation.
- Install the **002 build**, create a conversation with an image, then install this build over it
  (`flutter install`, NOT a test runner) → old conversations open unchanged (v2→v3 migration on
  real data), image still renders, new audio features work in the same conversation.
- Delete an audio-bearing conversation → `adb shell run-as com.example.ai_assistant ls
  app_flutter/audio/` shows its files gone (no orphans from this path).

## V8 — Offline & privacy (SC-009)

Airplane mode on. Record → send → reply → 3 audio-referencing follow-ups. **Expected**: zero
failures. With a network monitor attached (e.g. `adb shell dumpsys netstats` deltas or mitmproxy
on a debug build), confirm zero requests during the entire flow (`check_network_seam.sh` is the
static half of this gate).

## V9 — Performance & memory (SC-003/SC-004/SC-010, research R7.4)

`--release` build, median of 5:

- recording state visible within 500 ms of mic tap; elapsed updates ≥1/s.
- max-length (30 s) clip: first reply words within 15 s of send.
- during recording AND while an audio reply streams: scroll/taps respond within 100 ms.
- memory: `adb shell dumpsys meminfo com.example.ai_assistant` at: idle-loaded, after a text
  turn, after a 30 s-clip audio turn. Expected envelope per the spike: audio adds on the order of
  +150–250 MB transiently over the text baseline; investigate anything beyond ~500 MB.

## V10 — Accessibility (SC-011)

Android Accessibility Scanner over: composer with mic, recording state, preview chip, permission
explainer. All touch targets ≥48dp, AA contrast (notes/errors in `textSecondary`, never
`textMuted`). TalkBack: recording start and stop are announced; chip exposes duration and
play/remove labels.

## Cleanup gate (before merge)

- Spike artifacts removed: `integration_test/spike_audio_grounding_test.dart` deleted,
  `integration_test` dev-dependency dropped (the `test_driver/` driver stays).
- `specs/003-audio-input/checklists/requirements.md` re-confirmed; constitution gates re-checked
  per [plan.md](plan.md).
