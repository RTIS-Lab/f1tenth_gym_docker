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
                       ros-foxy-rviz2 \
                       ros-foxy-tf-transformations \
                       coinor-libipopt-dev \
                       cppad

# valgrind
RUN ulimit -n 1024
RUN --mount=target=/var/lib/apt/lists,type=cache,sharing=private \
    --mount=target=/var/cache/apt,type=cache,sharing=private \
    apt-get update --fix-missing && \
    apt-get install -y valgrind

RUN apt-get -y dist-upgrade
RUN --mount=type=cache,target=/root/.cache pip3 install transforms3d cython

RUN mkdir -p /f1tenth_drive/src/kw_f110_drive/
RUN mkdir -p /f1tenth_drive/src/kw_f110_drive/kw_f110_msgs/
RUN mkdir -p /f1tenth_drive/src/kw_f110_drive/kw_f110_drive/

COPY ./src/kw_f110_drive/kw_f110_msgs/package.xml /f1tenth_drive/src/kw_f110_drive/kw_f110_msgs/
COPY ./src/kw_f110_drive/kw_f110_drive/package.xml /f1tenth_drive/src/kw_f110_drive/kw_f110_drive/

# ros package dependencies
RUN --mount=target=/var/lib/apt/lists,type=cache,sharing=private \
    --mount=target=/var/cache/apt,type=cache,sharing=private \
    source /opt/ros/foxy/setup.bash && \
        cd /f1tenth_drive && \
        rosdep install -i --from-path src --rosdistro foxy -y

# range_libc
COPY lib/ /f1tenth_drive/lib/
RUN cd /f1tenth_drive/lib/range_libc/pywrapper && \
    python3 setup.py install


# copy the rest
COPY . /f1tenth_drive

# build
RUN source /opt/ros/foxy/setup.bash && \
    cd /f1tenth_drive && \
    colcon build --symlink-install

WORKDIR '/f1tenth_drive'
RUN echo "source /opt/ros/foxy/setup.bash" >> ~/.bashrc
RUN echo "source /f1tenth_drive/install/setup.bash" >> ~/.bashrc

ENTRYPOINT ["bash", "-c", "source /f1tenth_drive/install/setup.bash && ros2 run kw_f110_drive teleop"]

