#!/usr/bin/env bash
# Privacy / network-seam guard — Constitution Principle I (Privacy Is the Product) + SC-009/SC-014.
#
# Two classes of permitted outbound networking:
#   1. One-time model download: lib/data/model/background_model_downloader.dart
#      (via background_downloader — private model binary, never user content).
#   2. Web-research feature (006): lib/infrastructure/network/*.dart only
#      (package:http in TavilyNetworkResearchService; package:html in HtmlExtractor;
#      flutter_secure_storage in FlutterSecureKeyStore — key management, no network I/O).
#      Enforced in tandem with check_plugin_seam.sh (which gates these three packages to
#      lib/infrastructure/network/).
#
# No other file may import a networking package or open a raw socket — that is how we keep
# the guarantee auditable in CI rather than aspirational.
#
# (google_fonts is allowed: runtime fetching is disabled in main.dart.
#  flutter_gemma runs fully on-device. The blocked list below is content-capable I/O.)
#
# Exit 0 = clean; exit 1 = a forbidden network use was found.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

# Permitted locations for network imports:
#   ^lib/data/model/background_model_downloader\.dart  — one-time model download
#   ^lib/infrastructure/network/                        — 006 web-research seam (T025/T026/T027)
allowed='^lib/data/model/background_model_downloader\.dart:|^lib/infrastructure/network/'

violations="$(grep -rEn \
  "import\s+['\"]package:(http|dio|http2|grpc|web_socket_channel|socket_io_client)/|HttpClient\(|RawDatagramSocket|RawSocket|Socket\.(connect|startConnect)|WebSocket\.connect" \
  lib --include='*.dart' \
  | grep -vE "$allowed" || true)"

if [[ -n "$violations" ]]; then
  echo "✗ Privacy/network-seam violation (Principle I + SC-014): networking outside permitted seams"
  echo "$violations"
  echo
  echo "  Permitted network locations:"
  echo "    lib/data/model/background_model_downloader.dart  — one-time model download"
  echo "    lib/infrastructure/network/                       — 006 web-research (package:http, html, flutter_secure_storage)"
  echo
  echo "  All other networking is forbidden — no user content may leave the device."
  exit 1
fi

# ── 006 import-isolation guard (T027) ─────────────────────────────────────────────────────────
# package:http, flutter_secure_storage, package:html must be imported ONLY within
# lib/infrastructure/network/. Any import outside that directory is a seam violation.

status=0

_check_network_import() {
  local pattern="$1" label="$2" fix="$3"
  local violations
  violations="$(grep -rEn "import\s+['\"]package:(${pattern})" lib \
    --include='*.dart' \
    | grep -v '^lib/infrastructure/network/' || true)"
  if [[ -n "$violations" ]]; then
    echo "✗ Network-seam violation (006, T027, SC-014): ${label} imported outside lib/infrastructure/network/"
    echo "$violations"
    echo
    echo "  Fix: ${fix}"
    echo
    status=1
  fi
}

_check_network_import \
  "http[/']" \
  "package:http" \
  "Use the NetworkResearchService interface (lib/domain/services/network_research_service.dart). Only TavilyNetworkResearchService may import package:http."

_check_network_import \
  "flutter_secure_storage" \
  "flutter_secure_storage" \
  "Use the SecureKeyStore interface (lib/domain/services/secure_key_store.dart). Only FlutterSecureKeyStore may import flutter_secure_storage."

_check_network_import \
  "html[/']" \
  "package:html" \
  "Use HtmlExtractor via the NetworkResearchService seam. Only HtmlExtractor (html_extractor.dart) may import package:html."

if [[ "$status" -ne 0 ]]; then
  exit 1
fi

echo "✓ Network seam intact — model download → background_model_downloader.dart; web-research (http/html/flutter_secure_storage) → lib/infrastructure/network/ only"
