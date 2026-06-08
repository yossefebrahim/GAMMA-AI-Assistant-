#!/usr/bin/env bash
# Plugin-seam guard — Constitution Principle VII (Testable Through a Plugin Seam).
#
# Platform plugins may be imported ONLY inside their permitted seam directory; every other layer
# depends on a domain interface so domain/presentation stay unit-testable with fakes and plugins
# stay swappable. Run in CI / pre-commit. Exit 0 = clean; exit 1 = a forbidden import was found.
#
#   * package:flutter_gemma                     → ONLY lib/infrastructure/gemma/  (GemmaService)
#   * package:image_picker / permission_handler → ONLY lib/infrastructure/media/  (MediaPickerService
#                                                  / MediaPermissionService — 002 R2/R3)
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

status=0

# $1 = grep pattern (alternation of package prefixes), $2 = permitted dir prefix, $3 = label, $4 = fix hint.
check_seam() {
  local pattern="$1" allowed_dir="$2" label="$3" fix="$4"
  local violations
  violations="$(grep -rEn "import\s+['\"]package:(${pattern})" lib \
    --include='*.dart' \
    | grep -v "^${allowed_dir}" || true)"
  if [[ -n "$violations" ]]; then
    echo "✗ Plugin-seam violation (Principle VII): ${label} imported outside ${allowed_dir}"
    echo "$violations"
    echo
    echo "  Fix: ${fix}"
    echo
    status=1
  fi
}

check_seam "flutter_gemma" "lib/infrastructure/gemma/" \
  "flutter_gemma" \
  "depend on lib/domain/services/gemma_service.dart (the GemmaService seam) instead."

check_seam "image_picker|permission_handler" "lib/infrastructure/media/" \
  "image_picker/permission_handler" \
  "depend on lib/domain/services/media_picker_service.dart or media_permission_service.dart instead."

if [[ "$status" -ne 0 ]]; then
  exit 1
fi

echo "✓ Plugin seams intact — flutter_gemma → lib/infrastructure/gemma/; image_picker/permission_handler → lib/infrastructure/media/"
