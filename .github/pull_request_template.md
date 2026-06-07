<!--
Thanks for the PR! CI runs automatically on every PR to main:
analyze + tests + seam guards + codegen check + Android build smoke.
Run `bash tool/verify.sh` locally to reproduce the gates before pushing.
-->

## What & why

<!-- One or two sentences. Link the spec/FR/SC IDs this touches, e.g. FR-021, SC-005. -->

## How to validate

<!-- Steps a reviewer can follow, or "covered by tests in test/…". -->

## Checklist

- [ ] `bash tool/verify.sh` passes locally (analyze, tests, seams, codegen).
- [ ] No `package:flutter_gemma` import outside `lib/infrastructure/gemma/` (Constitution VII).
- [ ] No networking outside `lib/data/model/background_model_downloader.dart` (Constitution I — privacy).
- [ ] Generated code committed if schema/codegen changed (`dart run build_runner build`).
- [ ] Tests added/updated for the behaviour changed.
- [ ] On-device / offline-first invariants preserved (no user content leaves the device).
