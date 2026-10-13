#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
camera_script="$script_dir/camera.sh"
pid_file="/tmp/camera_pids.txt"

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

if [[ -f "$pid_file" ]]; then
    awk -F: '$1 !~ /^zenoh/ {print $2}' "$pid_file" | xargs -r kill 2>/dev/null || true
    sleep 1
    awk -F: '$1 !~ /^zenoh/ {print $2}' "$pid_file" | xargs -r kill -9 2>/dev/null || true
    : > "$pid_file"
fi

pkill -f 'gemini305.launch.py|gemini_330_series.launch.py|relay_compressed_image.py|component_container' 2>/dev/null || true
stop_camera_launcher
echo "camera processes stopped; Zenoh router left running"
