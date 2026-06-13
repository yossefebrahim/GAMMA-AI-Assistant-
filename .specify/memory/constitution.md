<!--
SYNC IMPACT REPORT
==================
Version change: 1.2.0 → 2.0.0  [MAJOR amendment]
Bump rationale: Backward-incompatible redefinition of a NON-NEGOTIABLE principle.
  Principle I ("Privacy Is the Product") previously stated an ABSOLUTE rule: the only
  permitted outbound call was the one-time model download, and user content could never
  leave the device under any circumstances. This amendment redefines that rule as
  on-device-by-default with individually opt-in, off-by-default, visibly-indicated
  egress for any feature that sends user content off-device. The discipline — opt-in,
  visible at the moment it happens, graceful offline degradation, auditable, named
  recipient, justified — remains NON-NEGOTIABLE; only the binary absolute is relaxed
  to a governed opt-in model. This is a MAJOR bump per the versioning policy: it is a
  backward-incompatible redefinition of a principle.

Note on model downloads: model downloads have ALWAYS been network-based (bytes-in).
  Principle I has never restricted bytes-in; it governs USER CONTENT egress (bytes-out).
  This amendment makes that distinction explicit.

Modified principles:
  - I. Privacy Is the Product — redefined from absolute-no-egress to on-device-by-default
       with governed opt-in egress; discipline (opt-in, off by default, visibly indicated,
       graceful degradation, auditable, named recipient, justified) remains NON-NEGOTIABLE.
  - II. Offline-First — light reconciliation: explicitly states opt-in network features
       are enhancements that degrade gracefully, never prerequisites; "app never breaks
       offline" language made explicit.

Modified sections:
  - Technology & Platform Constraints → Networking bullet: now reflects (a) one-time
       model download and (b) explicitly opt-in, off-by-default features that send user
       content off-device under the Principle I safeguards.
  - Development Workflow → Privacy gate: content-bearing calls now permitted ONLY when
       behind an opt-in toggle (off by default), visibly indicated at call time, offline-
       degrading, named-recipient, and auditable; all other calls must still carry no
       user content.

Removed sections: none

Templates requiring updates:
  - .specify/templates/plan-template.md          ✅ no structural edit needed — its
       Constitution Check section holds only generic placeholder text and resolves the
       gates dynamically from this constitution file at plan time, so the new opt-in
       egress safeguards (off by default, visibly indicated, offline-degrading, named
       recipient, auditable) are gated automatically without editing the template.
  - .specify/templates/spec-template.md          ✅ no change required
  - .specify/templates/tasks-template.md         ✅ no change required
  - CLAUDE.md / README.md                         ✅ no hardcoded privacy refs to update;
       the active feature (005-memory) is fully on-device and unaffected by this amendment.

Deferred TODOs: none.
-->

# On-Device Gemma Assistant Constitution

## Core Principles

### I. Privacy Is the Product (NON-NEGOTIABLE)

All inference MUST run on-device. User content — prompts, generated responses, images,
audio, and conversation metadata — MUST NOT leave the device by default. The one-time
model download (including any license, manifest, or checksum fetch strictly required to
perform that download) remains a permitted network call; it has always been network-based
and is bytes-in, not user-content-out. Any feature that sends user content off-device
MUST be individually opt-in, OFF by default, visibly indicated in the UI at the moment
egress happens, and designed to degrade gracefully so the app never breaks offline. Every
such path MUST be auditable, MUST name its recipient, and MUST be justified. Analytics,
crash reporting, and telemetry MUST NOT capture conversation content; any telemetry MUST
be opt-in and content-free. The discipline itself — opt-in, off by default, visible at
the moment it happens, graceful offline degradation, auditable, named recipient, justified
— is NON-NEGOTIABLE.

**Rationale**: Privacy is this product's reason to exist. The governing principle is
on-device by default: no user content leaves the device unless the user explicitly
enables a specific, named, visibly-indicated feature that degrades gracefully without it.
Model downloads have always been network-based (bytes-in); this principle governs user
content egress (bytes-out). The discipline protecting user content is absolute — what
changes is that a rigorously governed opt-in path is now permitted rather than prohibited,
enabling future enhancements without compromising the core privacy guarantee.

### II. Offline-First

Once a model is installed, every core feature MUST function with zero connectivity. Loss
of connectivity MUST NEVER interrupt, corrupt, or terminate an active chat or generation.
Core features MUST NOT block on or degrade with network availability, the initial model
download excepted. Opt-in network features permitted under Principle I MUST degrade
gracefully when offline — they are enhancements, never prerequisites, and their absence
MUST NOT break the app. The app MUST be fully operable in airplane mode after setup.

**Rationale**: Offline operation is the natural consequence of on-device inference and
the reliability guarantee users depend on. The app never breaks offline; connectivity
must always be an enhancement, never a prerequisite.

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
- **Networking**: restricted to (a) the one-time model download and (b) explicitly opt-in,
  off-by-default features that send user content off-device under the Principle I safeguards
  (opt-in, visibly indicated at the moment of egress, gracefully degrading offline, auditable,
  named recipient, justified).

Any deviation from this stack MUST be recorded as a constitution amendment with rationale.

## Development Workflow & Quality Gates

- **Plugin-seam gate**: every change touching model behavior MUST keep flutter_gemma behind
  the service abstraction (Principle VII).
- **Test gate**: domain and presentation logic MUST have passing unit tests that run without
  the native plugin. Capability-gating logic (Principle III) MUST be unit-tested against
  representative capability data.
- **Privacy gate**: every change introducing or modifying a network call MUST document the
  call and demonstrate it carries no user content (Principle I) — OR, if it is a
  content-bearing call, MUST demonstrate it is behind an opt-in toggle (off by default),
  visibly indicated at call time, degrades gracefully offline, names its recipient, and is
  auditable. A content-bearing call that does not meet all of these criteria MUST be rejected.
- **Accessibility gate**: UI changes MUST be verified for contrast and touch-target
  compliance before merge (Principle VI).
- **Resource gate**: any code that loads a model or opens a session MUST show its
  corresponding release path (Principle VIII).
- **Constitution Check**: `/speckit-plan` MUST evaluate each feature against these principles
  before Phase 0 research and re-check after Phase 1 design. Features introducing opt-in
  egress MUST additionally verify the Principle I safeguards (opt-in toggle off by default,
  visible indication at egress time, offline degradation, named recipient, auditability).
  Violations MUST be recorded in the plan's Complexity Tracking table with justification.

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

**Version**: 2.0.0 | **Ratified**: 2026-06-07 | **Last Amended**: 2026-06-12
