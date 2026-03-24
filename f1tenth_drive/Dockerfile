FROM ros:humble

SHELL ["/bin/bash", "-c"]
ENV PIP_BREAK_SYSTEM_PACKAGES=1
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/
RUN uv venv /opt/venv
# Use the virtual environment automatically
ENV VIRTUAL_ENV=/opt/venv
# Place entry points in the environment at the front of the path
ENV PATH="/opt/venv/bin:$PATH"

# dependencies
ARG DEBIAN_FRONTEND=noninteractive
RUN rm -f /etc/apt/apt.conf.d/docker-clean; echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' > /etc/apt/apt.conf.d/keep-cache
RUN --mount=target=/var/lib/apt/lists,type=cache,sharing=private \
    --mount=target=/var/cache/apt,type=cache,sharing=private \
    apt-get update --fix-missing && \
    apt-get install -y git \
                       nano \
                       vim \
                       python3-pip \
                       python3-scipy \
                       libeigen3-dev \
                       tmux \
                       ros-humble-rviz2 \
                       ros-humble-tf-transformations \
                       ros-humble-ackermann-msgs \
                       coinor-libipopt-dev \
                       libboost-all-dev \
                       clang-15 \
                       clangd-15 \
                       ninja-build \
                       ccache \
                       libjsoncpp-dev \
                       libgfortran5
                       #nvidia-cudnn \
                       #nvidia-cuda-dev


    # valgrind
RUN ulimit -n 1024
RUN --mount=target=/var/lib/apt/lists,type=cache,sharing=private \
    --mount=target=/var/cache/apt,type=cache,sharing=private \
    apt-get update --fix-missing && \
    apt-get install -y valgrind \
                       openssh-server

RUN apt-get -y dist-upgrade

# SSH server setup
RUN mkdir -p /var/run/sshd
RUN echo 'root:password' | chpasswd
RUN sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config
# SSH login fix. Otherwise user is kicked off after login
RUN sed -i 's@session\s*required\s*pam_loginuid.so@session optional pam_loginuid.so@g' /etc/pam.d/sshd
RUN sed -i 's/^#?Port\s+22/Port 2222/' /etc/ssh/sshd_config


RUN mkdir -p /f1tenth_drive/src/kw_f110_drive/
RUN mkdir -p /f1tenth_drive/src/kw_f110_drive/kw_f110_msgs/
RUN mkdir -p /f1tenth_drive/src/kw_f110_drive/kw_f110_drive/

COPY ./src/kw_f110_drive/kw_f110_msgs/package.xml /f1tenth_drive/src/kw_f110_drive/kw_f110_msgs/
COPY ./src/kw_f110_drive/kw_f110_drive/package.xml /f1tenth_drive/src/kw_f110_drive/kw_f110_drive/

# ros package dependencies
RUN --mount=target=/var/lib/apt/lists,type=cache,sharing=private \
    --mount=target=/var/cache/apt,type=cache,sharing=private \
    source /opt/ros/humble/setup.bash && \
        cd /f1tenth_drive && \
        rosdep install -i --from-path src --rosdistro humble -y

# setuptools: https://github.com/ros2/ros2/issues/1702
RUN --mount=type=cache,target=/root/.cache uv pip install transforms3d cython==0.29.37 numba setuptools==79.0.1 empy==3.3.4 colcon-common-extensions lark opencv-python scipy colcon-mixin

# range_libc
COPY lib/ /f1tenth_drive/lib/
# RUN cd /f1tenth_drive/lib/range_libc/pywrapper && \
#     python3 setup.py install

RUN cd /f1tenth_drive/lib/range_libc/pywrapper && \
    uv pip install . --no-build-isolation

# if libgfortran.so.5 exists, symlink it
RUN if [ -f /usr/lib/aarch64-linux-gnu/libgfortran.so.5 ]; then \
        ln -sf /usr/lib/aarch64-linux-gnu/libgfortran.so.5  /usr/lib/aarch64-linux-gnu/libgfortran-8a9a71bc.so.5.0.0 ; \
    fi

# copy the rest
COPY . /f1tenth_drive

# clang setup
RUN update-alternatives --install /usr/bin/clang clang /usr/bin/clang-15 15
RUN update-alternatives --install /usr/bin/clang++ clang++ /usr/bin/clang++-15 15


# build
RUN source /opt/ros/humble/setup.bash && \
    cd /f1tenth_drive && \
    colcon build

WORKDIR '/f1tenth_drive'
# our SSH session won't inherit the ENV values above?
RUN echo "export PATH=/opt/venv/bin:$PATH" >> ~/.bashrc
RUN echo "export VIRTUAL_ENV=/opt/venv" >> ~/.bashrc
RUN echo "export RCUTILS_COLORIZED_OUTPUT=1"  >> ~/.bashrc

RUN echo "export LD_LIBRARY_PATH=\"/f1tenth_drive/lib/libtorch/lib/\"" >> ~/.bashrc

RUN echo "source /f1tenth_drive/setrmw.sh" >> ~/.bashrc
RUN echo "source /opt/ros/humble/setup.bash" >> ~/.bashrc
RUN echo "source /f1tenth_drive/install/setup.bash" >> ~/.bashrc

# Start SSH server and ROS application
ENTRYPOINT ["bash", "-c", "service ssh start && source /f1tenth_drive/install/setup.bash && source /f1tenth_drive/setrmw.sh && ros2 run kw_f110_drive teleop"]
