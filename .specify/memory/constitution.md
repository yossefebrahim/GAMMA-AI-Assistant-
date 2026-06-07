<!--
SYNC IMPACT REPORT
==================
Version change: 1.1.0 → 1.2.0  [MINOR amendment]
Bump rationale: Added a new core principle (X. Design Identity — Monochrome Minimalism) and
reconciled the existing Dark-First & Accessible principle (VI) to defer to it. Adding a new
principle is a MINOR bump per the versioning policy. No principle removed or redefined in a
backward-incompatible way; VI retains its accessibility floor and now references X.

Added principles:
  - X. Design Identity — Monochrome Minimalism (Nothing-inspired: near-black canvas,
       monochrome palette + single #D71921 accent, dot-matrix/grotesque/mono typography,
       no gradients/shadows, Glyph-style motion, centralized tokens)

Modified principles:
  - VI. Dark-First & Accessible — now defers visual-language specifics to Principle X and
       .specify/memory/design-system.md; accessibility floor remains mandatory and prevails

Modified sections: none
Removed sections: none

Templates requiring updates:
  - .specify/templates/plan-template.md          ✅ Constitution Check gate resolves against
       this file at plan time; no edit required (will now also gate on Principle X / tokens).
  - .specify/templates/spec-template.md          ✅ no change required
  - .specify/templates/tasks-template.md         ✅ no change required
  - CLAUDE.md / README.md                         ✅ no hardcoded design refs to update

Deferred TODOs: none.

Notes:
  - .specify/memory/design-system.md EXISTS and already encodes this language (palette with
       bg #000000 and accent #D71921, dot-matrix signature, flat/no-shadow, lowercase voice,
       monospace metadata). It is the BINDING token source referenced by Principle X and §VI,
       and that reference resolves. Keep the two in sync whenever either changes (palette,
       type scale, motion, surface, token names).
-->

# On-Device Gemma Assistant Constitution

## Core Principles

### I. Privacy Is the Product (NON-NEGOTIABLE)

All inference MUST run on-device. The ONLY permitted outbound network call is the
one-time model download (including any license, manifest, or checksum fetch strictly
required to perform that download). User content — prompts, generated responses, images,
audio, and conversation metadata — MUST NEVER leave the device. Analytics, crash
reporting, and telemetry MUST NOT capture conversation content; any telemetry MUST be
opt-in and content-free. Every network-capable code path MUST be auditable and justified
against this rule.

**Rationale**: Privacy is this product's reason to exist. A single content-bearing
network call invalidates the entire value proposition, so the constraint is absolute,
not best-effort.

### II. Offline-First

Once a model is installed, every core feature MUST function with zero connectivity. Loss
of connectivity MUST NEVER interrupt, corrupt, or terminate an active chat or generation.
Features MUST NOT block on or degrade with network availability, the initial model
download excepted. The app MUST be fully operable in airplane mode after setup.

**Rationale**: Offline operation is the natural consequence of on-device inference and
the reliability guarantee users depend on; connectivity must be an enhancement, never a
prerequisite.

### III. Capability-Driven UX

The UI MUST expose only the input affordances the active model actually supports — image,
audio, function calling, and thinking included. Capabilities MUST be modeled as data
queried from the active model or service, never as hardcoded per-model conditional
branches. An affordance for a capability the current model cannot handle MUST NOT be
rendered or enabled.

**Rationale**: Models differ in modality support and that support set changes over time.
Treating capabilities as data keeps the interface honest and prevents broken
interactions as models are swapped.

### IV. Responsive & Cancellable

Output MUST stream token-by-token to the user. Every long-running operation — model
download and text generation — MUST be cancellable by the user at any time, with prompt
resource cleanup on cancel. Inference and other heavy work MUST NOT run on the UI isolate;
the UI MUST remain interactive throughout.

**Rationale**: On-device generation is slow relative to UI expectations. Streaming and
cancellation keep the experience under the user's control and the interface alive.

### V. Graceful Degradation

The app MUST preflight device capability — available RAM, CPU architecture, and supported
backends — before attempting model load or inference. When a device cannot support an
operation, the app MUST fail with clear, honest, actionable guidance, never an unexplained
crash or out-of-memory kill. Conditions below the required baseline MUST be detected and
communicated up front, not discovered at runtime.

RAM and architecture tiers (non-negotiable):

- **Hard requirement**: arm64-v8a CPU architecture and ≥ 8 GB RAM. Devices below either
  threshold MUST be rejected at startup with actionable guidance.
- **Comfortable target**: ~12 GB RAM. This is the threshold at which the optional E4B
  upgrade tier MAY be offered to the user.
- **Borderline devices (exactly 8 GB)**: E2B MUST be used as the default and the E4B tier
  MUST NOT be offered, regardless of user preference.

**Rationale**: Large models push device limits hard. Predictable, explained failure
preserves user trust and prevents data loss from abrupt termination. Explicit RAM
thresholds keep model-tier selection safe and deterministic rather than speculative.

### VI. Dark-First & Accessible

The app MUST use Material 3 with dark theme as the default. Theme MUST be user-controllable
and persisted across sessions. UI MUST meet contrast and touch-target accessibility
standards — WCAG AA contrast ratios and a minimum 48dp touch target. Accessibility is a
release gate, not a follow-up. The specific visual language — palette, typography, motion,
and surface treatment — is governed by Principle X (Design Identity — Monochrome Minimalism)
and the binding token set in `.specify/memory/design-system.md`; the accessibility floor
defined here remains mandatory and prevails wherever a visual choice would compromise it.

**Rationale**: A private assistant is used in varied lighting and by varied people.
Accessible, dark-first design serves both visual comfort and inclusion as first-class
concerns.

### VII. Testable Through a Plugin Seam

All flutter_gemma usage MUST be isolated behind a single service abstraction (interface).
Domain and presentation logic MUST be unit-testable without the native plugin, using fakes
or mocks of that seam. No widget, provider, or domain class may import or call
flutter_gemma directly.

**Rationale**: The native plugin cannot run inside unit tests. A single seam keeps the
bulk of the application fast to test and the underlying plugin swappable.

### VIII. Resource Hygiene

Exactly ONE model MUST be active at a time. Models and inference sessions MUST be explicitly
released when no longer needed — on model switch, navigation away, or backgrounding as
appropriate. Downloaded model storage MUST be user-visible and user-deletable. Large
downloads MUST respect Android foreground-service rules.

**Rationale**: Models consume gigabytes of RAM and storage. Disciplined lifecycle
management prevents leaks, OOM kills, and silent disk bloat.

### IX. Lean Scope

The app MUST ship the smallest thing that works, then layer. The following are explicit
NON-GOALS for v1 and MUST NOT be built until the core experience is solid: cloud sync, user
accounts, RAG/embeddings, and non-Android platforms. Any new scope MUST be justified against
the core experience before it is adopted.

**Rationale**: A solid, focused core protects the privacy and reliability guarantees;
premature breadth introduces complexity that undermines them.

### X. Design Identity — Monochrome Minimalism

The visual language is inspired by Nothing: a near-pure-black, dark-first canvas and a
strictly monochrome palette (black / white / gray) with a single red accent (#D71921). The
accent MUST be used sparingly and ONLY for active, recording, stop, and destructive/error
states. Typography MUST pair a dot-matrix display face (branding and numerals) with a clean
technical grotesque for UI and a monospace for status/metadata labels. Gradients and drop
shadows MUST NOT be used; separation comes from hairline borders and subtle surface steps.
Loading and active states MUST use dot-matrix / Glyph-style pulsing motifs rather than
conventional spinners. Microcopy MUST be lowercase and understated. Design tokens MUST be
centralized — no hardcoded colors or fonts in widgets. The complete, binding token set lives
in `.specify/memory/design-system.md`, which every feature plan and implementation MUST
follow.

**Rationale**: A distinctive, disciplined visual identity is part of the product, not
decoration. Centralizing it as binding tokens in one design system keeps every screen
coherent and makes the identity enforceable in review rather than aspirational.

## Technology & Platform Constraints

- **Platform**: Android first. Non-Android platforms are out of scope for v1 (Principle IX).
- **Language & Framework**: Flutter + Dart.
- **State Management**: Riverpod.
- **Persistence**: SQLite (conversations, settings, model registry).
- **Model Runtime**: flutter_gemma (LiteRT-LM / MediaPipe), `.litertlm` format.
  Models: Gemma 4 E2B (~2.4 GB, `ModelType.gemma4`) as primary / default; Gemma 4 E4B
  (~4.3 GB, `ModelType.gemma4`) as an optional upgrade tier for devices with ≥ 12 GB RAM.
  Both variants expose identical capabilities (text, image, audio, function calling, thinking);
  tier selection is a catalog configuration, not an architectural branch.
- **Device Baseline**: arm64-v8a with 8 GB RAM (Principle V).
- **Networking**: restricted to the one-time model download only (Principle I).

Any deviation from this stack MUST be recorded as a constitution amendment with rationale.

## Development Workflow & Quality Gates

- **Plugin-seam gate**: every change touching model behavior MUST keep flutter_gemma behind
  the service abstraction (Principle VII).
- **Test gate**: domain and presentation logic MUST have passing unit tests that run without
  the native plugin. Capability-gating logic (Principle III) MUST be unit-tested against
  representative capability data.
- **Privacy gate**: every change introducing or modifying a network call MUST document the
  call and demonstrate it carries no user content (Principle I).
- **Accessibility gate**: UI changes MUST be verified for contrast and touch-target
  compliance before merge (Principle VI).
- **Resource gate**: any code that loads a model or opens a session MUST show its
  corresponding release path (Principle VIII).
- **Constitution Check**: `/speckit-plan` MUST evaluate each feature against these principles
  before Phase 0 research and re-check after Phase 1 design. Violations MUST be recorded in
  the plan's Complexity Tracking table with justification.

## Governance

This constitution supersedes all other development practices and conventions for the
On-Device Gemma Assistant project.

**Amendment procedure**: changes MUST be proposed via pull request that (a) names the
principle(s) or section(s) affected, (b) provides rationale, and (c) updates the version and
Sync Impact Report. Amendments require maintainer approval before merge.

**Versioning policy** (semantic):

- **MAJOR**: removal or backward-incompatible redefinition of a principle or governance rule.
- **MINOR**: addition of a new principle or section, or materially expanded guidance.
- **PATCH**: clarifications, wording, and non-semantic refinements.

**Compliance review**: all pull requests and reviews MUST verify compliance with these
principles. The Constitution Check gate in `plan.md` MUST pass before implementation begins.
Deviations MUST be justified in the plan's Complexity Tracking table; an unjustifiable
violation MUST be rejected, or the constitution amended first. Runtime development guidance
lives in `CLAUDE.md` and the active feature plan.

**Version**: 1.2.0 | **Ratified**: 2026-06-07 | **Last Amended**: 2026-06-07
