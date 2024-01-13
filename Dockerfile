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

FROM ros:foxy

SHELL ["/bin/bash", "-c"]

# dependencies
RUN rm -f /etc/apt/apt.conf.d/docker-clean; echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' > /etc/apt/apt.conf.d/keep-cache
RUN --mount=target=/var/lib/apt/lists,type=cache,sharing=private \
    --mount=target=/var/cache/apt,type=cache,sharing=private \
    apt-get update --fix-missing && \
    apt-get install -y git \
                       nano \
                       vim \
                       python3-pip \
                       libeigen3-dev \
                       tmux \
    ros-foxy-rosbridge-suite \
    ros-foxy-rviz2 \
    x11-xserver-utils \
    && apt-get dist-upgrade -y

RUN --mount=type=cache,target=/root/.cache pip3 install transforms3d

# f1tenth gym
# RUN git clone https://github.com/f1tenth/f1tenth_gym
RUN mkdir -p /f1tenth_gym
COPY f1tenth_gym f1tenth_gym
RUN --mount=type=cache,target=/root/.cache cd f1tenth_gym && \
    pip3 install -e .

# ros2 gym bridge
RUN mkdir -p sim_ws/src/f1tenth_gym_ros
COPY ./package.xml /sim_ws/src/f1tenth_gym_ros/
RUN --mount=target=/var/lib/apt/lists,type=cache,sharing=private \
    --mount=target=/var/cache/apt,type=cache,sharing=private \
    source /opt/ros/foxy/setup.bash && \
    cd sim_ws/ && \
    rosdep install -i --from-path src --rosdistro foxy -y

COPY . /sim_ws/src/f1tenth_gym_ros
RUN rm /sim_ws/src/f1tenth_gym_ros/wait_for_x.bash

RUN source /opt/ros/foxy/setup.bash && \
    cd sim_ws/ && \
    colcon build

COPY wait_for_x.bash /sim_ws/wait_for_x.bash

WORKDIR '/sim_ws'
# ENTRYPOINT ["/bin/bash"]
# run the gym bridge instead

# source the workspace and run the bridge
ENTRYPOINT ["bash", "-c", "source /sim_ws/install/setup.bash && ros2 launch f1tenth_gym_ros gym_bridge_launch.py"]
