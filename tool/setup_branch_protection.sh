#!/usr/bin/env bash
# One-time setup: require the CI pipeline to pass before anything merges to main.
#
# Makes the "CI Passed" status check (from .github/workflows/ci.yml) a required,
# blocking check on the main branch, requires branches to be up to date, and
# requires at least one approving PR review.
#
#   bash tool/setup_branch_protection.sh
#
# Requirements: gh CLI authenticated with admin rights on the repo, and the CI
# workflow must have run at least once (so GitHub knows the "CI Passed" context).
# Re-running is safe (idempotent — it overwrites the protection settings).
set -euo pipefail

branch="${1:-main}"
repo="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
echo "Configuring branch protection on ${repo}@${branch} ..."

gh api \
  --method PUT \
  -H "Accept: application/vnd.github+json" \
  "repos/${repo}/branches/${branch}/protection" \
  --input - <<'JSON'
{
  "required_status_checks": {
    "strict": true,
    "contexts": ["CI Passed"]
  },
  "enforce_admins": false,
  "required_pull_request_reviews": {
    "required_approving_review_count": 1,
    "dismiss_stale_reviews": true
  },
  "restrictions": null,
  "required_linear_history": true,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "required_conversation_resolution": true
}
JSON

echo "✓ Branch protection applied. PRs to ${branch} now require 'CI Passed' + 1 review."
