#!/usr/bin/env bash
# 2D tradeoff sweep for `full` (FastSimplex): governor_margin x speed_cap.
# governor_margin in {0.0,0.1,...,1.0} (0-100% in 10% steps - extended from
# the original 0-60% run; margin>1.0 isn't meaningful, it would use more of
# the found-safe candidate than was actually proven safe).
# speed_cap in {0.0,0.5,...,3.0} m/s (0-60% of the current 5.0 m/s
# model_speed_cap/abs_speed_cap default in vanilla_driver.yaml).
# 11 x 7 = 77 combinations x 2 tracks x 5 seeds = 770 cells. Resumable: the
# original 490 cells (margin 0.0-0.6) are already done and get skipped;
# only the new margin 0.7-1.0 cells (280 of them) actually run.
#
# Same resumability/retry/shm-cleanup design as run_full_eval.sh: a cell
# whose events.jsonl already has episode_end is skipped, a failing cell is
# retried once before being logged to failures.log and skipped.
#
# Usage: scripts/run_speedcap_sweep.sh   (no args; everything below is fixed)
set -uo pipefail
cd "$(dirname "$0")/.."

if [[ ! -x scripts/run_experiment.sh ]]; then
  echo "FATAL: scripts/run_experiment.sh not found (run from repo root)" >&2
  exit 1
fi

RESULTS_TAG=speedcap_govmargin_sweep_20260722
HOST_OUTPUT_DIR="f1tenth_drive/results/$RESULTS_TAG"
CONTAINER_OUTPUT_DIR="/ros_ws/results/$RESULTS_TAG"
TRACKING_DIR="f1tenth_drive/eval_tracking"
MANIFEST="$TRACKING_DIR/${RESULTS_TAG}_manifest.csv"
FAILURES_LOG="$TRACKING_DIR/${RESULTS_TAG}_failures.log"
DURATION=60
SEEDS=$(seq 1 5)
GRAND_TOTAL=770

TRACKS=(Austin BrandsHatch)
MODEL=delayed_3000000.pt
CKPT=3000000
ARCH=full
GOVERNOR_MARGINS=(0.0 0.1 0.2 0.3 0.4 0.5 0.6 0.7 0.8 0.9 1.0)
SPEED_CAPS=(0.0 0.5 1.0 1.5 2.0 2.5 3.0)

mkdir -p "$TRACKING_DIR" || { echo "FATAL: could not create $TRACKING_DIR" >&2; exit 1; }
if [[ ! -f $MANIFEST ]]; then
  echo "track,governor_margin,speed_cap,run_id,status,timestamp" > "$MANIFEST"
fi

manifest_row() {
  echo "$1,$2,$3,$4,$5,$(date -Iseconds)" >> "$MANIFEST"
}

is_complete() {
  local f="$HOST_OUTPUT_DIR/$1/events.jsonl"
  [[ -f $f ]] && grep -q 'episode_end' "$f"
}

# Same /dev/shm leak mitigation as run_full_eval.sh - see that script's
# comment for the full rationale (FastDDS shm segments leaked by SIGKILL'd
# participants, ipc:host means they land in the host's shared /dev/shm).
SHM_CLEANUP_EVERY=10
CELL_COUNT=0
cleanup_shm() {
  docker compose run --rm --no-deps --entrypoint bash drive -c \
    "find /dev/shm -maxdepth 1 -type f -user root -mmin +10 \
       \( -name 'fastrtps_*' -o -name 'sem.fastrtps_*' \) -delete" \
    >/dev/null 2>&1 || true
}

# run_cell TRACK GOV_MARGIN SPEED_CAP RUN_ID SEED
run_cell() {
  local track=$1 gov=$2 cap=$3 run_id=$4 seed=$5
  local exp="${ARCH}_${CKPT}_${track}_${run_id}"

  CELL_COUNT=$((CELL_COUNT + 1))
  if (( CELL_COUNT % SHM_CLEANUP_EVERY == 0 )); then
    echo "[shm-cleanup] after $CELL_COUNT cells"
    cleanup_shm
  fi

  if is_complete "$exp"; then
    echo "[skip] $exp (already complete)"
    manifest_row "$track" "$gov" "$cap" "$run_id" "skipped"
    return 0
  fi

  local attempt
  for attempt in 1 2; do
    echo "[run attempt $attempt] $exp (gov=$gov cap=$cap)"
    scripts/run_experiment.sh --arch "$ARCH" --track "$track" --model "$MODEL" \
      --checkpoint "$CKPT" --duration "$DURATION" --run-id "$run_id" \
      --seed "$seed" --output-dir "$CONTAINER_OUTPUT_DIR" \
      --governor-margin "$gov" --speed-cap "$cap"
    if is_complete "$exp"; then
      manifest_row "$track" "$gov" "$cap" "$run_id" "done"
      return 0
    fi
    echo "[warn] $exp attempt $attempt produced no episode_end"
  done

  echo "[FAIL] $exp failed after 2 attempts" | tee -a "$FAILURES_LOG"
  manifest_row "$track" "$gov" "$cap" "$run_id" "failed"
  return 1
}

TOTAL=0
for TRACK in "${TRACKS[@]}"; do
  echo "=================== track: $TRACK ==================="
  for gov in "${GOVERNOR_MARGINS[@]}"; do
    for cap in "${SPEED_CAPS[@]}"; do
      for seed in $SEEDS; do
        run_id=$(printf "gm%s_sc%s_s%02d" "$gov" "$cap" "$seed")
        run_cell "$TRACK" "$gov" "$cap" "$run_id" "$seed"
        TOTAL=$((TOTAL + 1))
        echo "[progress] $TOTAL/$GRAND_TOTAL cells attempted"
      done
    done
  done
done

echo "=================== sweep attempted: $TOTAL cells ==================="
echo "SWEEP_COMPLETE"
