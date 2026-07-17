#!/usr/bin/env bash
# Daily ADS-B trace pipeline, split into phases so each can run as its own CI step:
#   resolve  -> find the latest adsblol release tag for the variant
#   fetch    -> stream the split-tar assets straight into tar (no 4-6 GB staged)
#   fit      -> fit sparse Catmull-Rom spline nodes (fit_spline.py)
#   legs     -> split into per-airport leg partitions (build_legs.py)
#   upload   -> rclone sync the legs to Cloudflare R2
# Run a single phase (`run_pipeline.sh fit`) or the whole thing (`run_pipeline.sh`
# / `run_pipeline.sh all`). Phases share state through $WORK (the resolved tag is
# written to $WORK/TAG), so the CI steps hand off via the persisted workspace.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

REPO="${SRC_REPO:-adsblol/globe_history_2026}"
VARIANT="${VARIANT:-prod-0}"            # prod-0 (ADS-B) | mlatonly-0 | staging-0
WORK="${WORK:-$SCRIPT_DIR/work}"
OUT="${OUT:-$SCRIPT_DIR/out}"
R2_PREFIX="${R2_PREFIX:-legs}"
TOL_GROUND="${TOL_GROUND:-2}"
TOL_CRUISE="${TOL_CRUISE:-150}"
CORNER="${CORNER:-35}"
TAGFILE="$WORK/TAG"

resolve() {
    mkdir -p "$WORK"
    # Releases are newest-first, so the first page holds the latest of every
    # variant -- do NOT --paginate (that applies --jq per page -> one tag per page).
    local tag
    tag="$(gh api "repos/$REPO/releases?per_page=100" \
            --jq "[.[] | select(.tag_name | endswith(\"-planes-readsb-$VARIANT\"))][0].tag_name")"
    [ -n "$tag" ] && [ "$(printf '%s' "$tag" | wc -l)" -eq 0 ] \
        || { echo "bad/empty $VARIANT tag: '$tag'"; exit 1; }
    echo "$tag" >"$TAGFILE"
    echo "resolved $VARIANT release: $tag"
}

fetch() {
    local tag; tag="$(cat "$TAGFILE")"
    rm -rf "$WORK/traces"
    # browser_download_url is public, so curl concatenates the .tar.aa/.ab/.ac
    # parts (sorted) to stdout in one pass -> tar extracts, nothing staged on disk.
    mapfile -t urls < <(gh api "repos/$REPO/releases/tags/$tag" \
            --jq '.assets[].browser_download_url' | sort)
    echo "streaming ${#urls[@]} asset parts into tar..."
    curl -fsSL "${urls[@]}" | tar -x -C "$WORK"
    echo "extracted $(find "$WORK/traces" -name 'trace_full_*.json' | wc -l) traces"
}

fit() {
    python3 "$SCRIPT_DIR/fit_spline.py" "$WORK/traces" --ground-elevation \
        --airports "$SCRIPT_DIR/airports.csv" --parquet "$WORK/nodes" \
        --tol-ground "$TOL_GROUND" --tol-cruise "$TOL_CRUISE" --corner "$CORNER"
}

legs() {
    mkdir -p "$OUT"; rm -rf "$OUT/legs"
    python3 "$SCRIPT_DIR/build_legs.py" \
        --traces "$WORK/nodes/nodes.parquet" \
        --meta "$WORK/nodes/aircraft.parquet" --out-dir "$OUT/legs"
}

upload() {
    : "${R2_BUCKET:?set R2_BUCKET (Cloudflare R2 bucket name)}"
    local tag; tag="$(cat "$TAGFILE" 2>/dev/null || echo '?')"
    rclone sync "$OUT/legs" "r2:$R2_BUCKET/$R2_PREFIX" \
        --checksum --transfers 16 --fast-list --stats-one-line
    echo "DONE: $tag -> r2:$R2_BUCKET/$R2_PREFIX"
}

case "${1:-all}" in
    resolve) resolve ;;
    fetch)   fetch ;;
    fit)     fit ;;
    legs)    legs ;;
    upload)  upload ;;
    all)     resolve; fetch; fit; legs; upload ;;
    *) echo "usage: $0 [resolve|fetch|fit|legs|upload|all]" >&2; exit 2 ;;
esac
