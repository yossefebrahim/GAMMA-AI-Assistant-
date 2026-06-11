# Fix Plan — `set_timer` integer-argument bug (004 function-calling)

**Date:** 2026-06-11
**Device:** Samsung SM-A346E (A34), Android 16, flutter_gemma 0.15.3, Gemma 4 E2B, GPU
**Tested by:** live on-device runs (typed into the composer) + the user's screenshot + unit suite
**Verdict:** The feature is **95% working**. Five of the six tool scenarios pass end-to-end.
**Exactly one tool is broken — `set_timer` — due to a single, well-isolated bug.** Everything
else (routing, gating, leak filtering, chips, persistence, hallucination handling) is solid.

---

## 1. Test results

| # | Scenario | Prompt | Result | How verified |
|---|----------|--------|--------|--------------|
| 1 | Device info | "what's my battery level?" | ✅ **PASS** — `get_device_info` chip (battery section), "Your battery level is 47%." | user screenshot |
| 2 | **Timer** | "set a 5 minute timer" | ❌ **FAIL** — `set_timer` rejected: *"argument seconds must be an integer"*, then a retry blocked by *"only one tool call per turn"* | user screenshot |
| 3 | Theme | "switch to light mode" → "switch back to dark" | ✅ **PASS** — both directions; `set_theme` chip + app theme actually flips | live on-device |
| 4 | Clipboard | copy text, then "summarize my clipboard" | ✅ **PASS** — `summarize_clipboard` chip (success, `truncated false`), model answers grounded in the copied text | live on-device |
| 5 | Plain question | "what's the capital of France?" | ✅ **PASS** — "The capital of France is Paris." No tool, no chip, no JSON leak | live on-device |
| 6 | Hallucinated probe | "check the weather" | ✅ **PASS** — "I do not have access to real-time weather information…" Graceful text decline, **no fake tool chip** | live on-device |

> Note (non-blocking, scenario 4): the model *restated* the clipboard sentence rather than tightly
> compressing it. The input was a single sentence, so there was nothing to shorten — the tool path
> itself works end-to-end. This is model phrasing, not a bug.

---

## 2. Root cause (scenario 2)

The model correctly decides to call `set_timer` and correctly computes the duration. It emits the
argument as a JSON **number**, which arrives at the Dart layer as a **`double`** — visible on the
chip as `SECONDS: 300.0` (not `300`). That double then hits two integer-only gates back-to-back:

### Gate A — the strict validator rejects it

`lib/core/tools/schema_validator.dart:104-109`

```dart
case 'integer':
  // Dart/JSON: an integer arrives as `int`; reject doubles even with a zero fraction ...
  if (value is! int) {
    return ValidationResult.invalid('argument $name must be an integer');
  }
```

`300.0 is! int` → `true` → **`ToolInvalidArgs("argument seconds must be an integer")`**. This is the
first red chip in the screenshot. The validator is *intentionally* strict here, but the rule is too
strict: `300.0` is a whole number and is a legitimate integer value in JSON (JSON has no separate
integer type). It correctly rejects genuinely fractional values like `1.5`, but it also throws away
valid whole-valued durations.

### Gate B — even if A passed, the handler cast would throw

`lib/features/chat/tool_handler_providers.dart:54`

```dart
final seconds = args['seconds'] as int;   // 300.0 is a double → throws _TypeError
```

So relaxing the validator alone is **not enough** — the value must actually be *coerced* to a real
`int` before it reaches the handler, or this cast becomes the next failure (caught and surfaced as
`ToolFailure`). The fix has to produce a true `int`, not just accept the double.

### Why the second red chip appears ("only one tool call per turn")

This is **not a separate bug** — it is the spec's one-round-trip rule (FR-006/FR-024) working as
designed, triggered by Gate A:

1. `set_timer(seconds: 300.0)` → Gate A rejects → error chip.
2. The error is fed back to the model on resume.
3. The model apologizes ("I will try again") and emits a **second** `set_timer` call.
4. `chat_controller.dart:310-322` blocks the second call — only one tool round trip per turn — and
   renders it as an error chip: *"only one tool call per turn."*

**Fixing Gate A/B removes the trigger entirely**: the first call succeeds, there is no failure to
apologize for, and no retry to block. One fix clears both red chips.

### Why our tests didn't catch it

All 25 tool unit tests pass. The validator test only checks `seconds: 1.5` (a *fractional* double,
correctly rejected) and `seconds: 300` / `0` / `90000` (real `int`s). **No test feeds a
whole-valued double like `300.0`** — which is exactly what the live model produces. The fakes in
`tool_failure_matrix_test.dart` also script `int` args (`{'seconds': 0}`), so the seam→double
reality was never exercised off-device.

---

## 3. The fix

**Primary fix (required): schema-aware integer coercion in the dispatcher.**
`lib/domain/services/tool_dispatcher.dart` is the single, schema-aware chokepoint the contract
already assigns to argument handling ("the dispatcher validates args against the schemas"). Coerce
**before** validating, so the validator stays strict and the handler receives a true `int`.

```dart
Future<ToolOutcome> dispatch(String name, Map<String, Object?> args) async {
  final spec = ToolRegistry.byName(name);
  if (spec == null) return ToolUnknown(name);

  // Coerce whole-valued doubles → int for integer-typed properties. The model/SDK emits JSON
  // numbers that arrive as Dart `double` (e.g. 300.0); JSON has no separate integer type. A value
  // with a fractional part (1.5) is left as-is so the strict validator still rejects it.
  final coerced = _coerceIntegerArgs(spec.parameters, args);

  final validation = validator.validate(spec.parameters, coerced);
  if (validation is InvalidT) return ToolInvalidArgs(validation.reason);

  final handler = _handlers[name];
  if (handler == null) return const ToolFailure('tool not available');

  try {
    final result = await handler(coerced);          // handler now gets a true int
    final (bounded, truncated) = _applyBound(result, spec.resultCharBound);
    return ToolSuccess(bounded, truncated: truncated);
  } catch (error) {
    return ToolFailure(_reasonOf(error));
  }
}

Map<String, Object?> _coerceIntegerArgs(
    Map<String, Object?> schema, Map<String, Object?> args) {
  final properties =
      (schema['properties'] as Map?)?.cast<String, Object?>() ?? const <String, Object?>{};
  final out = Map<String, Object?>.of(args);
  for (final entry in args.entries) {
    final propSchema = (properties[entry.key] as Map?)?.cast<String, Object?>();
    if (propSchema?['type'] != 'integer') continue;
    final v = entry.value;
    if (v is double && v.isFinite && v == v.roundToDouble()) {
      out[entry.key] = v.toInt();            // 300.0 -> 300 ; 1.5 left as double -> still rejected
    }
  }
  return out;
}
```

Net effect: `300.0` → `300` (int) → passes validation (≥1, ≤86400) → handler fires the timer.
`1.5` stays a double → still rejected with *"argument seconds must be an integer."* No change to
the validator, the registry, or the seam.

**Optional polish (P2, cosmetic): the chip shows `SECONDS: 300.0`.**
The chip's `toolArgs` is persisted from the raw `call.args` (`chat_controller.dart:267`), so it will
still display `300.0` even after the timer works. To make it read `300`, persist the coerced args on
the chip. Cleanest option: have the dispatcher coerce, and pass the *same* coerced map to
`appendToolInvocation`. Two reasonable approaches:

- **A (preferred):** lift the `_coerceIntegerArgs` call into `_runToolTurn` (it can read the schema
  via `ToolRegistry.byName(call.name)?.parameters`), compute `normalizedArgs` once, and use it for
  **both** `appendToolInvocation(args: normalizedArgs)` *and* `dispatch(call.name, normalizedArgs)`.
  One coercion, fixes display + validation + handler together.
- **B:** leave coercion in the dispatcher and accept `300.0` on the chip as cosmetic-only.

This is non-blocking — the timer works either way. Decide A vs B when implementing.

---

## 4. Tests to add (TDD — write these first, watch them fail, then fix)

1. **`test/unit/core/schema_validator_test.dart`** — *if* we also relax the validator (defense in
   depth): add `seconds: 300.0` → valid. (Not required if we only coerce in the dispatcher; in that
   case the validator never sees the double. Keep the existing `1.5` → invalid case either way.)
2. **`test/unit/domain/tool_dispatcher_test.dart`** — the load-bearing cases:
   - `dispatch('set_timer', {'seconds': 300.0})` → `ToolSuccess`; assert the handler received
     **`300` as `int`** (capture the arg in a fake handler and assert `received is int`).
   - `dispatch('set_timer', {'seconds': 1.5})` → `ToolInvalidArgs` (fractional still rejected).
   - `dispatch('set_timer', {'seconds': 0.0})` → `ToolInvalidArgs` (coerced to 0, fails `minimum`).
   - `dispatch('set_timer', {'seconds': 86400.0})` → `ToolSuccess` (upper bound, coerced).
3. **`test/unit/features/tool_failure_matrix_test.dart`** — add a happy-path
   `ToolCallRequested('set_timer', {'seconds': 300.0})` → success chip + grounded resume, mirroring
   the real seam output instead of pre-coerced `int`s.

---

## 5. Verification on device (after the fix)

Per `CLAUDE.md` / memory: **never** `flutter test integration_test/...` (it wipes the model + DB).
Use a normal run:

```bash
flutter run -d 192.168.9.2:46327      # or: flutter drive ... (raise the screen timeout for long drives)
```

Then in the chat, retype the timer probes and confirm:

- "set a 5 minute timer" → **green** `set_timer` chip reading `SECONDS: 300` (or `300.0` if we skip
  the P2 polish), a system timer actually starts, and the reply confirms it. **No** "only one tool
  call per turn" chip.
- "set a timer for 90 seconds" / "set a 2 hour timer" → succeed (bounds 1…86400s).
- "set a timer for 30 hours" → honest decline / clamp (exceeds the 24h max — model-side).
- Re-run scenarios 1, 3, 4, 5, 6 once to confirm no regression.

---

## 6. Scope / non-issues

- **In scope:** the integer-coercion fix (§3) + tests (§4). ~15 lines of production code.
- **Not bugs (leave alone):** the one-round-trip rule (§2 "second red chip"), the strict
  unknown-key rejection, the LeakFilter, the hallucination decline path — all verified working.
- **Out of scope:** clipboard summarization quality (model phrasing); any new tools.
- **Risk:** very low. The change is additive, schema-gated to `integer` properties (only
  `set_timer.seconds` today), and fully covered by the new unit tests. The strict-validation
  guarantee for fractional values is preserved.
