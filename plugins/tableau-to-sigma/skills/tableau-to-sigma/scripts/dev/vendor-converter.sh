#!/usr/bin/env bash
# vendor-converter.sh — refresh the COMMITTED, zero-config Tableau→Sigma converter
# that ships inside this skill at converter/tableau.mjs.
#
# Unlike fetch-converter.sh (which clones+builds into a gitignored vendor/ dir for
# devs), this BUNDLES the built converter into a single self-contained ESM file and
# commits it, so local conversion works for everyone with NO clone, NO npm install,
# and NO network — the guaranteed local fallback migrate-tableau.rb auto-discovers
# last. A single bundled file (esbuild) means no node_modules to commit and no
# .gitignore fight; its only runtime requirement is `node` on PATH.
#
# The vendored snapshot can drift from the live converter. That is the accepted
# trade for a zero-setup, no-data-egress default; a dev's own local checkout (or
# TABLEAU_MCP_BUILD / SIGMA_DATA_MODEL_MCP / fetch-converter.sh) still WINS over the
# vendored copy, so the floor only kicks in when nothing fresher exists. Re-run this
# after the converter changes (see memory: "mcp-sync") and commit the result.
#
#   ./scripts/dev/vendor-converter.sh                 # use ~/sigma-data-model-mcp
#   ./scripts/dev/vendor-converter.sh /path/to/mcp    # use a specific checkout
#
# Requires: a sigma-data-model-mcp checkout with esbuild installed (its devDep) +
# git for provenance stamping.
set -euo pipefail

SRC="${1:-$HOME/sigma-data-model-mcp}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"   # skill root
DEST="$HERE/converter"
ENTRY="$SRC/build/tableau.js"
OUT="$DEST/tableau.mjs"

[ -d "$SRC" ] || { echo "FATAL: converter source not found: $SRC (pass a path, or clone twells89/sigma-data-model-mcp)"; exit 1; }

# Build the converter if its entry artifact is missing.
if [ ! -f "$ENTRY" ]; then
  echo "→ $ENTRY missing — building (npm ci && npm run build)"
  ( cd "$SRC" && { npm ci --silent || npm install --silent; } && npm run build --silent )
fi
[ -f "$ENTRY" ] || { echo "FATAL: $ENTRY still missing after build"; exit 1; }

ESBUILD="$SRC/node_modules/.bin/esbuild"
[ -x "$ESBUILD" ] || { echo "FATAL: esbuild not found at $ESBUILD — run 'npm install' in $SRC first"; exit 1; }

echo "→ bundling converter closure into $OUT (single self-contained ESM file)"
mkdir -p "$DEST"
"$ESBUILD" "$ENTRY" --bundle --format=esm --platform=node --outfile="$OUT" >/dev/null

# Sanity: the bundle must export convertTableauToSigma and pull in NO external module.
node --input-type=module -e "import { convertTableauToSigma } from '$OUT'; if (typeof convertTableauToSigma !== 'function') { console.error('FATAL: bundle does not export convertTableauToSigma'); process.exit(1); }"

# Stamp provenance so drift is visible in the diff.
SHA="$(git -C "$SRC" rev-parse --short HEAD 2>/dev/null || echo unknown)"
DATE="$(git -C "$SRC" log -1 --format=%cd --date=short 2>/dev/null || echo unknown)"
FXP="$(node -e "console.log(require('$SRC/node_modules/fast-xml-parser/package.json').version)" 2>/dev/null || echo unknown)"
cat > "$DEST/PROVENANCE.json" <<EOF
{
  "source_repo": "twells89/sigma-data-model-mcp",
  "source_commit": "$SHA",
  "source_commit_date": "$DATE",
  "fast_xml_parser_version": "$FXP",
  "artifact": "tableau.mjs",
  "bundler": "esbuild --bundle --format=esm --platform=node",
  "note": "Self-contained bundled artifact, not source. Refresh with scripts/dev/vendor-converter.sh after the converter changes."
}
EOF

echo "✓ vendored converter ready: $OUT (source $SHA, $DATE; fast-xml-parser $FXP)"
echo "  migrate-tableau.rb auto-discovers it as the guaranteed local fallback — commit the diff."
