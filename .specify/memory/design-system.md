# Design System — On-Device Gemma Assistant

> Visual language **inspired by Nothing** (nothing.tech): monochrome, minimal, dot-matrix, restraint, a single red accent.
> Dark-first. Material 3 under the hood. This file is the source of truth — every `/speckit.plan` must follow it.

---

## 1. Design philosophy

Five rules that define the look. Every screen obeys them.

1. **Monochrome by default.** The interface is black, white, and gray. Color is not used for decoration.
2. **One accent, used rarely.** A single Nothing-red is reserved for *active, live, and destructive* states only — generation in progress, recording, the stop control, critical errors. If red appears everywhere, the system is broken.
3. **Dot-matrix is the signature.** A dot-matrix (Glyph-style) display face carries branding and numerals; pulsing dot motifs replace conventional spinners.
4. **Flat, not layered with shadows.** No gradients, no drop shadows. Separation comes from hairline borders and subtle surface steps.
5. **Understated, technical voice.** Microcopy is lowercase. Metadata reads like a spec sheet — uppercase monospace with letter-spacing (`GPU · 2.4GB · ARM64`). Product/model names use parentheses, e.g. `model ( gemma 4 e2b )`.

> **IP note:** This is an *inspired-by* language, not a clone. Do not ship Nothing's logo or proprietary assets. The dot-matrix face must be an openly-licensed font you source/bundle yourself (see §3) — the *design language* itself is not protectable, the brand marks are.

---

## 2. Color tokens

Dark is the default theme. Light is an optional inverse.

### 2.1 Dark theme (default)

| Token | Hex | Use |
|---|---|---|
| `bg` | `#000000` | App canvas (true black, OLED) |
| `surface` | `#0D0D0D` | Sheets, dialogs, primary cards |
| `surfaceContainer` | `#161616` | Raised cards, chat input bar |
| `surfaceContainerHigh` | `#222222` | User message bubble, chips, fields |
| `outline` | `#2E2E2E` | Hairline borders, the main separator |
| `outlineVariant` | `#1C1C1C` | Faint dividers |
| `textPrimary` | `#FFFFFF` | Body and headings |
| `textSecondary` | `#A0A0A0` | Captions, secondary labels |
| `textMuted` | `#5C5C5C` | Disabled, placeholders, timestamps |
| `accent` (red) | `#D71921` | **Active / recording / stop / error only** |
| `onAccent` | `#FFFFFF` | Text/icon on red |

### 2.2 Light theme (optional inverse)

| Token | Hex |
|---|---|
| `bg` | `#FFFFFF` |
| `surface` | `#FAFAFA` |
| `surfaceContainer` | `#F0F0F0` |
| `surfaceContainerHigh` | `#E6E6E6` |
| `outline` | `#D6D6D6` |
| `outlineVariant` | `#ECECEC` |
| `textPrimary` | `#000000` |
| `textSecondary` | `#5C5C5C` |
| `textMuted` | `#9A9A9A` |
| `accent` (red) | `#D71921` |

**Accent discipline (non-negotiable):** red is allowed only on — the generating pulse, the audio record indicator, the stop-generation button, destructive confirmations, and critical errors. Everything else (send, primary buttons, links, selected states) is monochrome (white-on-black / black-on-white).

---

## 3. Typography

Three roles, three faces.

| Role | Face | Where |
|---|---|---|
| **Display** | Dot-matrix (Ndot-style) | App name, big numerals (download %, timer countdowns), empty-state branding, "Glyph" moments |
| **UI / Body** | **Space Grotesk** | Screen titles, model names, chat message text, buttons, descriptions |
| **Mono / Spec** | **Space Mono** (or JetBrains Mono) | Status readouts, metadata, tags, technical labels — uppercase, letter-spaced |

**Font sourcing:**
- Space Grotesk + Space Mono → Google Fonts (use `google_fonts`, or bundle for offline since the app is offline-first — **bundle them**, don't fetch at runtime).
- Dot-matrix face → not on Google Fonts. Source an openly-licensed dot-matrix/LED font (e.g. a `5x7`-style dot font) and bundle as an asset. Use it sparingly — display and numerals only, never body.

**Type scale (dp):**

| Style | Size / Line | Weight | Face | Letter-spacing |
|---|---|---|---|---|
| Display L | 40 / 44 | — | Dot-matrix | normal |
| Display S | 28 / 32 | — | Dot-matrix | normal |
| Title L | 22 / 28 | 600 | Space Grotesk | -0.2 |
| Title M | 17 / 24 | 600 | Space Grotesk | -0.2 |
| Body L | 16 / 24 | 400 | Space Grotesk | 0 |
| Body M | 14 / 20 | 400 | Space Grotesk | 0 |
| Label / Spec | 11 / 16 | 500 | Space Mono | **+1.5, UPPERCASE** |

---

## 4. Spacing, layout, shape

- **Spacing scale (4dp base):** `4 · 8 · 12 · 16 · 24 · 32 · 48`. Everything aligns to this grid.
- **Screen padding:** 16dp horizontal default; 24dp for hero/empty states.
- **Corner radius:** cards/sheets `12`, inputs/chips/buttons `8`, dot/FAB-style actions full-round. Industrial, modest — never soft/blobby.
- **Borders:** 1dp hairline in `outline` for any separation. This is the primary way elements are distinguished.

---

## 5. Elevation

There is **no shadow-based elevation.** Depth is expressed by:
1. stepping the surface token (`surface` → `surfaceContainer` → `surfaceContainerHigh`), and
2. a 1dp `outline` hairline.

Disable Material's default shadow/tint overlays (`elevation: 0`, kill surface-tint).

---

## 6. Iconography

- Monochrome, **outline** style, regular weight, geometric.
- Default `textPrimary`; inactive `textMuted`.
- Reserve filled/red icons for active states only.
- Where a brand moment calls for it, dot-matrix-styled glyphs are encouraged.

---

## 7. Motion

- **Precise and quick:** 150–250ms, mechanical easing (standard/decelerate). No bouncy springs — Nothing is restrained.
- **Signature loaders are dot-based**, not circular spinners:
  - **Generating:** a row of dot-matrix dots pulsing in sequence (Glyph rhythm).
  - **Recording:** a single pulsing red dot.
  - **Download:** a thin determinate bar (`accent` or white fill on `outline` track) with a dot-matrix `%` numeral beside it.

---

## 8. Component treatments (mapped to this app)

| Surface | Treatment |
|---|---|
| **App shell** | `bg` true black. Top bar borderless except a 1dp `outline` bottom hairline. A mono spec line shows active model + backend: `GEMMA 4 E2B · GPU · ON-DEVICE`. |
| **Assistant bubble** | Left-aligned, **transparent / borderless** (or 1dp `outline`). Body L in Space Grotesk, `textPrimary`. No colored fill. |
| **User bubble** | Right-aligned, filled `surfaceContainerHigh`, radius 12 (tighter on the trailing corner). Differentiation is by **alignment + subtle fill, never color**. |
| **Streaming cursor** | A blinking block/dot at the tail of the streaming text, or the dot-matrix pulse below the bubble while tokens arrive. |
| **Stop-generation** | The one prominent red affordance: `accent` fill, `onAccent` square-stop glyph. Visible only while generating. |
| **Composer / input bar** | `surfaceContainer`, 1dp `outline`, radius 12. Monochrome send icon (white). Attachment + mic icons monochrome; **mic turns red only while recording.** |
| **Audio recording** | Pulsing red dot + a monochrome waveform (waveform bars in `textSecondary`, peak in `accent`). Mono duration readout in dot-matrix numerals. |
| **Thinking panel** | Collapsible, 1dp `outline`, mono `REASONING` label, content in `textSecondary` (dimmed vs. the answer). Collapsed by default. |
| **Function-call chip** | Mono uppercase tag, monochrome: `TOOL · SET_THEME`. Result shown as a quiet system line, not a colored banner. |
| **Model download screen** | Big dot-matrix `%`, thin progress bar, mono spec readout (`4.3GB · ARM64-V8A`), monochrome **cancel**; destructive **delete** uses red. |
| **First-run / empty state** | Large dot-matrix wordmark, a single lowercase tagline (`everything runs on your device.`), one monochrome primary action. |
| **Settings (backend, theme)** | List rows on `surface`, 1dp `outline` dividers, mono section headers. Selected = monochrome check, not a colored highlight. |

---

## 9. Flutter / Material 3 implementation

Map the tokens onto a `ColorScheme.dark` so Material widgets inherit the language for free:

| Token | M3 `ColorScheme` role |
|---|---|
| `bg` | `surface` + `scaffoldBackgroundColor` |
| `surface` | `surfaceContainerLow` |
| `surfaceContainer` | `surfaceContainer` |
| `surfaceContainerHigh` | `surfaceContainerHigh` |
| `outline` | `outline` |
| `outlineVariant` | `outlineVariant` |
| `textPrimary` | `onSurface` |
| `textSecondary` | `onSurfaceVariant` |
| `accent` (red) | `primary` + `error` |
| `onAccent` | `onPrimary` / `onError` |

`ThemeData` checklist:
- `useMaterial3: true`, `brightness: Brightness.dark`.
- `scaffoldBackgroundColor: #000000`.
- `cardTheme` / `dialogTheme`: `elevation: 0`, `surfaceTintColor: Colors.transparent`, `shape` with 12dp radius + `BorderSide(color: outline)`.
- `dividerTheme`: `color: outline`, `thickness: 1`.
- `splashFactory` subtle; keep ripples low-contrast.
- `textTheme`: build with bundled **Space Grotesk** (display→title→body) and **Space Mono** (`labelSmall`/`labelMedium` uppercase + letterSpacing 1.5). Register the **dot-matrix** font as a separate `TextStyle` helper (`AppText.dotMatrix(...)`) for display/numerals.
- Centralize tokens in an `AppColors` / `AppText` / `AppSpacing` file; never hardcode hex in widgets (keeps it swappable and testable, per the constitution's design principle).

---

## 10. Quick reference (cheat sheet)

```
CANVAS        #000000
SURFACES      #0D0D0D → #161616 → #222222
BORDERS       #2E2E2E (hairline, 1dp)
TEXT          #FFFFFF / #A0A0A0 / #5C5C5C
ACCENT (RED)  #D71921  — active / recording / stop / error ONLY
TYPE          Dot-matrix (display) · Space Grotesk (UI) · Space Mono (spec labels)
SHAPE         cards 12 · controls 8 · grid 4dp
ELEVATION     none — surface steps + hairline borders
MOTION        150–250ms, mechanical · dot-matrix pulse for loaders
VOICE         lowercase · model ( gemma 4 e2b ) · UPPERCASE MONO METADATA
```
