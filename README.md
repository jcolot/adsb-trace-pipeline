# adsb-trace-pipeline

Daily pipeline that turns the [adsblol `globe_history`](https://github.com/adsblol/globe_history_2026/releases)
ADS-B trace dump into compact, smooth per-airport flight tracks for a browser 3-D
viewer (THREE.js + [hyparquet](https://github.com/hyparam/hyparquet)).

## What it does

For each aircraft's raw readsb trace it fits a sparse set of **centripetal
Catmull-Rom control points** ("nodes") whose reconstruction — the exact curve the
frontend draws — stays within an **altitude-graduated tolerance** (2 m on the
ground → 150 m at cruise). It then splits each aircraft into flight **legs** and
writes them **hive-partitioned per airport** so the browser fetches only the
airport it's showing.

Result: ~37× smaller than the source, no overshoot, sharp taxi corners (cusps),
stable ground altitude, and no parked-at-gate "scribbles".

### Stages

1. **`fit_spline.py`** — `traces/ → nodes.parquet` + `aircraft.parquet`.
   Per-second decimation (mean position **and** time), stationary-gate snapping,
   ground-elevation reference, greedy CR-node placement.
2. **`build_legs.py`** — `nodes.parquet → legs/` (per-airport partitions +
   `flights.parquet` index).

`smooth_trace.py`, `compress_trace.py`, `validate_recon.py` are supporting /
diagnostic modules (`validate_recon.py` measures reconstruction error vs raw).

## Output schema

`legs/airports/airport=<ICAO>/data_0.parquet`, one row per node:

| column | type | notes |
|---|---|---|
| `icao` | string | aircraft hex |
| `t` | int32 | **deciseconds** (0.1 s) — divide by 10 for seconds |
| `lat`, `lon` | int32 | scaled fixed-point |
| `alt` | int32 | feet |
| `on_ground` | bool | |
| `cusp` | bool | **break the spline here** (taxi corner / ground↔air) |
| `leg_id`, `dep`, `arr`, `reg`, `type` | | leg / aircraft metadata |

**Frontend:** draw a centripetal Catmull-Rom through consecutive nodes, starting a
new curve at every `cusp` node.

## Run locally

```bash
pip install -r requirements.txt
python3 fit_spline.py path/to/traces --ground-elevation \
    --parquet nodes --tol-ground 2 --tol-cruise 150 --corner 35
python3 build_legs.py --traces nodes/nodes.parquet \
    --meta nodes/aircraft.parquet --out-dir out/legs
```

`run_pipeline.sh` does the whole daily job end-to-end (resolve latest release →
stream-extract → fit → legs → upload to R2). It streams the ~4 GB split-tar
download straight into `tar`, so peak disk is just the ~2.9 GB extracted tree.

## Daily automation

`.github/workflows/daily.yml` runs at **04:00 UTC** (after the ~03:26 UTC
`prod-0` release drops) and uploads `legs/` to Cloudflare R2 via `rclone`.

### Configuration

Repo **variable**: `R2_BUCKET` — the R2 bucket name.

Repo **secrets**:

| secret | value |
|---|---|
| `R2_ACCESS_KEY_ID` | R2 API token access key |
| `R2_SECRET_ACCESS_KEY` | R2 API token secret |
| `R2_ENDPOINT` | `https://<account-id>.r2.cloudflarestorage.com` |

R2 has **no egress fees**, so the browser range-fetches partitions directly.

### Frontend read URL

Public bucket base (r2.dev dev URL — rate-limited, not CDN-cached, fine to start):

```
https://pub-135f2252a0074f0b9761b0dc93a75fa5.r2.dev/legs
```

So a partition is:
`https://pub-135f2252a0074f0b9761b0dc93a75fa5.r2.dev/legs/airports/airport=<ICAO>/data_0.parquet`
and the leg index is `.../legs/flights.parquet`.

To move to a CDN-cached custom domain later (e.g. `splines.<domain>`), connect it
in **R2 → bucket → Settings → Custom Domains**; only this base URL changes on the
frontend — the pipeline is unaffected.

### CORS

hyparquet issues cross-origin **Range** requests, so set the bucket CORS policy
(**R2 → bucket → Settings → CORS**) to allow your frontend origin:

```json
[{"AllowedOrigins":["<FRONTEND_ORIGIN>"],
  "AllowedMethods":["GET","HEAD"],
  "AllowedHeaders":["range","content-type"],
  "ExposeHeaders":["content-length","content-range","accept-ranges"]}]
```
