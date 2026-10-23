#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
camera_script="$script_dir/camera.sh"

# shellcheck source=lib/common.sh
source "$script_dir/lib/common.sh"
init_runtime_dir

stop_camera_launcher() {
    local proc_dir
    local pid
    local arg
    local -a argv

    for proc_dir in /proc/[0-9]*; do
        pid="${proc_dir##*/}"
        [[ "$pid" != "$$" ]] || continue

        argv=()
        mapfile -d '' -t argv < "$proc_dir/cmdline" 2>/dev/null || continue
        (( ${#argv[@]} > 0 )) || continue
        [[ "${argv[0]##*/}" == "bash" ]] || continue

        for arg in "${argv[@]:1}"; do
            if [[ "$arg" == "$camera_script" ]]; then
                kill "$pid" 2>/dev/null || true
                break
            fi
        done
    done
}

stop_camera_processes
stop_camera_launcher
echo "camera processes stopped; Zenoh router left running"
