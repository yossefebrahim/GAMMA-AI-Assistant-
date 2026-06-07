#!/usr/bin/env bash
# Privacy / network-seam guard — Constitution Principle I (Privacy Is the Product) + SC-009.
#
# The ONLY permitted outbound network call is the one-time model download, which lives in
# lib/data/model/background_model_downloader.dart (via background_downloader). No other source
# file may import a networking package or open a socket — that is how we keep the guarantee that
# no user content ever leaves the device auditable in CI rather than aspirational.
#
# (google_fonts is allowed: runtime fetching is disabled in main.dart, so it never hits the
# network. flutter_gemma runs fully on-device. The blocked list below is content-capable I/O.)
#
# Exit 0 = clean; exit 1 = a forbidden network use was found.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

allowed='^lib/data/model/background_model_downloader\.dart:'

violations="$(grep -rEn \
  "import\s+['\"]package:(http|dio|http2|grpc|web_socket_channel|socket_io_client)/|HttpClient\(|RawDatagramSocket|RawSocket|Socket\.(connect|startConnect)|WebSocket\.connect" \
  lib --include='*.dart' \
  | grep -vE "$allowed" || true)"

if [[ -n "$violations" ]]; then
  echo "✗ Privacy/network-seam violation (Principle I): networking outside the model-download seam"
  echo "$violations"
  echo
  echo "  All networking must stay in lib/data/model/background_model_downloader.dart (the only"
  echo "  outbound call is the one-time model download). No user content may leave the device."
  exit 1
fi

echo "✓ Network seam intact — the only networking is the model download (background_downloader)"
