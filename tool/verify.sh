#!/usr/bin/env bash
# Local mirror of the CI pipeline (.github/workflows/ci.yml). Run before pushing
# so a PR's gates are green before it ever reaches GitHub.
#
#   bash tool/verify.sh            # run every gate, report all failures
#   SKIP_BUILD=1 bash tool/verify.sh   # skip the (slow) Android build smoke
#
# Exit 0 = every required gate passed. Exit 1 = at least one failed.
# The format check is advisory (matches CI) and never fails the run.
set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

bold=$'\033[1m'; red=$'\033[31m'; grn=$'\033[32m'; ylw=$'\033[33m'; rst=$'\033[0m'
failures=()

step() { printf '\n%s==> %s%s\n' "$bold" "$1" "$rst"; }
run() { # run "<label>" <cmd...>
  local label="$1"; shift
  step "$label"
  if "$@"; then
    printf '%s✓ %s%s\n' "$grn" "$label" "$rst"
  else
    printf '%s✗ %s%s\n' "$red" "$label" "$rst"
    failures+=("$label")
  fi
}

run "Resolve dependencies (flutter pub get)" flutter pub get

step "pubspec.lock is committed and consistent"
if git diff --exit-code pubspec.lock >/dev/null 2>&1; then
  printf '%s✓ pubspec.lock clean%s\n' "$grn" "$rst"
else
  printf '%s✗ pubspec.lock changed after pub get — commit it%s\n' "$red" "$rst"
  failures+=("pubspec.lock consistent")
fi

run "Static analysis (flutter analyze --fatal-infos --fatal-warnings)" \
  flutter analyze --fatal-infos --fatal-warnings

run "Plugin-seam guard (Constitution VII)" bash tool/check_plugin_seam.sh
run "Network/privacy-seam guard (Constitution I)" bash tool/check_network_seam.sh

step "Generated code is up to date (build_runner)"
# Keep stderr visible so a broken builder shows its cause locally, as it does in CI.
if ! dart run build_runner build >/dev/null; then
  printf '%s✗ build_runner failed (see error above)%s\n' "$red" "$rst"
  failures+=("Generated code up to date")
elif [[ -z "$(git status --porcelain -- '*.g.dart' '*.drift.dart' '*.freezed.dart')" ]]; then
  printf '%s✓ generated code matches committed output%s\n' "$grn" "$rst"
else
  # Scoped to generated artifacts so verify.sh stays accurate even with other uncommitted work.
  printf '%s✗ generated code is stale — run "dart run build_runner build" and commit%s\n' "$red" "$rst"
  git --no-pager diff --stat -- '*.g.dart' '*.drift.dart' '*.freezed.dart'
  failures+=("Generated code up to date")
fi

run "Tests with coverage (flutter test --coverage)" flutter test --coverage

# Advisory — never counts as a failure (matches CI policy for this repo).
step "Format check (advisory)"
if dart format --output=none --set-exit-if-changed . >/dev/null 2>&1; then
  printf '%s✓ dart format clean%s\n' "$grn" "$rst"
else
  printf '%s! some files are not dart-format-clean (advisory; run "dart format .")%s\n' "$ylw" "$rst"
fi

if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
  run "Build debug APK (arm64-v8a)" \
    flutter build apk --debug --target-platform android-arm64
else
  step "Android build smoke — SKIPPED (SKIP_BUILD=1)"
fi

echo
if [[ ${#failures[@]} -eq 0 ]]; then
  printf '%s✓ All required gates passed.%s\n' "$grn" "$rst"
  exit 0
fi
printf '%s✗ %d gate(s) failed:%s\n' "$red" "${#failures[@]}" "$rst"
for f in "${failures[@]}"; do printf '   - %s\n' "$f"; done
exit 1
