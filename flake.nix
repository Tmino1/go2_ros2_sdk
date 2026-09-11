{
  description = "ROS2 Humble dev shell for go2_ros2_sdk on JetPack 5 (no reflash)";

  inputs = {
    # Pinned (not `master`) - see README notes in this repo for why: master's
    # nixpkgs currently defaults to python3 3.13 (too new for any Jetson torch
    # wheel and breaks when mixed with an older nixpkgs). This commit's own
    # matched nixpkgs fork resolves python3 to 3.11.9.
    nix-ros-overlay.url = "github:lopsided98/nix-ros-overlay/c9b5ce4266f2c60f733d9d660939ede2853c21d6";
    nixpkgs.follows = "nix-ros-overlay/nixpkgs"; # IMPORTANT: keep matched to the overlay's own pin
  };

  outputs = { self, nix-ros-overlay, nixpkgs }:
    nix-ros-overlay.inputs.flake-utils.lib.eachDefaultSystem (system:
      let
        # oneTBB 2021.8 no longer exists at this nixpkgs snapshot; slam_toolbox's
        # generated expression still asks for it by name. 2021.x keeps a stable
        # ABI, so aliasing to the newest available 2021.x release is safe.
        tbbOverlay = final: prev: { tbb_2021_8 = prev.tbb_2021_11; };

        pkgs = import nixpkgs {
          inherit system;
          overlays = [ tbbOverlay nix-ros-overlay.overlays.default ];
        };

        # Hash fixups for upstream ros2-gbp release tarballs that have been
        # regenerated since this nix-ros-overlay commit was cut (a known class
        # of bit-rot on older, no-longer-CI-tracked overlay pins). Each hash
        # is the *actual* value Nix reported in a real "hash mismatch" build
        # error - not guessed. Expect to append more here as the build
        # progresses further into the dependency graph on real hardware.
        srcHashFixups = {
          fastrtps = "sha256-ngNzOWIqCaaJF8OXdbrP/ig9yIa7+XhcJznrg3hqAK8=";
        };

        humble = pkgs.rosPackages.humble.overrideScope (final: prev:
          (builtins.mapAttrs
            (name: hash: prev.${name}.overrideAttrs (old: {
              src = old.src.overrideAttrs (_: { outputHash = hash; });
            }))
            srcHashFixups)
          // {
            slam-toolbox = prev.slam-toolbox.override { tbb_2021_8 = pkgs.tbb_2021_11; };

            # nav2 (and likely more packages further into this build) were
            # written against an older, less pedantic GCC than this nixpkgs
            # snapshot ships (13.x). `-Werror` turns newer GCC's extra
            # warnings (e.g. -Wmaybe-uninitialized false positives) into hard
            # build failures for code that's otherwise fine.
            #
            # NOTE: this must be NIX_CFLAGS_COMPILE, not CXXFLAGS. nav2's own
            # CMakeLists.txt sets -Werror itself via add_compile_options(),
            # which CMake places *after* env-derived CXXFLAGS on the actual
            # compiler invocation - so a plain CXXFLAGS override gets silently
            # overridden right back by the package's own -Werror (confirmed:
            # this is exactly what happened to the first attempt at this
            # fix). NIX_CFLAGS_COMPILE is nixpkgs' cc-wrapper mechanism for
            # flags that must win regardless of what the build system itself
            # specifies - the wrapper appends it last, after everything else.
            buildRosPackage = args: prev.buildRosPackage (args // {
              NIX_CFLAGS_COMPILE = (args.NIX_CFLAGS_COMPILE or "") + "-Wno-error ";
            });
          }
        );

        # Everything go2_robot_sdk / go2_interfaces / lidar_processor_cpp
        # need, per their package.xml - excluding everything only
        # coco_detector/lidar_processor(py)/speech_processor need (torch,
        # torchvision, open3d - not building those packages at all, see chat
        # history). foxglove-bridge IS included even though we launch with
        # foxglove:=false: robot_cpp.launch.py calls
        # get_package_share_directory('foxglove_bridge') unconditionally at
        # parse time, so it has to be present or the launch crashes on
        # startup regardless of the flag.
        rosDeps = with humble; [
          ros-core rclcpp sensor-msgs geometry-msgs std-msgs
          twist-mux joy teleop-twist-joy foxglove-bridge
          navigation2 nav2-amcl nav2-bringup nav2-map-server nav2-util
          pointcloud-to-laserscan image-transport compressed-image-transport
          slam-toolbox cv-bridge rmw-cyclonedds-cpp
          pcl-ros pcl-conversions tf2 tf2-ros
          rosidl-default-generators rosidl-default-runtime
          robot-state-publisher
        ];
      in {
        devShells.default = pkgs.mkShell {
          name = "go2-ros2-sdk";
          packages = [
            pkgs.colcon
            pkgs.python3
            pkgs.python3Packages.pip
            (humble.buildEnv { paths = rosDeps; })

            # ament-cmake itself (found missing via smoke testing on real
            # Jetson hardware, see CMAKE_PREFIX_PATH comment below): every
            # ROS package declares ament_cmake as a <buildtool_depend>, which
            # buildRosPackage treats as a nativeBuildInput used only while
            # nix itself compiles that package - it never ends up in the
            # package's own runtime output, so humble.buildEnv's merge above
            # (which only merges the *runtime* content of rosDeps) never
            # picks it up. Since colcon has to compile go2_ros2_sdk's own
            # ament_cmake-based packages (lidar_processor_cpp, go2_interfaces)
            # right here in this shell, ament-cmake needs to be a direct
            # mkShell input so nix actually runs its (and its propagated
            # ament-cmake-core / export-macro packages') setup hooks -
            # merging it into the buildEnv above would not do that, since
            # buildEnv only symlinks file trees and doesn't propagate the
            # setup hooks of what it merges.
            humble.ament-cmake

            # Same story, one step further into the build: go2_interfaces'
            # rosidl_generate_interfaces() call needs python_cmake_module's
            # CMake config (via rosidl_generator_py), which is again only a
            # nativeBuildInput of rosidl_generator_py's own nix build, not
            # part of any package's runtime output.
            humble.python-cmake-module
          ];

          shellHook = ''
            # colcon derives each dependency's CMake config location from
            # AMENT_PREFIX_PATH by sourcing that prefix's colcon-generated
            # local_setup.* - but nix's buildEnv profile isn't a colcon-built
            # prefix, so it ships no such file. Without this, CMake's
            # find_package(... CONFIG) (e.g. ament_cmake_core, needed by
            # lidar_processor_cpp) can't find packages that are right there
            # in the nix store. Mirror AMENT_PREFIX_PATH (which nix already
            # populates correctly) onto CMAKE_PREFIX_PATH directly.
            export CMAKE_PREFIX_PATH="$AMENT_PREFIX_PATH''${CMAKE_PREFIX_PATH:+:$CMAKE_PREFIX_PATH}"

            # ament_python bakes in colcon's own interpreter (a nix store
            # python3 with a fixed shebang) as sys.executable for installed
            # scripts - activating ~/go2_ws/.venv before `colcon build` has
            # no effect on that. Nix's python3 can still see the venv's
            # packages (aiortc, opencv-python, etc, per the SDK's
            # requirements.txt) via PYTHONPATH though, regardless of which
            # interpreter actually runs. Found via smoke testing on real
            # Jetson hardware (go2_driver_node died with
            # ModuleNotFoundError: No module named 'aiortc').
            for _go2_venv_site in "$HOME"/go2_ws/.venv/lib/python3.*/site-packages; do
              if [ -d "$_go2_venv_site" ]; then
                export PYTHONPATH="$_go2_venv_site''${PYTHONPATH:+:$PYTHONPATH}"
              fi
            done
            unset _go2_venv_site

            # Leftover from an earlier, non-Nix ROS2 setup attempt - .bashrc
            # (or similar) exports this pointing at a ~/cyclonedds_ws that no
            # longer exists, which breaks rmw_cyclonedds_cpp's domain
            # participant creation entirely. This SDK only uses DDS for local
            # inter-node comms (the robot itself talks over WebRTC), so no
            # custom CycloneDDS config is needed here at all.
            unset CYCLONEDDS_URI

            export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp

            # Stripped-down launch: no rviz2 (view remotely if ever needed),
            # no foxglove (package is built to satisfy the launch file's
            # unconditional lookup, but never started), no speech_processor
            # (not built at all - see COLCON_IGNORE below; robot_cpp.launch.py
            # was patched locally in this clone to gate its TTS node behind
            # this same 'speech' flag, since upstream launches it
            # unconditionally otherwise). Keeps joystick + teleop as a manual
            # override path, and nav2 + slam together (robot_cpp.launch.py's
            # own default: navigate-while-mapping). ROBOT_IP (and ROBOT_TOKEN
            # if your robot needs it) must already be exported in your
            # environment before calling this - they're per-robot
            # secrets/config, not something to bake into the flake.
            go2-launch() {
              ros2 launch go2_robot_sdk robot_cpp.launch.py \
                rviz2:=false \
                foxglove:=false \
                speech:=false \
                joystick:=true \
                teleop:=true \
                nav2:=true \
                slam:=true \
                "$@"
            }

            echo "=================================================="
            echo "go2_ros2_sdk dev shell - humble / python $(python3 --version)"
            echo "=================================================="
            echo "One-time workspace setup:"
            echo "  mkdir -p ~/go2_ws && cd ~/go2_ws"
            echo "  git clone --recurse-submodules https://github.com/abizovnuralem/go2_ros2_sdk.git src"
            echo "  touch src/coco_detector/COLCON_IGNORE src/lidar_processor/COLCON_IGNORE src/speech_processor/COLCON_IGNORE"
            echo "  python3 -m venv .venv && source .venv/bin/activate"
            echo "  # strip torch/torchvision/open3d out of src/requirements.txt first - not needed"
            echo "  # add 'requests' to src/requirements.txt too - go2_robot_sdk's own"
            echo "  # http_client.py needs it and upstream's requirements.txt omits it"
            echo "  pip install -r src/requirements.txt"
            echo "  colcon build"
            echo "  source install/setup.bash"
            echo ""
            echo "  # speech_processor stays COLCON_IGNOREd (its TTS node needs an"
            echo "  # ELEVENLABS_API_KEY nobody's configured) - robot_cpp.launch.py in"
            echo "  # this clone was patched locally to gate that node behind a"
            echo "  # 'speech' launch arg (default false) instead of launching it"
            echo "  # unconditionally like upstream does."
            echo ""
            echo "Then, with ROBOT_IP (and ROBOT_TOKEN if needed) exported:"
            echo "  go2-launch"
            echo "=================================================="
          '';
        };
      });

  nixConfig = {
    extra-substituters = [ "https://ros.cachix.org" ];
    extra-trusted-public-keys = [ "ros.cachix.org-1:dSyZxI8geDCJrwgvCOHDoAfOm5sV1wCPjBkKL+38Rvo=" ];
  };
}
