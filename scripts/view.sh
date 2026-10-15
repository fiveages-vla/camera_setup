#!/usr/bin/env bash
# View camera images started by camera.sh in rqt_image_view.
# Usage: view.sh (opens head; switch cameras using the dropdown)
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_DIR="$(dirname -- "$SCRIPT_DIR")"
ORBBEC_WS="$REPO_DIR/OrbbecSDK_ROS2"

if [[ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
    printf 'ERROR: no DISPLAY; run from a desktop terminal or use ssh -X / VNC.\n' >&2
    exit 1
fi

set +u
unset AMENT_PREFIX_PATH CMAKE_PREFIX_PATH COLCON_PREFIX_PATH LD_LIBRARY_PATH PYTHONPATH
source /opt/ros/jazzy/setup.bash
if [[ ! -f "$ORBBEC_WS/install/setup.bash" ]]; then
    printf 'ERROR: build %s/OrbbecSDK_ROS2 first; see README.md.\n' "$REPO_DIR" >&2
    exit 1
fi
source "$ORBBEC_WS/install/setup.bash"
set -u
export RMW_IMPLEMENTATION="${RMW_IMPLEMENTATION:-rmw_zenoh_cpp}"
export ROS_DOMAIN_ID="${ROS_DOMAIN_ID:-16}"

if ! ros2 pkg prefix rqt_image_view >/dev/null 2>&1; then
    printf 'ERROR: rqt_image_view not installed: sudo apt install ros-jazzy-rqt-image-view\n' >&2
    exit 1
fi

# The zenoh router is started by camera.sh.
if ! pgrep -f '[r]mw_zenohd' >/dev/null; then
    printf 'WARN: rmw_zenohd not running; start cameras with camera.sh first.\n' >&2
fi

exec ros2 run rqt_image_view rqt_image_view /camera_head/color/image_raw/compressed
