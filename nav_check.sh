#!/usr/bin/env bash
# nav_check.sh — no-motion health gate for driver + SLAM + Nav2. Run it at every session setup
# and before merging any SDK change to master.
# Moves robot: NO. Launches robot_cpp.launch.py with teleop:=false (no twist_mux), and FAILs if
# /cmd_vel has a subscriber. Refuses to start if a go2_robot_sdk launch is already running.
# Usage:  ROBOT_IP=192.168.123.161 ./nav_check.sh [robot_cpp.launch.py args...]
#           e.g. ./nav_check.sh nav_to_pose_bt_xml:=/path/to/project_bt.xml
#         NAV_CHECK_SECS=60 (watch window after Nav2 is active)
# Log:    /tmp/nav_check.log (full launch output). Exit 0 = PASS, 1 = FAIL. Stops its own launch on exit.
set -uo pipefail
repo=$(cd "$(dirname "$0")" && pwd)
ws=$(dirname "$repo")

if [ -z "${IN_NIX_SHELL:-}" ]; then
  exec nix develop "$repo" --command bash "$0" "$@"
fi
: "${ROBOT_IP:?set ROBOT_IP (the dog, e.g. 192.168.123.161)}"
set +u; source "$ws/install/setup.bash"; set -u
export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp
unset CYCLONEDDS_URI
LOG=/tmp/nav_check.log
SECS=${NAV_CHECK_SECS:-60}
fails=0
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }
ok()   { echo "ok:   $*"; }

# 1. Installed config/launch must match src (not a symlink install).
share="$ws/install/go2_robot_sdk/share/go2_robot_sdk"
for d in config launch; do
  for f in "$repo/go2_robot_sdk/$d"/*; do
    [ -f "$f" ] || continue
    cmp -s "$f" "$share/$d/$(basename "$f")" || fail "install/ $d/$(basename "$f") differs from src - rebuild"
  done
done
[ $fails -eq 0 ] && ok "install/ config+launch match src"

if pgrep -f "ros2 launch go2_robot_sdk" >/dev/null; then
  echo "FAIL: a go2_robot_sdk launch is already running - stop it first"; exit 1
fi
ros2 daemon stop >/dev/null 2>&1

# 2. Launch (teleop off) and wait for the driver and Nav2.
setsid ros2 launch go2_robot_sdk robot_cpp.launch.py \
  rviz2:=false foxglove:=false speech:=false joystick:=false teleop:=false \
  nav2:=true slam:=true "$@" > "$LOG" 2>&1 &
pgid=$!
cleanup() {
  kill -INT -- "-$pgid" 2>/dev/null
  for _ in $(seq 15); do kill -0 "$pgid" 2>/dev/null || break; sleep 1; done
  kill -9 -- "-$pgid" 2>/dev/null
}
trap cleanup EXIT
echo "launched (pgid $pgid), log $LOG"

wait_for() {  # $1 pattern, $2 timeout s
  for _ in $(seq "$2"); do grep -q "$1" "$LOG" && return 0; sleep 1; done; return 1
}
wait_for "validated and ready" 45 && ok "driver connected" \
  || { fail "driver not ready in 45s (stuck at Data channel connecting?)"; exit 1; }
wait_for "Managed nodes are active" 60 && ok "Nav2 active" \
  || { fail "Nav2 not active in 60s"; exit 1; }
start_line=$(wc -l < "$LOG")

# 3. Safety and wiring.
subs=$(ros2 topic info /cmd_vel --no-daemon 2>/dev/null | sed -n 's/Subscription count: //p')
[ "${subs:-1}" = "0" ] && ok "/cmd_vel has 0 subscribers" || fail "/cmd_vel subscribers = ${subs:-?} (expected 0)"
for p in default_nav_to_pose_bt_xml default_nav_through_poses_bt_xml; do
  echo "info: $p = $(ros2 param get /bt_navigator $p 2>/dev/null | sed "s/.*value is: //")"
done

rate() {  # $1 topic, $2 seconds -> average Hz (0 if none)
  local r; r=$(timeout "$2" ros2 topic hz "$1" 2>/dev/null | sed -n 's/.*average rate: //p' | tail -1)
  echo "${r:-0}"
}
check_rate() {  # $1 topic, $2 min Hz, $3 window s
  local r; r=$(rate "$1" "$3")
  awk -v r="$r" -v m="$2" 'BEGIN{exit !(r >= m)}' && ok "$1 ${r} Hz" || fail "$1 ${r} Hz (< $2)"
}
check_rate /scan 8 8
check_rate /odom 15 8
check_rate /map 0.05 25

# 4a. Nothing inside/at the footprint. A sitting or lying dog puts the floor inside the scan's
#     height band, which shows up as a wall ~0.3 m ahead and "Starting point in lethal space".
python3 - <<'PY' || fail "scan returns within 0.45 m of base_link - is the dog sitting/lying? stand it up"
import math, sys, time, rclpy
from rclpy.qos import qos_profile_sensor_data
from sensor_msgs.msg import LaserScan
rclpy.init(); n = rclpy.create_node('nav_check_close'); got = []
n.create_subscription(LaserScan, '/scan', got.append, qos_profile_sensor_data)
end = time.time() + 10
while time.time() < end and len(got) < 5: rclpy.spin_once(n, timeout_sec=0.2)
if not got: print('FAIL: no /scan within 10s'); sys.exit(1)
close = [r for s in got for r in s.ranges if math.isfinite(r) and s.range_min <= r < 0.45]
print(f'info: /scan returns < 0.45 m: {len(close)} over {len(got)} scans' + (f', closest {min(close):.2f} m' if close else ''))
sys.exit(1 if len(close) >= 3 * len(got) else 0)
PY

# 4b. Robot inside the global costmap with margin.
python3 - <<'PY' || fail "robot not inside the global costmap with >= 0.5 m margin"
import rclpy, sys, time
from rclpy.qos import QoSProfile, DurabilityPolicy, ReliabilityPolicy
from nav_msgs.msg import OccupancyGrid
from rclpy.time import Time
from tf2_ros import Buffer, TransformListener
rclpy.init(); n = rclpy.create_node('nav_check_margin')
buf = Buffer(); TransformListener(buf, n)
info = []
qos = QoSProfile(depth=1, durability=DurabilityPolicy.TRANSIENT_LOCAL, reliability=ReliabilityPolicy.RELIABLE)
n.create_subscription(OccupancyGrid, '/global_costmap/costmap', lambda m: info.append(m.info), qos)
end = time.time() + 15; tf = None
while time.time() < end and (not info or tf is None):
    rclpy.spin_once(n, timeout_sec=0.2)
    try: tf = buf.lookup_transform('map', 'base_link', Time())
    except Exception: pass
if not info or tf is None:
    print('FAIL: no global costmap or map->base_link within 15s'); sys.exit(1)
i = info[-1]; x, y = tf.transform.translation.x, tf.transform.translation.y
x0, y0 = i.origin.position.x, i.origin.position.y
m = min(x - x0, x0 + i.width * i.resolution - x, y - y0, y0 + i.height * i.resolution - y)
print(f'info: robot ({x:.2f},{y:.2f}) in global costmap {i.width}x{i.height}@{i.resolution}, margin {m:.2f} m')
sys.exit(0 if m >= 0.5 else 1)
PY

# 5. Watch window, then known-bad signatures (only lines logged after Nav2 came up).
echo "watching ${SECS}s..."
sleep "$SECS"
tail -n +"$start_line" "$LOG" > "$LOG.window"
for sig in "Sensor origin .* out of map bounds" "out of bounds of the costmap" "out of costmap" \
           "Transform data too old" "process has died" "Data channel is not open"; do
  c=$(grep -cE "$sig" "$LOG.window")
  [ "$c" -eq 0 ] && ok "no \"$sig\"" || fail "$c x \"$sig\""
done

echo "-----"
if [ $fails -eq 0 ]; then echo "NAV_CHECK PASS"; exit 0; else echo "NAV_CHECK FAIL ($fails)"; exit 1; fi
