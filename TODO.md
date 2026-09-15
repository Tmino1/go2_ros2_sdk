# TODO

## Package this repo as a proper Nix derivation

Right now both `go2-testing/flake.nix` and `vision-inspect/flake.nix` provide the Humble
*toolchain* via `nix-ros-overlay`, but this repo itself is still built the old way: a manual
`git clone` into a colcon workspace's `src/`, a hand-managed `.venv` for its pip-only deps
(`aiortc`, `opencv-python`, etc.), and `colcon build` inside the devShell. That works (proven
on real Go2 hardware), but it's not reproducible the way the rest of the toolchain is, and it
can't be consumed as a clean flake input by a sibling project.

**Idea (deferred 2026-09-15, not started):** write a real `buildRosPackage`-style Nix derivation
for `go2_robot_sdk`/`go2_interfaces`/`lidar_processor_cpp` etc., so this repo becomes a proper
flake output another flake (`vision-inspect`, or anything else on this robot) can just depend on,
instead of everyone re-doing the manual clone+venv+colcon dance.

**Why this got punted rather than done immediately:** this repo isn't in the ros2-gbp release
index `nix-ros-overlay` draws packages from (it's a manually-maintained community SDK, not an
official ROS distro package), and it has non-ROS pip deps (`aiortc` notably) that would need
their own Nix packaging or a `poetry2nix`/`mach-nix`-style bridge. Real, open-ended packaging
effort with unknown yak-shaving — explicitly deprioritized in favor of getting the
Go2/RealSense/local-vLLM waypoint pipeline (`vision-inspect`, `dev/vision-v2`) working first.

**When picking this up:** start from whatever `go2-testing/flake.nix`'s `shellHook` comments
already documented as known nix-ros-overlay/colcon integration gaps (`CMAKE_PREFIX_PATH` mirror,
`ament-cmake`/`python-cmake-module` as direct `mkShell` inputs, `.venv` `PYTHONPATH` bridge) —
those are exactly the friction points a real derivation would need to solve properly instead of
working around at shell-hook time.
