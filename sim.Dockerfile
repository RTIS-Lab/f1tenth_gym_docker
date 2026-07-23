ARG BASE_IMAGE_TAG=latest
FROM f1tenth-base:${BASE_IMAGE_TAG}

ARG DEBIAN_FRONTEND=noninteractive

# gym==0.19.0 (pinned by f1tenth_gym) breaks with modern setuptools.
# Install a compatible version first, then install f1tenth_gym skipping its broken pin.
RUN --mount=type=cache,target=/root/.cache uv pip install 'gym==0.25.2'
RUN git clone https://github.com/f1tenth/f1tenth_gym /f1tenth_gym && \
    uv pip install -e /f1tenth_gym --no-deps

RUN --mount=type=cache,target=/root/.cache uv pip install \
    transforms3d \
    pyglet \
    pyopengl \
    numba \
    pillow

# virtual display + VNC server, so rviz can be viewed without X11 forwarding
# (useful when SSH X11Forwarding is disabled / the client has no X server).
# xauth is needed to cookie-protect the virtual display: /tmp/.X11-unix is
# bind-mounted from the host, so on a shared machine an unauthenticated
# display would be reachable by any other local user.
RUN --mount=target=/var/lib/apt/lists,type=cache,sharing=private \
    --mount=target=/var/cache/apt,type=cache,sharing=private \
    apt-get update && apt-get install -y xvfb x11vnc xauth

# Create workspace structure
RUN mkdir -p /sim_ws/src/f1tenth_gym_ros
WORKDIR /sim_ws

# Copy package.xml ahead of the volume mount so rosdep can resolve deps at build time
COPY f1tenth_gym_ros/package.xml src/f1tenth_gym_ros/package.xml

RUN --mount=target=/var/lib/apt/lists,type=cache,sharing=private \
    --mount=target=/var/cache/apt,type=cache,sharing=private \
    apt-get update && \
    source /opt/ros/humble/setup.bash && \
    rosdep install -i --from-path src --rosdistro humble -y \
        --skip-keys 'python-transforms3d-pip'

COPY sim_entrypoint.sh /sim_entrypoint.sh
RUN chmod +x /sim_entrypoint.sh

ENTRYPOINT ["/sim_entrypoint.sh"]
CMD ["ros2", "launch", "f1tenth_gym_ros", "gym_bridge_launch.py"]
