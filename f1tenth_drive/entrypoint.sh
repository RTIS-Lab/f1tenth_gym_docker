#!/bin/bash
set -e

# Source ROS 2
source /opt/ros/humble/setup.bash

# Start SSH server in the background
echo "--- Starting SSH Server ---"
/usr/sbin/sshd -p 2222

# Build the workspace
echo "--- Building workspace at /ros_ws ---"
cd /ros_ws
colcon build

# Source the local workspace if it exists
if [ -f /ros_ws/install/setup.bash ]; then
  echo "--- Sourcing local workspace ---"
  source /ros_ws/install/setup.bash
fi

# Execute the command passed to the script
exec "$@"
