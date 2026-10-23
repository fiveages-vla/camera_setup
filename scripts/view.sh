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

# rqt persists its own display rotation separately from camera rotation.
# Reset only that setting so saved 90/270 camera angles are shown faithfully.
python3 - <<'PY'
from python_qt_binding.QtCore import QSettings

settings = QSettings(QSettings.IniFormat, QSettings.UserScope, "ros.org", "rqt_gui")
changed = False
for key in settings.allKeys():
    if "plugin__rqt_image_view__ImageView__" in key and key.endswith("/plugin/rotate"):
        if str(settings.value(key)) != "0":
            settings.setValue(key, 0)
            changed = True
if changed:
    settings.sync()
    if settings.status() != QSettings.NoError:
        raise SystemExit("ERROR: failed to reset rqt_image_view display rotation")
    print("可视化额外旋转已重置为 0°，按相机发布的方向显示。")
PY

# The zenoh router is started by camera.sh.
if ! pgrep -f '[r]mw_zenohd' >/dev/null; then
    printf 'WARN: rmw_zenohd not running; start cameras with camera.sh first.\n' >&2
fi

exec ros2 run rqt_image_view rqt_image_view /camera_head/color/image_raw/compressed
