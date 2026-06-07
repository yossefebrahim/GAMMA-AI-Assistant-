# CI/CD

Every pull request to `main` (and every push to `main`) is tested automatically by
GitHub Actions. The same gates run locally via `bash tool/verify.sh`, so a PR can be
green before it is ever pushed.

## Pipelines

| Workflow | File | Trigger | What it does |
|---|---|---|---|
| **CI** | [`.github/workflows/ci.yml`](../.github/workflows/ci.yml) | PR → `main`, push → `main`, manual | Analyze, tests, seam guards, codegen check, Android build smoke |
| **Release** | [`.github/workflows/release.yml`](../.github/workflows/release.yml) | push tag `v*`, manual | Builds release APK + AAB, publishes a GitHub Release |

### CI jobs

| Job | Gate | Blocking? |
|---|---|---|
| `analyze` | `flutter analyze --fatal-infos --fatal-warnings` | ✅ |
| `analyze` | `pubspec.lock` committed & consistent | ✅ |
| `analyze` | Plugin-seam guard — `flutter_gemma` only in `lib/infrastructure/gemma/` (Constitution VII) | ✅ |
| `analyze` | Privacy/network-seam guard — networking only in the model-download seam (Constitution I) | ✅ |
| `analyze` | Generated code up to date (`dart run build_runner build` → no diff) | ✅ |
| `analyze` | `dart format` clean | ⚠️ advisory (annotation only) |
| `test` | `flutter test --coverage` (unit + widget; offline, fakes) | ✅ |
| `build-android` | `flutter build apk --debug --target-platform android-arm64` | ✅ |
| `ci-passed` | Aggregates the above into one required check | ✅ |

`ci-passed` is the single status check to require in branch protection — it stays
valid even as individual jobs are added or removed.

## Run the gates locally

```bash
bash tool/verify.sh              # full pipeline
SKIP_BUILD=1 bash tool/verify.sh # skip the slow Android build smoke
```

## Enable branch protection (one-time)

After the CI workflow has run at least once on `main` (so GitHub knows the
`CI Passed` check exists):

```bash
bash tool/setup_branch_protection.sh
```

This requires `CI Passed` + 1 review, up-to-date branches, linear history, and
conversation resolution before merging to `main`. Needs `gh` with repo-admin rights.

## Releases

```bash
git tag v1.0.0
git push origin v1.0.0   # → Release workflow builds artifacts + GitHub Release
```

> **Signing:** release builds are currently **debug-signed** (see the TODO in
> `android/app/build.gradle.kts`), so the artifacts are not Play-Store-uploadable
> yet. To ship for real, add a release keystore + `key.properties` via repo
> secrets and uncomment the signing/Play steps in `release.yml`.

## Toolchain pinning

- Flutter is pinned to **3.44.1 / stable** (`FLUTTER_VERSION` in both workflows) to
  match `specs/001-model-download-chat/research.md`. Bump it deliberately.
- All actions are **SHA-pinned** with a version comment. [Dependabot](../.github/dependabot.yml)
  opens weekly PRs to bump the pins (plus `pub` and Gradle dependencies).
