#!/usr/bin/env bash
# Plugin-seam guard — Constitution Principle VII (Testable Through a Plugin Seam).
#
# `package:flutter_gemma` (and its symbols) may be imported ONLY inside lib/infrastructure/gemma/.
# Every other layer must depend on the GemmaService interface so domain/presentation stay
# unit-testable with FakeGemmaService and the plugin stays swappable. Run in CI / pre-commit.
#
# Exit 0 = clean; exit 1 = a forbidden import was found.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

# Search lib/ for flutter_gemma imports outside the permitted seam directory.
violations="$(grep -rEn "import\s+['\"]package:flutter_gemma" lib \
  --include='*.dart' \
  | grep -v '^lib/infrastructure/gemma/' || true)"

if [[ -n "$violations" ]]; then
  echo "✗ Plugin-seam violation (Principle VII): flutter_gemma imported outside lib/infrastructure/gemma/"
  echo "$violations"
  echo
  echo "  Fix: depend on lib/domain/services/gemma_service.dart (the GemmaService seam) instead."
  exit 1
fi

echo "✓ Plugin seam intact — flutter_gemma is confined to lib/infrastructure/gemma/"
