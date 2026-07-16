#!/usr/bin/env bash
# Daily ADS-B trace pipeline:
#   resolve latest adsblol release -> stream-extract traces -> fit Bezier nodes
#   -> split into per-airport legs -> upload to Cloudflare R2.
# Designed to stream the ~4 GB download straight into tar so peak disk is only the
# ~2.9 GB extracted tree (no 4 GB of archive parts sitting on the runner).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

REPO="${SRC_REPO:-adsblol/globe_history_2026}"
VARIANT="${VARIANT:-prod-0}"            # prod-0 (ADS-B) | mlatonly-0 | staging-0
WORK="${WORK:-$SCRIPT_DIR/work}"
OUT="${OUT:-$SCRIPT_DIR/out}"
R2_PREFIX="${R2_PREFIX:-legs}"
: "${R2_BUCKET:?set R2_BUCKET (Cloudflare R2 bucket name)}"

TOL_GROUND="${TOL_GROUND:-2}"
TOL_CRUISE="${TOL_CRUISE:-150}"
CORNER="${CORNER:-35}"

mkdir -p "$WORK" "$OUT"

# 1. Latest release tag for the variant (releases are returned newest-first).
echo "::group::resolve release"
TAG="$(gh api "repos/$REPO/releases" --paginate \
        --jq "[.[] | select(.tag_name | endswith(\"-planes-readsb-$VARIANT\"))][0].tag_name")"
[ -n "$TAG" ] || { echo "no $VARIANT release found"; exit 1; }
echo "using release: $TAG"
echo "::endgroup::"

# 2. Stream the split-tar assets (.tar.aa, .tar.ab, ... in name order) into tar.
#    browser_download_url is public for a public repo, so curl needs no auth and
#    concatenates the parts to stdout in one pass -> no 4 GB staged on disk.
echo "::group::download + extract"
rm -rf "$WORK/traces"
mapfile -t URLS < <(gh api "repos/$REPO/releases/tags/$TAG" \
        --jq '.assets[].browser_download_url' | sort)
echo "assets: ${#URLS[@]}"
curl -fsSL "${URLS[@]}" | tar -x -C "$WORK"
echo "extracted $(find "$WORK/traces" -name 'trace_full_*.json' | wc -l) traces"
echo "::endgroup::"

# 3. Fit sparse centripetal-CR nodes, then split into per-airport legs.
echo "::group::fit_bezier"
python3 "$SCRIPT_DIR/fit_bezier.py" "$WORK/traces" --ground-elevation \
    --airports "$SCRIPT_DIR/airports.csv" \
    --parquet "$WORK/bezier" \
    --tol-ground "$TOL_GROUND" --tol-cruise "$TOL_CRUISE" --corner "$CORNER"
echo "::endgroup::"

echo "::group::build_legs"
rm -rf "$OUT/legs"
python3 "$SCRIPT_DIR/build_legs.py" \
    --traces "$WORK/bezier/nodes.parquet" \
    --meta "$WORK/bezier/aircraft.parquet" \
    --out-dir "$OUT/legs"
echo "::endgroup::"

# 4. Publish to R2 (rclone remote "r2" comes from RCLONE_CONFIG_R2_* env vars).
echo "::group::upload to r2:$R2_BUCKET/$R2_PREFIX"
rclone sync "$OUT/legs" "r2:$R2_BUCKET/$R2_PREFIX" \
    --checksum --transfers 16 --fast-list --stats-one-line
echo "::endgroup::"

echo "DONE: $TAG -> r2:$R2_BUCKET/$R2_PREFIX"
