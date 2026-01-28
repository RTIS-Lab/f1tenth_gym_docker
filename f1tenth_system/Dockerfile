# MIT License

# Copyright (c) 2020 Hongrui Zheng

# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:

# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.

# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

ARG BASE_IMAGE_TAG=latest
FROM f1tenth-base:${BASE_IMAGE_TAG}

WORKDIR /ros_ws

# Copy package.xml files for dependency caching
COPY src/f1tenth_system/vesc/vesc_driver/package.xml src/f1tenth_system/vesc/vesc_driver/package.xml
COPY src/f1tenth_system/vesc/vesc_msgs/package.xml src/f1tenth_system/vesc/vesc_msgs/package.xml
COPY src/f1tenth_system/vesc/vesc_ackermann/package.xml src/f1tenth_system/vesc/vesc_ackermann/package.xml
COPY src/f1tenth_system/vesc/vesc/package.xml src/f1tenth_system/vesc/vesc/package.xml
COPY src/f1tenth_system/f1tenth_stack/package.xml src/f1tenth_system/f1tenth_stack/package.xml

# Install ROS dependencies for this specific service
RUN --mount=target=/var/lib/apt/lists,type=cache,sharing=private \
    --mount=target=/var/cache/apt,type=cache,sharing=private \
    apt-get update && \
    source /opt/ros/humble/setup.bash && \
    rosdep install -i --from-path src --rosdistro humble -y

# Copy application code
COPY . .

# Install Python dependencies for this service using uv
RUN --mount=type=cache,target=/root/.cache uv pip install gym numpy scipy numba pyglet pyopengl

# The entrypoint script will build, source, and then execute the CMD
ENTRYPOINT ["/ros_ws/entrypoint.sh"]
CMD ["ros2", "launch", "f1tenth_stack", "bringup_launch.py"]
