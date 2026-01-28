# Base image for F1TENTH ROS2 development
FROM ros:humble

SHELL ["/bin/bash", "-c"]
ENV PIP_BREAK_SYSTEM_PACKAGES=1

# Install uv for python package management
# Using uv from astral is a good practice for python venvs.
COPY --from=ghcr.io/astral-sh/uv:0.9.26 /uv /uvx /bin/
RUN uv venv /opt/venv
# Use the virtual environment automatically
ENV VIRTUAL_ENV=/opt/venv
# Place entry points in the environment at the front of the path
ENV PATH="/opt/venv/bin:$PATH"

# Basic dependencies and tools from both services
ARG DEBIAN_FRONTEND=noninteractive
RUN rm -f /etc/apt/apt.conf.d/docker-clean; echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' > /etc/apt/apt.conf.d/keep-cache
RUN --mount=target=/var/lib/apt/lists,type=cache,sharing=private \
    --mount=target=/var/cache/apt,type=cache,sharing=private \
    apt-get update --fix-missing && \
    apt-get install -y \
        git \
        nano \
        vim \
        python3-pip \
        python3-scipy \
        libeigen3-dev \
        tmux \
        ros-humble-rosbridge-suite \
        ros-humble-rviz2 \
        ros-humble-tf-transformations \
        ros-humble-ackermann-msgs \
        ros-humble-urg-node \
        ros-humble-asio-cmake-module \
        ros-humble-joy \
        x11-xserver-utils \
        libasio-dev \
    && apt-get dist-upgrade -y

# Install common python tools.
# The original files had some of these, consolidating here.
RUN --mount=type=cache,target=/root/.cache uv pip install \
    setuptools==79.0.1 \
    empy==3.3.4 \
    colcon-common-extensions \
    colcon-mixin \
    lark \
    opencv-python \
    scipy

# Source ROS setup automatically in bash
RUN echo "source /opt/ros/humble/setup.bash" >> ~/.bashrc
# Add venv and other useful env vars to bashrc for interactive sessions
RUN echo "export PATH=/opt/venv/bin:$PATH" >> ~/.bashrc
RUN echo "export VIRTUAL_ENV=/opt/venv" >> ~/.bashrc
RUN echo "export RCUTILS_COLORIZED_OUTPUT=1"  >> ~/.bashrc
RUN echo 'if [ -f /ros_ws/install/setup.bash ]; then source /ros_ws/install/setup.bash; fi' >> ~/.bashrc
