#!/usr/bin/env bash
# Run one evaluation episode: pick a start pose, (re)start the simulator,
# run the RL driver + the chosen safety architecture for a fixed duration,
# and leave a streaming event log in f1tenth_drive/results/<experiment>/.
#
# Usage:
#   scripts/run_experiment.sh --arch full --track levine \
#       --model step_1000000_delayed.pt --duration 60 [--seed 1] [--run-id r1]
#
# Architectures: full | no_early_stop | fb_only | mpc_only | rl_only |
#                classic | anytime
#
# Extra flags for sweeps: --output-dir DIR (default /ros_ws/results),
# --governor-margin VALUE, --no-governor, --speed-cap VALUE (m/s, overrides
# both model_speed_cap and abs_speed_cap on the rl_driver).
set -euo pipefail
cd "$(dirname "$0")/.."

ARCH=full
TRACK=levine
MODEL=step_1000000_delayed.pt
CKPT=""
DURATION=60
RUN_ID=""
SEED=""
ANYTIME_BUDGET=40
RESPAWN=1
OUTPUT_DIR=/ros_ws/results
GOVERNOR_MARGIN=""
NO_GOVERNOR=0
SPEED_CAP=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --arch) ARCH=$2; shift 2;;
    --track) TRACK=$2; shift 2;;
    --model) MODEL=$2; shift 2;;
    --checkpoint) CKPT=$2; shift 2;;
    --duration) DURATION=$2; shift 2;;
    --run-id) RUN_ID=$2; shift 2;;
    --seed) SEED=$2; shift 2;;
    --anytime-budget-ms) ANYTIME_BUDGET=$2; shift 2;;
    --no-respawn) RESPAWN=0; shift;;
    --output-dir) OUTPUT_DIR=$2; shift 2;;
    --governor-margin) GOVERNOR_MARGIN=$2; shift 2;;
    --no-governor) NO_GOVERNOR=1; shift;;
    --speed-cap) SPEED_CAP=$2; shift 2;;
    *) echo "unknown option: $1" >&2; exit 1;;
  esac
done

CKPT=${CKPT:-$(echo "$MODEL" | grep -o '[0-9]\+' | head -1)}
RUN_ID=${RUN_ID:-$(date +%Y%m%d_%H%M%S)}
EXP="${ARCH}_${CKPT}_${TRACK}_${RUN_ID}"

echo "=== experiment: $EXP (duration ${DURATION}s) ==="

docker compose up -d discovery

# classic simplex needs the precomputed recoverable-region table
if [[ $ARCH == classic ]]; then
  docker compose run --rm --no-deps --entrypoint bash drive -c \
    "source /opt/ros/humble/setup.bash && source /ros_ws/install/setup.bash && \
     test -f /ros_ws/eval_data/classic_simplex_bounds.csv || \
     ros2 run rtis_safety classic_simplex_precompute \
       /ros_ws/eval_data/classic_simplex_bounds.csv 4.0 6.0"
fi

# pick a valid start pose and patch it (plus the map) into sim.yaml
PLACE_ARGS=(--track "$TRACK"
            --write-config /sim_ws/src/f1tenth_gym_ros/config/sim.yaml)
[[ -n $SEED ]] && PLACE_ARGS+=(--seed "$SEED")
docker compose run --rm --no-deps --entrypoint bash sim -c \
  "python3 /sim_ws/src/f1tenth_gym_ros/scripts/place_car.py ${PLACE_ARGS[*]}"

# (re)start the simulator so it picks up the new config.
# VNC_ENABLED=1 implies you want to see rviz, so default headless off in
# that case unless the caller explicitly set SIM_HEADLESS themselves.
if [[ "${VNC_ENABLED:-0}" == 1 && -z "${SIM_HEADLESS+x}" ]]; then
  SIM_HEADLESS=0
fi
SIM_HEADLESS=${SIM_HEADLESS:-1} VNC_ENABLED=${VNC_ENABLED:-0} \
  docker compose up -d --force-recreate sim
echo "waiting for the simulator to build and come up..."
sleep 30

# crash-respawn monitor keeps episodes going after a collision
if [[ $RESPAWN == 1 ]]; then
  docker compose exec sim bash -c "pkill -f place_car.py || true" || true
  docker compose exec -d sim bash -c \
    "source /opt/ros/humble/setup.bash && \
     python3 /sim_ws/src/f1tenth_gym_ros/scripts/place_car.py \
       --track $TRACK ${SEED:+--seed $SEED} --respawn" || true
fi

# run the drive stack for the requested duration
GOVERNOR_ARGS=""
[[ -n $GOVERNOR_MARGIN ]] && GOVERNOR_ARGS+=" -p governor_margin:=${GOVERNOR_MARGIN}"
[[ $NO_GOVERNOR == 1 ]] && GOVERNOR_ARGS+=" -p governor_enabled:=false"

SPEEDCAP_ARGS=""
[[ -n $SPEED_CAP ]] && SPEEDCAP_ARGS+=" -p model_speed_cap:=${SPEED_CAP} -p abs_speed_cap:=${SPEED_CAP}"

docker compose run --rm --no-deps --entrypoint bash drive -c "
  source /opt/ros/humble/setup.bash && source /ros_ws/install/setup.bash
  ros2 run kw_f110_drive visible_area_node & VIS=\$!
  ros2 run rtis_f110_rl rl_driver --ros-args \
    --params-file /ros_ws/src/rtis_f110_rl/config/vanilla_driver.yaml \
    -p model_path:=$MODEL -p verbose:=0$SPEEDCAP_ARGS & RL=\$!
  sleep 3
  timeout --signal=INT --kill-after=45 ${DURATION}s \
    ros2 run rtis_safety rtis_safety_runner --ros-args \
      -p architecture:=$ARCH \
      -p experiment_name:=$EXP \
      -p output_dir:=$OUTPUT_DIR \
      -p track:=$TRACK \
      -p model_checkpoint:=$CKPT \
      -p model_file:=$MODEL \
      -p run_id:=$RUN_ID \
      -p classic_bounds_file:=/ros_ws/eval_data/classic_simplex_bounds.csv \
      -p anytime_budget_ms:=${ANYTIME_BUDGET}.0$GOVERNOR_ARGS || true
  kill -INT \$VIS \$RL 2>/dev/null || true
  sleep 1
  kill -9 \$VIS \$RL 2>/dev/null || true
"

if [[ $RESPAWN == 1 ]]; then
  docker compose exec sim bash -c "pkill -f place_car.py || true" || true
fi

echo "=== done: f1tenth_drive${OUTPUT_DIR#/ros_ws}/$EXP/events.jsonl ==="
