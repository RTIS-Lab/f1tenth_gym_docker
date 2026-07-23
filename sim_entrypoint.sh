#!/bin/bash
set -e

source /opt/ros/humble/setup.bash

if [ "${VNC_ENABLED:-0}" = "1" ]; then
    # /tmp/.X11-unix is bind-mounted from the (possibly shared, multi-user)
    # host, so other real X sessions may already occupy low display numbers
    # (e.g. :0, :1). Find a free one instead of assuming; never touch an
    # existing socket, it may belong to another user's live session.
    DISPNUM=50
    while [ -e "/tmp/.X11-unix/X${DISPNUM}" ] || [ -e "/tmp/.X${DISPNUM}-lock" ]; do
        DISPNUM=$((DISPNUM + 1))
    done
    echo "--- Starting virtual display :${DISPNUM} + VNC server on :5901 ---"
    export DISPLAY=":${DISPNUM}"
    # cookie-protect the display: since the socket dir is shared with the
    # host, other local users could otherwise reach this X server
    export XAUTHORITY=/tmp/.xvfb_sim_${DISPNUM}.xauth
    touch "$XAUTHORITY"
    MCOOKIE=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')
    xauth -f "$XAUTHORITY" add ":${DISPNUM}" . "$MCOOKIE"
    Xvfb ":${DISPNUM}" -auth "$XAUTHORITY" -screen 0 1280x800x24 -nolisten tcp &
    for i in $(seq 1 20); do
        [ -e "/tmp/.X11-unix/X${DISPNUM}" ] && break
        sleep 0.5
    done
    if [ -z "$VNC_PASSWORD" ]; then
        VNC_PASSWORD=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 12)
        echo "--- Generated VNC password (not saved anywhere else): $VNC_PASSWORD ---"
    fi
    x11vnc -display ":${DISPNUM}" -auth "$XAUTHORITY" -forever -shared \
        -localhost -rfbport 5901 -passwd "$VNC_PASSWORD" -bg -o /tmp/x11vnc.log
fi

echo "--- Building sim workspace ---"
cd /sim_ws
colcon build

if [ -f /sim_ws/install/setup.bash ]; then
    source /sim_ws/install/setup.bash
fi

exec "$@"
