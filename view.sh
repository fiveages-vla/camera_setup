#!/usr/bin/env bash
# View camera images started by camera.sh in rqt_image_view.
# Usage: view.sh [left|right|head|all]   (default: all -> one window per camera)
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ORBBEC_WS="${ORBBEC_WS:-$SCRIPT_DIR/OrbbecSDK_ROS2}"

declare -A TOPICS=(
    [left]="/camera_left_wrist/color/image_raw/compressed"
    [right]="/camera_right_wrist/color/image_raw/compressed"
    [head]="/camera_head/color/image_raw/compressed"
)
ORDER=(left right head)

target="${1:-all}"
case "$target" in
    left|right|head) selected=("$target") ;;
    all) selected=("${ORDER[@]}") ;;
    *)
        printf 'Usage: %s [left|right|head|all]\n' "${0##*/}" >&2
        exit 2
        ;;
esac

if [[ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
    printf 'ERROR: no DISPLAY; run from a desktop terminal or use ssh -X / VNC.\n' >&2
    exit 1
fi

set +u
source /opt/ros/jazzy/setup.bash
[[ -f "$ORBBEC_WS/install/setup.bash" ]] && source "$ORBBEC_WS/install/setup.bash"
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

pids=()
trap 'kill "${pids[@]}" 2>/dev/null || true' EXIT INT TERM

for name in "${selected[@]}"; do
    topic="${TOPICS[$name]}"
    if ! ros2 topic list 2>/dev/null | grep -qx "$topic"; then
        printf 'SKIP %s: topic not found (%s)\n' "$name" "$topic" >&2
        continue
    fi
    printf 'Opening %s: %s\n' "$name" "$topic"
    ros2 run rqt_image_view rqt_image_view "$topic" &
    pids+=("$!")
done

if (( ${#pids[@]} == 0 )); then
    printf 'ERROR: no camera topics available. Is camera.sh running?\n' >&2
    exit 1
fi

wait
