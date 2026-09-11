#!/usr/bin/env bash
# Smoke test for go2_ros2_sdk running onboard the Go2's embedded Jetson,
# inside the nix-ros-overlay Humble devShell defined by ../flake.nix.
#
# Run from inside `nix develop` in this repo, with `~/go2_ws` already set up
# per the flake's shellHook instructions.
#
# Usage:
#   ./smoke-test.sh discover     # Stage 0: figure out ROBOT_IP / network
#   ./smoke-test.sh build        # Stage 1: colcon build
#   ./smoke-test.sh static       # Stage 2: package/executable sanity
#   ./smoke-test.sh dry-launch   # Stage 3: launch file parses, no nodes started
#   ./smoke-test.sh live         # Stage 4: minimal live launch, sensors only, NO actuation
#   ./smoke-test.sh full         # Stage 6: full nav2+slam launch (run after Stage 5 sign-off)
#   ./smoke-test.sh all-safe     # runs discover, build, static, dry-launch, live (stops before actuation/full)
#
# Stage 5 (actuation / cmd_vel) is NOT in this script - it requires a human to
# confirm the robot is physically safe to command first. Do that by hand:
#   ros2 topic pub --once /cmd_vel geometry_msgs/msg/Twist "{}"
# (or whatever the SDK's actual cmd_vel topic/type turns out to be - confirm
# via `ros2 topic list` / `ros2 topic info` during Stage 4 before trying this.)

set -uo pipefail

WS="${GO2_WS:-$HOME/go2_ws}"
ROBOT_IP="${ROBOT_IP:-}"

# ament_python bakes in colcon's own interpreter (a nix store python3 with a
# fixed shebang) as sys.executable for installed scripts - activating the
# workspace's .venv before `colcon build` has no effect on that. Nix's
# python3 can still see the venv's packages (aiortc, opencv-python, etc, per
# the SDK's requirements.txt) via PYTHONPATH though, regardless of which
# interpreter actually runs. Found via smoke testing on real Jetson hardware.
if [ -d "$WS/.venv" ]; then
  venv_site_packages=$(find "$WS/.venv/lib" -maxdepth 1 -name 'python3.*' -exec echo {}/site-packages \; 2>/dev/null | head -n1)
  if [ -n "$venv_site_packages" ] && [ -d "$venv_site_packages" ]; then
    export PYTHONPATH="$venv_site_packages${PYTHONPATH:+:$PYTHONPATH}"
  fi
fi

# colcon's generated install/setup.bash (and the local_setup.bash it sources)
# reference several colcon-internal vars (COLCON_TRACE, COLCON_PREFIX_PATH,
# ...) with no default - under `set -u` that's an unbound-variable error the
# instant we source it. Rather than pre-declaring each one as we find it,
# just suspend nounset for the duration of the source.
source_install() {
  set +u
  # shellcheck disable=SC1091
  source install/setup.bash
  local rc=$?
  set -u
  return "$rc"
}

log() { printf '\n=== %s ===\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; exit 1; }

# --- launch process-group tracking -----------------------------------------
# `ros2 launch` fans out into several child nodes. A plain `kill` on just its
# own pid (or a SIGKILL that doesn't give it a chance to cascade SIGINT to
# its children) leaves those children running as orphans - confirmed on real
# hardware: 9 accumulated orphaned nodes (including a go2_driver_node pegged
# near 100% CPU) were found still actively connected to the robot over
# WebRTC after earlier runs of this script "finished" or failed partway
# through. Launching via `setsid` makes the launch process its own
# process-group leader, so `kill -- -$LAUNCH_PID` (negative pid = whole
# group) can terminate it and every child together. The EXIT/INT/TERM trap
# means this runs on *any* exit path out of a stage function, including
# `fail()`, not just the happy path at the end of the function.
LAUNCH_PID=""

stop_launch() {
  [ -n "$LAUNCH_PID" ] || return 0
  local pid="$LAUNCH_PID"
  LAUNCH_PID=""
  kill -0 "$pid" 2>/dev/null || return 0
  echo "Stopping launch (pid $pid, whole process group)..."
  kill -INT -- "-$pid" 2>/dev/null
  sleep 3
  if kill -0 "$pid" 2>/dev/null; then
    echo "WARNING: still alive after SIGINT, sending SIGKILL to process group"
    kill -9 -- "-$pid" 2>/dev/null
    sleep 1
  fi
}
# EXIT alone would also fire for INT/TERM once the shell actually exits, but
# a trap on INT/TERM without an explicit exit just resumes the script after
# cleanup instead of terminating it (a classic trap gotcha) - so those two
# exit explicitly. stop_launch() is idempotent (resets LAUNCH_PID itself),
# so it running twice via both traps on the same exit is harmless.
trap stop_launch EXIT
trap 'stop_launch; exit 130' INT
trap 'stop_launch; exit 143' TERM

start_launch() {
  # "$@" is the full `ros2 launch ...` argument list; stdout+stderr go to
  # the given logfile (first arg).
  local logfile="$1"; shift
  setsid "$@" > "$logfile" 2>&1 &
  LAUNCH_PID=$!
}
# -----------------------------------------------------------------------------

stage_discover() {
  log "Stage 0: discovery / network"
  echo "-- ip addr --"
  ip addr || true
  echo "-- arp -a --"
  arp -a || true
  echo "-- workspace check --"
  if [ -d "$WS/src" ]; then
    echo "OK: $WS/src exists"
    ls "$WS/src"
  else
    fail "$WS/src does not exist - clone go2_ros2_sdk per flake.nix shellHook instructions first"
  fi
  echo "NOTE: ROBOT_IP is currently '${ROBOT_IP:-<unset>}'. Since this Jetson is"
  echo "embedded on the robot itself, confirm the correct address for the"
  echo "motion-controller/WebRTC endpoint (commonly 192.168.123.x on Unitree's"
  echo "internal network) before Stage 4 - try pinging candidates above."
}

stage_build() {
  log "Stage 1: colcon build"
  cd "$WS" || fail "cannot cd to $WS"
  colcon build 2>&1 | tee /tmp/go2_colcon_build.log
  local rc=${PIPESTATUS[0]}
  if [ "$rc" -ne 0 ]; then
    fail "colcon build failed (rc=$rc) - see /tmp/go2_colcon_build.log"
  fi
  echo "OK: colcon build succeeded"
}

stage_static() {
  log "Stage 2: static package checks"
  cd "$WS" || fail "cannot cd to $WS"
  source_install || fail "could not source install/setup.bash"
  echo "-- ros2 pkg list | grep go2 --"
  ros2 pkg list | grep -i go2 || fail "no go2 packages found after build"
  echo "-- ros2 pkg executables go2_robot_sdk --"
  ros2 pkg executables go2_robot_sdk || fail "go2_robot_sdk has no executables (build likely incomplete)"
}

stage_dry_launch() {
  log "Stage 3: launch dry-run (--show-args, no nodes started)"
  cd "$WS" || fail "cannot cd to $WS"
  source_install || fail "could not source install/setup.bash"
  ros2 launch go2_robot_sdk robot_cpp.launch.py --show-args \
    || fail "launch file failed to parse - check for missing packages (e.g. foxglove_bridge)"
  echo "OK: launch file parses"
}

stage_live() {
  log "Stage 4: minimal live launch (sensors only, no nav2/slam/actuation)"
  [ -n "$ROBOT_IP" ] || fail "ROBOT_IP is not set - export it after Stage 0 discovery"
  cd "$WS" || fail "cannot cd to $WS"
  source_install || fail "could not source install/setup.bash"

  unset CYCLONEDDS_URI
  export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp

  start_launch /tmp/go2_live_launch.log \
    ros2 launch go2_robot_sdk robot_cpp.launch.py \
    rviz2:=false foxglove:=false speech:=false joystick:=false teleop:=false \
    nav2:=false slam:=false
  echo "launched (pid $LAUNCH_PID), observing for 20s..."
  sleep 20

  # A crashed launch (e.g. "package X not found") exits well within 20s and
  # doesn't necessarily print anything matching the error-keyword grep below
  # - checking the process is still alive is the real signal, not the log.
  if ! kill -0 "$LAUNCH_PID" 2>/dev/null; then
    echo "-- launch log (process died) --"
    cat /tmp/go2_live_launch.log
    fail "launch process exited before the 20s observation window ended"
  fi

  local nodes
  nodes=$(ros2 node list 2>/dev/null)
  echo "-- ros2 node list --"
  echo "$nodes"
  echo "-- ros2 topic list --"
  ros2 topic list || true

  # The robot itself broadcasts its own DDS participants on the shared
  # network regardless of whether our launch ever started - a non-empty
  # `ros2 node list` isn't proof go2_robot_sdk's own nodes came up. Look for
  # this package's actual node explicitly instead.
  if ! echo "$nodes" | grep -iq 'go2'; then
    echo "-- launch log --"
    cat /tmp/go2_live_launch.log
    fail "no go2_robot_sdk node found in 'ros2 node list' - launch likely failed silently or nodes came from elsewhere on the network"
  fi
  echo "OK: launch process alive and a go2_robot_sdk node is present"

  echo "-- checking for errors in launch log --"
  if grep -iE 'error|exception|traceback|fault' /tmp/go2_live_launch.log; then
    echo "WARNING: possible errors found above - inspect /tmp/go2_live_launch.log"
  else
    echo "OK: no obvious errors in launch log"
  fi

  echo ""
  echo "Pick real sensor topics from the 'ros2 topic list' output above and check rate, e.g.:"
  echo "  timeout 5 ros2 topic hz <topic>"
  echo ""
  stop_launch
  echo "-- checking for orphaned ros2 processes --"
  ps aux | grep -i 'ros2\|go2' | grep -v grep || echo "OK: none found"
}

stage_full() {
  log "Stage 6: full launch (nav2+slam) - run only after Stage 5 actuation sign-off"
  [ -n "$ROBOT_IP" ] || fail "ROBOT_IP is not set"
  cd "$WS" || fail "cannot cd to $WS"
  source_install || fail "could not source install/setup.bash"
  unset CYCLONEDDS_URI
  export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp

  start_launch /tmp/go2_full_launch.log \
    ros2 launch go2_robot_sdk robot_cpp.launch.py \
    rviz2:=false foxglove:=false speech:=false joystick:=true teleop:=true \
    nav2:=true slam:=true
  echo "launched (pid $LAUNCH_PID), observing for 30s..."
  sleep 30

  if ! kill -0 "$LAUNCH_PID" 2>/dev/null; then
    cat /tmp/go2_full_launch.log
    fail "launch process exited before the 30s observation window ended"
  fi

  local nodes
  nodes=$(ros2 node list 2>/dev/null)
  echo "$nodes"
  if ! echo "$nodes" | grep -iq 'go2'; then
    cat /tmp/go2_full_launch.log
    fail "no go2_robot_sdk node found in 'ros2 node list'"
  fi

  if grep -iE 'error|exception|traceback|fault' /tmp/go2_full_launch.log; then
    echo "WARNING: possible errors found - inspect /tmp/go2_full_launch.log"
  else
    echo "OK: no obvious errors in full launch log"
  fi
  stop_launch
  ps aux | grep -i 'ros2\|go2' | grep -v grep || echo "OK: no orphaned processes"
}

case "${1:-}" in
  discover) stage_discover ;;
  build) stage_build ;;
  static) stage_static ;;
  dry-launch) stage_dry_launch ;;
  live) stage_live ;;
  full) stage_full ;;
  all-safe)
    stage_discover && stage_build && stage_static && stage_dry_launch && stage_live
    ;;
  *)
    echo "Usage: $0 {discover|build|static|dry-launch|live|full|all-safe}"
    exit 1
    ;;
esac
