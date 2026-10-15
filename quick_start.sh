#!/usr/bin/env bash
# Interactive entry point for the camera setup scripts.
# Usage: ./quick_start.sh [install|camera|view|can|stop] [args...]
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPTS="$SCRIPT_DIR/scripts"

usage() {
    printf 'Usage: %s [install|camera|view|can|stop] [args...]\n' "$0" >&2
}

run_action() {
    local action="$1"
    shift
    case "$action" in
        install) exec "$SCRIPTS/install.sh" "$@" ;;
        camera)  exec "$SCRIPTS/camera.sh" "$@" ;;
        view)    exec "$SCRIPTS/view.sh" "$@" ;;
        can)     exec "$SCRIPTS/can.sh" "$@" ;;
        stop)    exec "$SCRIPTS/killcam.sh" "$@" ;;
        *)       usage; exit 2 ;;
    esac
}

if [[ $# -gt 0 ]]; then
    run_action "$@"
fi

cat <<'MENU'
Camera quick start
  1) 安装依赖    (scripts/install.sh)
  2) 启动相机    (scripts/camera.sh)
  3) 可视化      (scripts/view.sh,需在另一个终端运行)
  4) 启动 CAN    (scripts/can.sh)
  5) 停止相机    (scripts/killcam.sh)
  q) 退出
MENU

while true; do
    read -r -p "请选择 [1-5/q]: " choice || exit 0
    case "$choice" in
        1) run_action install ;;
        2) run_action camera ;;
        3) run_action view ;;
        4) run_action can ;;
        5) run_action stop ;;
        q|Q|"") exit 0 ;;
        *) printf '无效选择: %s\n' "$choice" >&2 ;;
    esac
done
