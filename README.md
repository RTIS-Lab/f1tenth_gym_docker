# FastSimplex development and evaluation repo
The structure of this repo is based off of https://github.com/RTIS-Lab/f1tenth_gym_docker. Uses ROS2 Humble

Extra assets are at https://nextcloud.kurtw.dev/s/nJAGi3GRtenoi4W
Put `extra_libs.zip` into `f1tenth_drive/lib`, and `extra_maps.zip` into `f1tenth_gym_ros/maps`

## Running
in short:
* docker compose up

Both have `colcon build` run at image build time, but you can also re-run yourself at runtime.

### SSH access
The driver container has an ssh server (forwarded to port 2222 in `docker-compose.yml`), with the username `root` and password `password`. You can ssh into the container with `ssh root@localhost -p 2222` to run commands in the container, or you can use `docker compose exec driver bash` to get a bash shell in the container.

You can also connect with any IDE that supports remote development over ssh - this really helps with syntax highlighting, debugging, etc.

### Display access
On a Linux desktop with X11 or xwayland, allow the container to access the display with `xhost local:docker`.
> I've tested this on a laptop with an integrated amd gpu, and a desktop with a discrete nvidia gpu. Both seem to work, but you may need to change some environment variables in `docker-compose.yml`

## Development
You may not need to restart the system to apply changes - if you're working in `f1tenth_drive`, it's usually enough to just re-run `colcon build` and re-run your nodes.

## FastSimplex
The FastSimplex algorithm is implemented in `f1tenth_drive/src/rtis_safety`, and uses the scheduler in `f1tenth_drive/src/rtis_preempt`.

### cgroup setup
In the docker container, run `f1tenth_drive/src/rtis_safety/setup_cpuset.bash`. This will create a cgroup called `deadline_group` with two cpu cores assigned. To ensure any further commands run in that cgroup, run `echo $$ > /sys/fs/cgroup/deadline_group/cgroup.procs`. 
> You can also do `source f1tenth_drive/src/rtis_safety/setup_cpuset.bash`, which will add the current shell to the cgroup

This only applies to the current shell - re-run it in any new shells you open. It will also prevent any other task from being run on the two assigned cpu cores. The cgroup will persist until you reboot the host or manually delete it - to remove it, run `f1tenth_drive/src/rtis_safety/remove_cpuset.bash`.

### Running

To start the FastSimplex system, run `ros2 launch rtis_safety safety_system.launch.py` in the driver container. Stop it with <kbd>Ctrl+C</kbd>.

### Analyzing a run
FastSimplex dumps json-structured log files in `f1tenth-drive/results`. There's a jupyter notebook in `analysis` that uses the log files to draw timelines, and derive runtime stats like mode switches, execution times, etc.

## Changing the map
The map is set in `f1tenth_gym_ros/config/sim.yaml`. You'll need to restart (or rebuild) the sim container: `docker compose restart sim`.
