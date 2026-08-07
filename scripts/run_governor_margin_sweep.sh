#!/usr/bin/env bash
# 1D governor_margin sweep for `full` (FastSimplex), RL speed cap left at its
# normal/default value (5.0 m/s in vanilla_driver.yaml - no --speed-cap
# override passed at all, unlike the separate 2D margin x cap grid).
# governor_margin in {0.0,0.1,...,1.0} (11 levels, 0-100% in 10% steps).
# Austin + BrandsHatch, N=30 seeds, matching the original 3-arm governor
# ablation's scope/N so the whole margin curve is statistically consistent
# (margin=0.6 and margin=1.0 ARE that original ablation's default/nomargin
# arms, copied forward - see the copy-forward step run before this script).
# 11 x 2 x 30 = 660 cells; 120 already done via copy-forward, 540 new.
#
# Same resumability/retry/shm-cleanup design as the other sweep scripts.
#
# Usage: scripts/run_governor_margin_sweep.sh   (no args)
set -uo pipefail
cd "$(dirname "$0")/.."

if [[ ! -x scripts/run_experiment.sh ]]; then
  echo "FATAL: scripts/run_experiment.sh not found (run from repo root)" >&2
  exit 1
fi

RESULTS_TAG=governor_margin_sweep_normalcap_20260728
HOST_OUTPUT_DIR="f1tenth_drive/results/$RESULTS_TAG"
CONTAINER_OUTPUT_DIR="/ros_ws/results/$RESULTS_TAG"
TRACKING_DIR="f1tenth_drive/eval_tracking"
MANIFEST="$TRACKING_DIR/${RESULTS_TAG}_manifest.csv"
FAILURES_LOG="$TRACKING_DIR/${RESULTS_TAG}_failures.log"
DURATION=60
SEEDS=$(seq 1 30)
GRAND_TOTAL=660

TRACKS=(Austin BrandsHatch)
MODEL=delayed_3000000.pt
CKPT=3000000
ARCH=full
GOVERNOR_MARGINS=(0.0 0.1 0.2 0.3 0.4 0.5 0.6 0.7 0.8 0.9 1.0)

mkdir -p "$TRACKING_DIR" || { echo "FATAL: could not create $TRACKING_DIR" >&2; exit 1; }
if [[ ! -f $MANIFEST ]]; then
  echo "track,governor_margin,run_id,status,timestamp" > "$MANIFEST"
fi

manifest_row() {
  echo "$1,$2,$3,$4,$(date -Iseconds)" >> "$MANIFEST"
}

is_complete() {
  local f="$HOST_OUTPUT_DIR/$1/events.jsonl"
  [[ -f $f ]] && grep -q 'episode_end' "$f"
}

SHM_CLEANUP_EVERY=10
CELL_COUNT=0
cleanup_shm() {
  docker compose run --rm --no-deps --entrypoint bash drive -c \
    "find /dev/shm -maxdepth 1 -type f -user root -mmin +10 \
       \( -name 'fastrtps_*' -o -name 'sem.fastrtps_*' \) -delete" \
    >/dev/null 2>&1 || true
}

# run_cell TRACK GOV_MARGIN RUN_ID SEED
run_cell() {
  local track=$1 gov=$2 run_id=$3 seed=$4
  local exp="${ARCH}_${CKPT}_${track}_${run_id}"

  CELL_COUNT=$((CELL_COUNT + 1))
  if (( CELL_COUNT % SHM_CLEANUP_EVERY == 0 )); then
    echo "[shm-cleanup] after $CELL_COUNT cells"
    cleanup_shm
  fi

  if is_complete "$exp"; then
    echo "[skip] $exp (already complete)"
    manifest_row "$track" "$gov" "$run_id" "skipped"
    return 0
  fi

  local attempt
  for attempt in 1 2; do
    echo "[run attempt $attempt] $exp (gov=$gov, cap=normal/5.0)"
    scripts/run_experiment.sh --arch "$ARCH" --track "$track" --model "$MODEL" \
      --checkpoint "$CKPT" --duration "$DURATION" --run-id "$run_id" \
      --seed "$seed" --output-dir "$CONTAINER_OUTPUT_DIR" \
      --governor-margin "$gov"
    if is_complete "$exp"; then
      manifest_row "$track" "$gov" "$run_id" "done"
      return 0
    fi
    echo "[warn] $exp attempt $attempt produced no episode_end"
  done

  echo "[FAIL] $exp failed after 2 attempts" | tee -a "$FAILURES_LOG"
  manifest_row "$track" "$gov" "$run_id" "failed"
  return 1
}

TOTAL=0
for TRACK in "${TRACKS[@]}"; do
  echo "=================== track: $TRACK ==================="
  for gov in "${GOVERNOR_MARGINS[@]}"; do
    for seed in $SEEDS; do
      run_id=$(printf "gm%s_s%02d" "$gov" "$seed")
      run_cell "$TRACK" "$gov" "$run_id" "$seed"
      TOTAL=$((TOTAL + 1))
      echo "[progress] $TOTAL/$GRAND_TOTAL cells attempted"
    done
  done
done

echo "=================== sweep attempted: $TOTAL cells ==================="
echo "SWEEP_COMPLETE"
