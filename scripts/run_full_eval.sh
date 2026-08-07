#!/usr/bin/env bash
# Full evaluation sweep for the FastSimplex paper: >=30 trials/condition
# across architectures x checkpoints x tracks (blocks A/B), plus a 3-arm
# speed-governor ablation (block C). See RESULTS.md for the methodology
# this produces data for, and the plan this implements.
#
# Every cell does a full sim restart (scripts/run_experiment.sh's normal,
# already-validated behavior) - an earlier version of this script tried to
# reuse one sim instance across a whole track's trials to save time, but
# testing found f1tenth_gym_ros doesn't cleanly reset velocity/ROS-graph
# state across a reused sim instance, which would have silently
# contaminated trial independence. Not worth the risk for a paper dataset.
#
# Resumable: a cell whose events.jsonl already has an episode_end is
# skipped, so re-running this script after any interruption picks up where
# it left off instead of redoing completed work. A cell that fails is
# retried once before being logged to failures.log and skipped - one bad
# cell never aborts the sweep.
#
# Meant to be run detached so it survives an SSH disconnect, e.g.:
#   setsid nohup bash scripts/run_full_eval.sh \
#     > f1tenth_drive/eval_tracking/full_eval_20260717_driver.log 2>&1 < /dev/null &
#   disown
#
# Usage: scripts/run_full_eval.sh   (no args; everything below is fixed)
set -uo pipefail
cd "$(dirname "$0")/.."

if [[ ! -x scripts/run_experiment.sh ]]; then
  echo "FATAL: scripts/run_experiment.sh not found (run from repo root)" >&2
  exit 1
fi

RESULTS_TAG=full_eval_20260720_mpcfix
HOST_OUTPUT_DIR="f1tenth_drive/results/$RESULTS_TAG"
CONTAINER_OUTPUT_DIR="/ros_ws/results/$RESULTS_TAG"
# f1tenth_drive/results/ is root-owned (populated by containers running as
# root), so the manifest/failures log - which this host-side script needs
# to write directly - live in a host-writable tracking dir instead. The
# per-trial results directories under HOST_OUTPUT_DIR still get created
# fine by the containers themselves; nothing here needs to mkdir there.
TRACKING_DIR="f1tenth_drive/eval_tracking"
MANIFEST="$TRACKING_DIR/${RESULTS_TAG}_manifest.csv"
FAILURES_LOG="$TRACKING_DIR/${RESULTS_TAG}_failures.log"
DURATION=60
SEEDS=$(seq 1 30)
GRAND_TOTAL=1680

TRACKS=(Austin BrandsHatch kurtmap0 kurtmap1)
GOVERNOR_TRACKS=(Austin BrandsHatch)
CKPT_LABELS=(400000 700000 1400000 3000000)
CKPT_MODELS=(delayed_400000.pt delayed_700000.pt delayed_1400000.pt delayed_3000000.pt)
BLOCK_A_ARCHS=(rl_only full)
BLOCK_B_ARCHS=(fb_only mpc_only classic anytime no_early_stop)
BEST_CKPT=3000000
BEST_MODEL=delayed_3000000.pt

mkdir -p "$TRACKING_DIR" || { echo "FATAL: could not create $TRACKING_DIR" >&2; exit 1; }
if [[ ! -f $MANIFEST ]]; then
  echo "track,arch,checkpoint,governor_arm,run_id,status,timestamp" > "$MANIFEST"
fi

manifest_row() {
  echo "$1,$2,$3,$4,$5,$6,$(date -Iseconds)" >> "$MANIFEST"
}

is_complete() {
  local f="$HOST_OUTPUT_DIR/$1/events.jsonl"
  [[ -f $f ]] && grep -q 'episode_end' "$f"
}

# FastDDS leaves shared-memory segment files in /dev/shm when a participant
# doesn't shut down gracefully (SIGKILL from run_experiment.sh's
# --kill-after, or a crash) - because drive/sim run with `ipc: host`, these
# land in the HOST's shared /dev/shm and accumulate across the sweep's
# ~1680 container churns. Left unchecked this degrades DDS discovery badly
# enough to cascade into near-100% trial failure (observed empirically:
# ~130 cells into the first attempt at this sweep, /dev/shm had 4000+
# leaked files and every subsequent trial failed). Only ever deletes
# root-owned files >10 min old, so it can't touch another user's shared
# memory on this host, or anything the long-lived discovery/sim containers
# are still actively using (their own segment files are read continuously,
# not by mtime).
SHM_CLEANUP_EVERY=10
CELL_COUNT=0
cleanup_shm() {
  docker compose run --rm --no-deps --entrypoint bash drive -c \
    "find /dev/shm -maxdepth 1 -type f -user root -mmin +10 \
       \( -name 'fastrtps_*' -o -name 'sem.fastrtps_*' \) -delete" \
    >/dev/null 2>&1 || true
}

# run_cell ARCH CKPT MODEL TRACK RUN_ID SEED [EXTRA run_experiment.sh ARGS...]
# Reads the global GOVERNOR_ARM (for the manifest row only).
run_cell() {
  local arch=$1 ckpt=$2 model=$3 track=$4 run_id=$5 seed=$6
  shift 6
  local extra_args=("$@")
  local exp="${arch}_${ckpt}_${track}_${run_id}"

  CELL_COUNT=$((CELL_COUNT + 1))
  if (( CELL_COUNT % SHM_CLEANUP_EVERY == 0 )); then
    echo "[shm-cleanup] after $CELL_COUNT cells"
    cleanup_shm
  fi

  if is_complete "$exp"; then
    echo "[skip] $exp (already complete)"
    manifest_row "$track" "$arch" "$ckpt" "$GOVERNOR_ARM" "$run_id" "skipped"
    return 0
  fi

  local attempt
  for attempt in 1 2; do
    echo "[run attempt $attempt] $exp"
    scripts/run_experiment.sh --arch "$arch" --track "$track" --model "$model" \
      --checkpoint "$ckpt" --duration "$DURATION" --run-id "$run_id" \
      --seed "$seed" --output-dir "$CONTAINER_OUTPUT_DIR" \
      "${extra_args[@]}"
    if is_complete "$exp"; then
      manifest_row "$track" "$arch" "$ckpt" "$GOVERNOR_ARM" "$run_id" "done"
      return 0
    fi
    echo "[warn] $exp attempt $attempt produced no episode_end"
  done

  echo "[FAIL] $exp failed after 2 attempts" | tee -a "$FAILURES_LOG"
  manifest_row "$track" "$arch" "$ckpt" "$GOVERNOR_ARM" "$run_id" "failed"
  return 1
}

TOTAL=0
for TRACK in "${TRACKS[@]}"; do
  echo "=================== track: $TRACK ==================="
  GOVERNOR_ARM=default

  # Block A: rl_only + full swept across all 4 checkpoints (progression story)
  for arch in "${BLOCK_A_ARCHS[@]}"; do
    for i in "${!CKPT_LABELS[@]}"; do
      ckpt=${CKPT_LABELS[$i]}
      model=${CKPT_MODELS[$i]}
      for seed in $SEEDS; do
        run_id=$(printf "s%02d" "$seed")
        run_cell "$arch" "$ckpt" "$model" "$TRACK" "$run_id" "$seed"
        TOTAL=$((TOTAL + 1))
        echo "[progress] $TOTAL/$GRAND_TOTAL cells attempted"
      done
    done
  done

  # Block B: single-checker / baseline architectures at the best checkpoint
  for arch in "${BLOCK_B_ARCHS[@]}"; do
    for seed in $SEEDS; do
      run_id=$(printf "s%02d" "$seed")
      run_cell "$arch" "$BEST_CKPT" "$BEST_MODEL" "$TRACK" "$run_id" "$seed"
      TOTAL=$((TOTAL + 1))
      echo "[progress] $TOTAL/$GRAND_TOTAL cells attempted"
    done
  done

  # Block C: governor ablation extra arms (margin=0.6 default is block A's
  # full/3M rows above, reused rather than re-run) - Austin/BrandsHatch only
  if [[ " ${GOVERNOR_TRACKS[*]} " == *" $TRACK "* ]]; then
    GOVERNOR_ARM=off
    for seed in $SEEDS; do
      run_id=$(printf "gov-off-s%02d" "$seed")
      run_cell full "$BEST_CKPT" "$BEST_MODEL" "$TRACK" "$run_id" "$seed" --no-governor
      TOTAL=$((TOTAL + 1))
      echo "[progress] $TOTAL/$GRAND_TOTAL cells attempted"
    done
    GOVERNOR_ARM=nomargin
    for seed in $SEEDS; do
      run_id=$(printf "gov-nomargin-s%02d" "$seed")
      run_cell full "$BEST_CKPT" "$BEST_MODEL" "$TRACK" "$run_id" "$seed" --governor-margin 1.0
      TOTAL=$((TOTAL + 1))
      echo "[progress] $TOTAL/$GRAND_TOTAL cells attempted"
    done
    GOVERNOR_ARM=default
  fi
done

echo "=================== sweep attempted: $TOTAL cells ==================="
echo "SWEEP_COMPLETE"
