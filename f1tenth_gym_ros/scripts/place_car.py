#!/usr/bin/env python3
"""Automatic car placement for evaluation runs.

Picks a valid start pose (enough clearance, oriented along the track) instead
of the hardcoded sx/sy/stheta in sim.yaml. Pose candidates come from the
track's centerline CSV when one exists; otherwise free cells of the occupancy
grid are used, oriented along the longest free ray.

Modes (combinable):
  default          print "sx sy stheta" to stdout
  --write-config   patch sx/sy/stheta (and optionally map_path) in sim.yaml
  --publish        publish the pose on /initialpose (resets the gym env)
  --respawn        keep running; on every collision, respawn at a fresh pose

Run inside the sim container, e.g.:
  python3 /sim_ws/src/f1tenth_gym_ros/scripts/place_car.py --track levine --publish
"""

import argparse
import csv
import glob
import math
import os
import random
import sys

import cv2
import numpy as np
import yaml


def resolve_map(maps_dir, track):
    """Resolve a track name to (yaml_path, map_stem_for_gym)."""
    racetracks_dir = os.path.join(maps_dir, 'f1tenth_racetracks')
    candidates = [
        os.path.join(maps_dir, track + '.yaml'),
        os.path.join(maps_dir, track, track + '_map.yaml'),
        os.path.join(racetracks_dir, track, track + '_map.yaml'),
        os.path.join(maps_dir, track + '.yml'),
        track if track.endswith('.yaml') else track + '.yaml',
    ]
    for cand in candidates:
        if os.path.isfile(cand):
            return cand, os.path.splitext(cand)[0]
    raise FileNotFoundError(
        f'no map yaml found for track "{track}" under {maps_dir}')


def load_map(yaml_path):
    with open(yaml_path) as f:
        info = yaml.safe_load(f)
    img_path = info['image']
    if not os.path.isabs(img_path):
        img_path = os.path.join(os.path.dirname(yaml_path), img_path)
    img = cv2.imread(img_path, cv2.IMREAD_GRAYSCALE).astype(np.float64)
    if info.get('negate', 0):
        img = 255.0 - img
    # standard ROS map_server convention: occupancy = (255 - v) / 255.
    # Use a threshold stricter than the map's free_thresh: SLAM maps mark
    # unknown/unseen space with light gray (e.g. 216 -> occupancy 0.15) that
    # would otherwise count as free and attract the placement.
    occupancy = (255.0 - img) / 255.0
    free = occupancy < 0.05
    return {
        'free': free,
        'resolution': float(info['resolution']),
        'origin': (float(info['origin'][0]), float(info['origin'][1])),
        'height': img.shape[0],
        'width': img.shape[1],
    }


def clearance_map(free, resolution):
    """Distance (m) to the nearest non-free cell."""
    dist = cv2.distanceTransform(free.astype(np.uint8), cv2.DIST_L2, 5)
    return dist.astype(np.float64) * resolution


def world_to_cell(m, x, y):
    col = int(round((x - m['origin'][0]) / m['resolution']))
    row = m['height'] - 1 - int(round((y - m['origin'][1]) / m['resolution']))
    return row, col


def cell_to_world(m, row, col):
    x = m['origin'][0] + col * m['resolution']
    y = m['origin'][1] + (m['height'] - 1 - row) * m['resolution']
    return x, y


def clearance_at(m, clear, x, y):
    row, col = world_to_cell(m, x, y)
    if 0 <= row < m['height'] and 0 <= col < m['width']:
        return clear[row, col]
    return 0.0


def find_centerline(yaml_path):
    map_dir = os.path.dirname(yaml_path)
    stem = os.path.splitext(os.path.basename(yaml_path))[0]
    patterns = [
        os.path.join(map_dir, stem.replace('_map', '') + '_centerline.csv'),
        os.path.join(map_dir, '*_centerline.csv'),
    ]
    for pattern in patterns:
        hits = sorted(glob.glob(pattern))
        if hits:
            return hits[0]
    return None


def centerline_candidates(csv_path, m, clear):
    """(x, y, theta, clearance) for each centerline point, oriented along the
    direction of travel (towards the next point)."""
    points = []
    with open(csv_path) as f:
        for row in csv.reader(f):
            if not row or row[0].strip().startswith('#'):
                continue
            try:
                points.append((float(row[0]), float(row[1])))
            except ValueError:
                continue
    candidates = []
    n = len(points)
    for i, (x, y) in enumerate(points):
        nx, ny = points[(i + 1) % n]
        theta = math.atan2(ny - y, nx - x)
        candidates.append((x, y, theta, clearance_at(m, clear, x, y)))
    return candidates


def grid_candidates(m, clear, min_clearance):
    """Fallback when there is no centerline: free cells with enough
    clearance, oriented along the longest free ray. Candidates are limited to
    the connected free region containing world (0,0) — the conventional start
    area on ROS maps — so the map's exterior background is never picked."""
    num_labels, labels = cv2.connectedComponents(
        m['free'].astype(np.uint8), connectivity=4)
    origin_row, origin_col = world_to_cell(m, 0.0, 0.0)
    target = 0
    if (0 <= origin_row < m['height'] and 0 <= origin_col < m['width']
            and m['free'][origin_row, origin_col]):
        target = labels[origin_row, origin_col]
    else:
        # no free cell at the origin: use the largest free component
        counts = np.bincount(labels.ravel())
        counts[0] = 0
        target = int(np.argmax(counts))
    in_region = labels == target
    rows, cols = np.where((clear >= min_clearance) & in_region)
    candidates = []
    stride = max(1, len(rows) // 2000)  # cap the candidate count
    for row, col in zip(rows[::stride], cols[::stride]):
        x, y = cell_to_world(m, int(row), int(col))
        best_len, best_theta = 0, 0.0
        for k in range(16):
            theta = k * math.pi / 8
            length = 0
            r, c = float(row), float(col)
            dr = -math.sin(theta)  # image rows grow downward
            dc = math.cos(theta)
            while True:
                r += dr
                c += dc
                ri, ci = int(round(r)), int(round(c))
                if not (0 <= ri < m['height'] and 0 <= ci < m['width']):
                    break
                if not m['free'][ri, ci]:
                    break
                length += 1
            if length > best_len:
                best_len, best_theta = length, theta
        candidates.append((x, y, best_theta, float(clear[row, col])))
    return candidates


def pick_pose(candidates, min_clearance, seed=None, index=None):
    valid = [c for c in candidates if c[3] >= min_clearance]
    if not valid:
        raise RuntimeError(
            f'no candidate pose with clearance >= {min_clearance} m '
            f'(best: {max(c[3] for c in candidates):.2f} m)')
    if index is not None:
        return valid[index % len(valid)]
    if seed is not None:
        return random.Random(seed).choice(valid)
    return max(valid, key=lambda c: c[3])


def patch_config(config_path, sx, sy, stheta, map_stem=None):
    with open(config_path) as f:
        lines = f.readlines()
    replacements = {'sx:': sx, 'sy:': sy, 'stheta:': stheta}
    if map_stem is not None:
        replacements['map_path:'] = f"'{map_stem}'"
    out = []
    for line in lines:
        stripped = line.lstrip()
        replaced = False
        for key, value in replacements.items():
            if stripped.startswith(key):
                indent = line[:len(line) - len(stripped)]
                out.append(f'{indent}{key} {value}\n')
                replaced = True
                break
        if not replaced:
            out.append(line)
    with open(config_path, 'w') as f:
        f.writelines(out)


def make_pose_msg(sx, sy, stheta):
    from geometry_msgs.msg import PoseWithCovarianceStamped
    msg = PoseWithCovarianceStamped()
    msg.header.frame_id = 'map'
    msg.pose.pose.position.x = sx
    msg.pose.pose.position.y = sy
    msg.pose.pose.orientation.z = math.sin(stheta / 2.0)
    msg.pose.pose.orientation.w = math.cos(stheta / 2.0)
    return msg


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--maps-dir',
                        default='/sim_ws/src/f1tenth_gym_ros/maps')
    parser.add_argument('--track', required=True,
                        help='track name, e.g. levine or kurtmap0')
    parser.add_argument('--min-clearance', type=float, default=0.6,
                        help='minimum obstacle clearance for a pose (m)')
    parser.add_argument('--seed', type=int, default=None,
                        help='pick a random valid pose with this seed '
                             '(default: highest-clearance pose)')
    parser.add_argument('--index', type=int, default=None,
                        help='pick the i-th valid candidate (deterministic '
                             'sweep across start positions)')
    parser.add_argument('--write-config', metavar='SIM_YAML', default=None,
                        help='patch sx/sy/stheta (and map_path) in this '
                             'sim.yaml')
    parser.add_argument('--publish', action='store_true',
                        help='publish the pose on /initialpose')
    parser.add_argument('--respawn', action='store_true',
                        help='keep running and respawn the car at a fresh '
                             'pose on every collision (implies --publish)')
    args = parser.parse_args()

    yaml_path, map_stem = resolve_map(args.maps_dir, args.track)
    m = load_map(yaml_path)
    clear = clearance_map(m['free'], m['resolution'])

    centerline = find_centerline(yaml_path)
    if centerline:
        candidates = centerline_candidates(centerline, m, clear)
        print(f'using centerline {centerline} '
              f'({len(candidates)} candidates)', file=sys.stderr)
    else:
        candidates = grid_candidates(m, clear, args.min_clearance)
        print(f'no centerline found, using {len(candidates)} grid candidates',
              file=sys.stderr)

    pose = pick_pose(candidates, args.min_clearance, args.seed, args.index)
    sx, sy, stheta, clearance = pose
    print(f'pose: x={sx:.3f} y={sy:.3f} theta={stheta:.3f} '
          f'(clearance {clearance:.2f} m)', file=sys.stderr)
    print(f'{sx:.4f} {sy:.4f} {stheta:.4f}')

    if args.write_config:
        patch_config(args.write_config, round(sx, 4), round(sy, 4),
                     round(stheta, 4), map_stem)
        print(f'updated {args.write_config}', file=sys.stderr)

    if args.publish or args.respawn:
        import rclpy
        from rclpy.node import Node
        from std_msgs.msg import Bool

        rclpy.init()
        node = Node('car_placer')
        pose_pub = node.create_publisher(
            type(make_pose_msg(0, 0, 0)), '/initialpose', 1)

        # give the publisher a moment to match subscribers, then publish
        rclpy.spin_once(node, timeout_sec=1.0)
        pose_pub.publish(make_pose_msg(sx, sy, stheta))
        node.get_logger().info('published /initialpose')

        if args.respawn:
            state = {'in_collision': False, 'respawns': 0}

            def on_collision(msg):
                if msg.data and not state['in_collision']:
                    state['respawns'] += 1
                    seed = (args.seed or 0) + state['respawns']
                    npose = pick_pose(candidates, args.min_clearance, seed)
                    node.get_logger().warn(
                        f'collision -> respawning at '
                        f'({npose[0]:.2f}, {npose[1]:.2f})')
                    pose_pub.publish(make_pose_msg(*npose[:3]))
                state['in_collision'] = msg.data

            node.create_subscription(Bool, '/ego_racecar/collision',
                                     on_collision, 10)
            try:
                rclpy.spin(node)
            except KeyboardInterrupt:
                pass
        node.destroy_node()


if __name__ == '__main__':
    main()
