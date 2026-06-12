# Quickstart — 005 Memory device validation

On-device verification of the shipped feature. **`flutter run` / `flutter drive` ONLY — NEVER
`flutter test integration_test/...`** (it uninstalls the app and wipes the 2.4 GB model + DB). Raise
the screen timeout for long drives (`settings put system screen_off_timeout 1800000` + `svc power
stayon true`; restore after). Reference device: the A34 with the installed Gemma 4 E2B `.litertlm`.

Prereqs: model installed; a tool-capable model active (the default catalog model declares function
calling); memory ON (default).

## Functional walkthroughs

- **V1 — capture (US1)**: in a chat, send "I prefer dark mode", "I build Android apps with Flutter",
  "my name is Yossef". Expect a `REMEMBER_FACT` chip per durable fact; open settings → memory and
  confirm each fact is listed (short canonical text, sensible category). Send "what's 17×23?" → no
  chip, nothing saved.
- **V2 — injection grounds a NEW conversation (US2)**: start a NEW conversation (don't restate
  anything). Ask "what stack do I use?" / "what's my name?" → answers use the saved facts. Ask "what's
  my favorite color?" (never saved) → the assistant says it doesn't know (no fabrication).
- **V3 — facts apply next session, not mid-chat (FR-008)**: in conversation A, after the model
  answers, send a NEW fact ("I'm vegetarian"); confirm the chip, then ask within A "what do you know
  about my diet?" — acceptable either way (the user just said it), but start conversation B and
  confirm "vegetarian" is present in B. (The block snapshots at conversation open.)
- **V4 — dedupe / supersede (US4)**: send "my name is Yossef" then "actually call me Joe"; open
  settings and confirm ONE current name fact ("Joe"), not two contradictory rows. Send "I prefer dark
  mode" twice; confirm no duplicate row.
- **V5 — forget by asking (US5)**: with facts injected, ask "forget that I live in Cairo". Expect a
  `FORGET_FACT` chip and the Cairo fact gone from settings + future injections. Then ask to forget
  something not stored → honest reply / error chip, nothing deleted.
- **V6 — settings management (US3)**: open settings → memory. Edit a fact's text (persists; appears in
  the next conversation's answers). Delete one (gone). Clear-all behind the destructive confirm
  (list empties). Verify the listed set matches what V2 answers reflect (transparency, FR-015).
- **V7 — global toggle (US3/FR-014)**: turn memory OFF. Start a new conversation, ask "what's my
  name?" → the assistant does NOT know (no injection); share a fact → no capture chip. Turn memory ON
  → facts return (existing facts were retained, not deleted).
- **V8 — restart persistence (US6)**: kill + relaunch. Confirm all facts persist in settings, prior
  conversations' memory chips render in place, and a NEW conversation is still grounded in the facts.

## Reliability gate (the shipped 30-prompt suite — `flutter drive`)

- **V9 — capture/false-positive suite (SC-001/002/003)**: run the on-device suite (≥20 fact-sharing,
  ≥10 no-fact prompts) via `flutter drive` (the shipped reliability harness, modeled on the Phase 0
  spike). Record: capture rate ≥ 75% on fact prompts (spike floor 80% with the tuned instruction as
  the lever), **0** false positives on no-fact prompts, **0** wrong/hallucinated tools, ≥ 90% good arg
  quality (≤80-char fact + valid category). Tune the capture instruction (R5) here.

## Cross-cutting gates

- **V10 — capability-off regression (SC-010)**: with a non-tool-capable configuration (scratch build
  flipping `functionCalling` off), confirm NO capture is attempted, chat (text/image/audio) is
  unchanged, AND injected facts + the settings screen still work (injection isn't gated). Zero
  behavioral change to existing flows.
- **V11 — airplane mode (SC-012)**: enable airplane mode; capture, inject, forget, and manage all work
  end-to-end. Observe zero network requests (`check_network_seam.sh` stays green in CI).
- **V12 — token budget (SC-005)**: with ~20 facts saved, confirm the facts block stays within the cap
  and a long conversation still streams normally (facts reserved off the budget, not crowding history).
- **V13 — accessibility (SC-013)**: run Accessibility Scanner over the memory screen + memory chips —
  48dp touch targets, AA contrast; destructive actions (delete, clear-all) use the sanctioned red.
