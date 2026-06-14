# offline / airplane-mode degradation — A34 device procedure (006)

the device half of the offline guarantee. the human runs this on the A34; it is not automated and is
not run by the SpecKit agent. supports **T062**, quickstart **V-series Step 2** (+ the **V11**/**V13**
gates that touch the same chips), and proves **SC-004** on real hardware.

## what this proves

- **SC-004** — with airplane mode enabled, **100%** of web tool call attempts produce a **red error
  chip** with an "offline" reason, **zero network calls** are observed, and the app **does not crash**.
- **FR-020** — connectivity absent ⇒ the web tool returns `OfflineError` **immediately, no retry**; the
  model is prompted to answer from its own knowledge; no crash, no hang, no retry loop.
- **FR-021** — with web access **off**, behavior is byte-identical to pre-006: no chip, no network, no
  new ui. (the parity mini-section below; airplane mode not required.)

host-side proofs already exist and stay green — this device pass is the on-hardware confirmation, not
the primary proof:

- offline-degradation mapping: `test/unit/tool_dispatcher_web_search_test.dart`
  (`OfflineError → "offline — no connection"`, and the structural guard fires before any network call).
- web-off byte-parity: `test/unit/web_gating_regression_test.dart`
  (case "(e) web off (no key) → behavior identical to pre-006, zero network (FR-021)").

## prereqs

- gemma 4 E2B `.litertlm` installed on the A34 (do not reinstall — that re-prompts for
  `MANAGE_EXTERNAL_STORAGE`).
- a **valid** tavily key saved in settings → web research (masked after save).
- global web toggle **on**; no per-conversation override (composer toggle in `inherit-global`).
- device id: the A34 can appear **twice** in `adb devices` — always pass `-d` explicitly, e.g.
  `192.168.9.2:45295`.
- for a long manual session, raise the screen timeout first:

```
adb shell settings put system screen_off_timeout 1800000
adb shell svc power stayon true
# restore after the run:
adb shell settings put system screen_off_timeout 60000
adb shell svc power stayon false
```

## entering / exiting airplane mode

adb (preferred — scriptable, no ui ambiguity):

```
adb -s 192.168.9.2:45295 shell cmd connectivity airplane-mode enable
adb -s 192.168.9.2:45295 shell cmd connectivity airplane-mode disable
```

manual alternative: swipe down from the top of the screen → tap the airplane icon to toggle. confirm
the status-bar airplane glyph is shown (radios off) before sending prompts.

## procedure — airplane mode (SC-004 / FR-020)

run the app interactively (no device wipe — never `flutter test integration_test/...`):

```
flutter run -d 192.168.9.2:45295
```

1. confirm global web toggle **on** and a valid key is stored (settings → web research; key shows
   masked).
2. enable airplane mode (adb command above, or swipe-down). confirm the airplane glyph in the status
   bar.
3. start a **new** conversation.
4. send these three research-worthy prompts, one at a time, waiting for each turn to finish:
   - `what's the current dart release?`
   - `what's the latest flutter stable release?`
   - `what changed in the android 15 developer preview?`
5. for **each** prompt, watch the chip + stream and confirm all of:
   - a `WEB_SEARCH · Tavily` chip appears (optimistic running state), then transitions to a **red error
     state** — not success, not stuck running.
   - the chip's reason is plain-language offline, e.g. `offline — no connection` (the exact string the
     dispatcher maps `OfflineError` to). it is **not** raw error text or a stack trace.
   - **no crash, no indefinite spinner, no retry storm** — the chip fails once and stays failed; it does
     not re-fire on its own.
   - the model still produces a **text reply** (prompted to answer from its own knowledge).
   - **no raw `{"function_call":...}` json** appears anywhere in the rendered text stream
     (leak-filter holds — shared with the V10 gate).
6. disable airplane mode (adb command above, or swipe-down). wait for the radios to reconnect (wait for
   wi-fi/mobile data to show connected in the status bar).
7. send one more research-worthy prompt, e.g. `what is flutter?`. confirm the `WEB_SEARCH · Tavily` chip
   now transitions to **success**, source url chips appear beneath the answer, and the answer is
   grounded — i.e. the feature resumes normally with no app restart.

## web-off parity check (FR-021) — no airplane mode

this is a **visual confirmation only**; the authoritative proof is host-side
(`test/unit/web_gating_regression_test.dart` case (e) + the gate cases in that file). radios stay on.

1. settings → web research → turn the global web toggle **off**. leave the key stored, no
   per-conversation override.
2. start a **new** conversation.
3. send `what's the latest flutter release?`.
4. confirm: **no** `WEB_SEARCH` chip appears, the model answers from its own knowledge (or says it can't
   browse), and the screen looks identical to pre-006 chat (no new ui element). per spec this path makes
   **zero network calls** — confirmed in code, not re-measured here.
5. restore the global web toggle **on** afterwards so the device is left in the V1 happy-path state.

## pass criteria

airplane mode (repeat the chip checks for **all three** prompts in step 4 — all must pass):

- [ ] toggle on + valid key stored, airplane mode enabled → setup confirmed (status-bar airplane glyph)
- [ ] each of 3 prompts → a `WEB_SEARCH · Tavily` chip appears then turns **red** (error state)
- [ ] each red chip's reason is plain-language offline (e.g. `offline — no connection`), no stack trace
- [ ] no crash, no app freeze, no stuck spinner across all 3 prompts
- [ ] no retry storm — each chip fails once and stays failed (no self re-fire)
- [ ] each prompt still yields a model **text reply** (answered from own knowledge)
- [ ] no raw `{"function_call":...}` json in any rendered stream
- [ ] airplane mode disabled + radios reconnected → next prompt's chip turns **success** with grounded
      answer + tappable source url chips (feature resumes, no restart)

web-off parity:

- [ ] global toggle off → research prompt produces **no** chip and pre-006-identical ui
- [ ] global toggle restored to on at the end (device left in V1 state)

## what to record

- pass/fail per checklist box; for any fail, note the prompt text, the chip's final state, and the exact
  reason string shown.
- the gemma 4 E2B model id / catalog entry active during the run and the app build (commit sha).
- for any crash: capture `adb -s 192.168.9.2:45295 logcat` around the failure and attach it.
- do **not** invent latency numbers — airplane-mode failures are expected to be near-instant (no retry),
  but record only "immediate / observable delay / hung" qualitatively, not a fabricated ms figure.
