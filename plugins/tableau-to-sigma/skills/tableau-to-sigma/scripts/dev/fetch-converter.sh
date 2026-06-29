#!/usr/bin/env bash
# fetch-converter.sh — get a LOCAL Tableau→Sigma converter build with one command,
# for the no-egress mechanical path when you don't already have the sigma-data-model
# MCP checked out elsewhere.
#
# It clones (or updates) the converter repo into a GITIGNORED vendor/ dir under the
# skill and builds it. migrate-tableau.rb then auto-discovers vendor/sigma-data-model-mcp/
# build/tableau.js (see the auto-discover block) — no TABLEAU_MCP_BUILD needed.
#
# We deliberately do NOT commit the build artifact: the converter is actively
# developed and not self-contained (build/tableau.js imports siblings), so a vendored
# snapshot would silently drift. Re-run this script to refresh.
#
#   ./scripts/dev/fetch-converter.sh            # clone/update + build (default branch)
#   ./scripts/dev/fetch-converter.sh <ref>      # build a specific branch/tag/sha
#
# Requires: git + node/npm on PATH.
set -euo pipefail

REPO="${SIGMA_CONVERTER_REPO:-https://github.com/twells89/sigma-data-model-mcp.git}"
REF="${1:-}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # the skill's scripts/ dir
DEST="$HERE/vendor/sigma-data-model-mcp"

command -v git  >/dev/null || { echo "FATAL: git not on PATH"; exit 1; }
command -v npm  >/dev/null || { echo "FATAL: npm/node not on PATH — the local converter needs Node"; exit 1; }

if [ -d "$DEST/.git" ]; then
  echo "→ updating existing checkout at $DEST"
  git -C "$DEST" fetch --quiet origin
  if [ -n "$REF" ]; then git -C "$DEST" checkout --quiet "$REF"; git -C "$DEST" pull --quiet --ff-only origin "$REF" 2>/dev/null || true
  else git -C "$DEST" pull --quiet --ff-only; fi
else
  echo "→ cloning $REPO → $DEST"
  mkdir -p "$(dirname "$DEST")"
  git clone --quiet "$REPO" "$DEST"
  [ -n "$REF" ] && git -C "$DEST" checkout --quiet "$REF"
fi

echo "→ installing deps + building (npm ci && npm run build)"
( cd "$DEST" && { npm ci --silent || npm install --silent; } && npm run build --silent )

BUILD="$DEST/build/tableau.js"
if [ -f "$BUILD" ]; then
  echo ""
  echo "✓ local converter ready: $BUILD"
  echo "  migrate-tableau.rb will auto-discover it (no TABLEAU_MCP_BUILD needed)."
  echo "  built from $(git -C "$DEST" rev-parse --short HEAD) ($(git -C "$DEST" rev-parse --abbrev-ref HEAD))"
else
  echo "FATAL: build did not produce $BUILD — check the npm build output above"; exit 1
fi
