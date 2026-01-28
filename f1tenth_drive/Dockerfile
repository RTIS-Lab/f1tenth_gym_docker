ARG BASE_IMAGE_TAG=latest
FROM f1tenth-base:${BASE_IMAGE_TAG}

# Install extra dependencies for the 'driver' service
ARG DEBIAN_FRONTEND=noninteractive
RUN --mount=target=/var/lib/apt/lists,type=cache,sharing=private \
    --mount=target=/var/cache/apt,type=cache,sharing=private \
    apt-get update --fix-missing && \
    apt-get install -y \
        coinor-libipopt-dev \
        libboost-all-dev \
        clang-15 \
        clangd-15 \
        ninja-build \
        ccache \
        libjsoncpp-dev \
        libgfortran5 \
        valgrind \
        openssh-server && \
    apt-get -y dist-upgrade

# SSH server setup
RUN mkdir -p /var/run/sshd && \
    echo 'root:password' | chpasswd && \
    sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config && \
    sed -i 's@session\s*required\s*pam_loginuid.so@session optional pam_loginuid.so@g' /etc/pam.d/sshd && \
    sed -i 's/^#?Port\s+22/Port 2222/' /etc/ssh/sshd_config

# clang setup
RUN update-alternatives --install /usr/bin/clang clang /usr/bin/clang-15 15 && \
    update-alternatives --install /usr/bin/clang++ clang++ /usr/bin/clang++-15 15

WORKDIR /ros_ws

# Copy package.xml files for dependency caching
COPY src/kw_f110_drive/kw_f110_drive/package.xml src/kw_f110_drive/kw_f110_drive/package.xml
COPY src/kw_f110_drive/kw_f110_msgs/package.xml src/kw_f110_drive/kw_f110_msgs/package.xml
COPY src/rtis_f110_rl/package.xml src/rtis_f110_rl/package.xml
COPY src/rtis_safety/package.xml src/rtis_safety/package.xml
COPY src/ros_preempt/simple_timer/package.xml src/ros_preempt/simple_timer/package.xml
COPY src/ros_preempt/preempt_executor/package.xml src/ros_preempt/preempt_executor/package.xml

# Install ROS dependencies
RUN --mount=target=/var/lib/apt/lists,type=cache,sharing=private \
    --mount=target=/var/cache/apt,type=cache,sharing=private \
    apt-get update && \
    source /opt/ros/humble/setup.bash && \
    rosdep install -i --from-path src --rosdistro humble -y --skip-keys nlopt

# Copy application code
COPY . .

# Python dependencies
RUN --mount=type=cache,target=/root/.cache uv pip install transforms3d cython==0.29.37 numba torch

# range_libc
RUN cd /ros_ws/lib/range_libc/pywrapper && \
    uv pip install . --no-build-isolation

# if libgfortran.so.5 exists, symlink it
RUN if [ -f /usr/lib/aarch64-linux-gnu/libgfortran.so.5 ]; then \
        ln -sf /usr/lib/aarch64-linux-gnu/libgfortran.so.5  /usr/lib/aarch64-linux-gnu/libgfortran-e1b7dfc8.so.5.0.0 ; \
    fi

# Add workspace to bashrc
RUN echo "export LD_LIBRARY_PATH=/ros_ws/lib/libtorch/lib/:\$LD_LIBRARY_PATH" >> /root/.bashrc

RUN echo "export FASTRTPS_DEFAULT_PROFILES_FILE=discovery_settings.xml" >> /root/.bashrc


# The entrypoint script will build, source, and then execute the CMD
ENTRYPOINT ["/ros_ws/entrypoint.sh"]
CMD ["ros2", "run", "kw_f110_drive", "teleop"]
