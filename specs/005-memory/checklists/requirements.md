# Specification Quality Checklist: On-Device Memory — Durable Facts About the User

**Purpose**: Validate specification completeness and quality before proceeding to planning
**Created**: 2026-06-11
**Feature**: [spec.md](../spec.md)

## Content Quality

- [x] No implementation details (languages, frameworks, APIs)
- [x] Focused on user value and business needs
- [x] Written for non-technical stakeholders
- [x] All mandatory sections completed

## Requirement Completeness

- [x] No [NEEDS CLARIFICATION] markers remain — all 3 resolved in the 2026-06-11 clarify session
      (Q1 app-global memory, no per-conversation profiles; Q2 auto-save on valid call, chip is
      the safeguard; Q3 on by default/opt-out) plus 4 carried from the Phase 0 spike (injection
      path, id-bearing block, mandatory dedupe/supersede, non-destructive toggle) — all integrated
      into clarifications, FR-001–FR-024, edge cases, and key entities.
- [x] Requirements are testable and unambiguous
- [x] Success criteria are measurable
- [x] Success criteria are technology-agnostic (no implementation details)
- [x] All acceptance scenarios are defined
- [x] Edge cases are identified
- [x] Scope is clearly bounded
- [x] Dependencies and assumptions identified

## Feature Readiness

- [x] All functional requirements have clear acceptance criteria
- [x] User scenarios cover primary flows
- [x] Feature meets measurable outcomes defined in Success Criteria
- [x] No implementation details leak into specification

## Requirements coverage

| Area | FRs | SCs | USs |
|---|---|---|---|
| Capture (`remember_fact`) | FR-001–005 | SC-001–003 | US1, US4 |
| Injection (facts block → context) | FR-006–009 | SC-004–005, SC-011–012 | US2 |
| Forget (`forget_fact`) | FR-010–011 | SC-007 | US5 |
| Memory management screen | FR-012–017 | SC-008–009 | US3 |
| Capability gating & transparency | FR-018–019 | SC-010–011 | US6 |
| Failure / degradation | FR-020–022 | SC-001–002 (rate), SC-006–007 | US7 |
| Privacy / on-device / design | FR-023–024 | SC-012–014 | US6, US7 |

All 7 user stories have acceptance scenarios. All 24 FRs map to at least one SC or acceptance
scenario. All 14 SCs are measurable and technology-agnostic.

## Notes

- All checklist items pass (16/16) as of the 2026-06-11 specification session. Spec is ready for
  `/speckit-plan`.
- The runtime-specific evidence (80% capture, 0 false positives, native system-message injection,
  id-fabrication hazard, duplicate-save hazard, integer-as-double coercion) lives in
  `spike-findings.md` and is referenced, not duplicated, in the spec.
- FR-023 (on-device only, no embeddings/vectors/network) and SC-014 (code/network audit) encode the
  v1 constitution boundary (Principle I/IX). `tool/check_network_seam.sh` is the CI enforcement.
- FR-018 (capture gated on `functionCalling`) mirrors the 004 structural seam coupling exactly;
  FR-009 + FR-016 (injection and manual management NOT gated) are deliberate departures from 004's
  symmetry, each backed by a clarification or spike finding.
- The spec deliberately avoids Dart/Flutter vocabulary (DriftMemoryRepository, Riverpod, Jaccard
  threshold); all such design decisions live in `data-model.md` and `research.md`.
