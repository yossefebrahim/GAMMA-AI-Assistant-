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
#   * package:record / audioplayers             → ONLY lib/infrastructure/media/  (AudioRecorderService
#                                                  / AudioPreviewPlayer — 003 R2/R4)
#   * package:battery_plus / android_intent_plus → ONLY lib/infrastructure/tools/ (DeviceInfoToolService
#                                                  / TimerIntentService — 004 R4)
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

check_seam "record|audioplayers" "lib/infrastructure/media/" \
  "record/audioplayers" \
  "depend on lib/domain/services/audio_recorder_service.dart or audio_preview_player.dart instead."

check_seam "battery_plus|android_intent_plus" "lib/infrastructure/tools/" \
  "battery_plus/android_intent_plus" \
  "depend on the DeviceInfoToolService / TimerIntentService seams in lib/infrastructure/tools/ instead (004 R4)."

# 006 web-research seam guards (Principle VII, FR-018, SC-014):
#   * package:http          → ONLY lib/infrastructure/network/ (TavilyNetworkResearchService)
#   * flutter_secure_storage → ONLY lib/infrastructure/network/ (FlutterSecureKeyStore)
#   * package:html          → ONLY lib/infrastructure/network/ (HtmlExtractor)
check_seam "http[/']" "lib/infrastructure/network/" \
  "package:http" \
  "depend on lib/domain/services/network_research_service.dart (the NetworkResearchService seam) instead. Only TavilyNetworkResearchService may import package:http (006, Principle VII)."

check_seam "flutter_secure_storage" "lib/infrastructure/network/" \
  "flutter_secure_storage" \
  "depend on lib/domain/services/secure_key_store.dart (the SecureKeyStore seam) instead. Only FlutterSecureKeyStore may import flutter_secure_storage (006, Principle VII)."

check_seam "html[/']" "lib/infrastructure/network/" \
  "package:html" \
  "depend on lib/infrastructure/network/html_extractor.dart (HtmlExtractor) via the NetworkResearchService seam instead. Only HtmlExtractor may import package:html (006, Principle VII)."

if [[ "$status" -ne 0 ]]; then
  exit 1
fi

echo "✓ Plugin seams intact — flutter_gemma → lib/infrastructure/gemma/; image_picker/permission_handler/record/audioplayers → lib/infrastructure/media/; battery_plus/android_intent_plus → lib/infrastructure/tools/; http/flutter_secure_storage/html → lib/infrastructure/network/"
