#!/usr/bin/env bash
# Shared helpers for the camera scripts. Meant to be sourced, not executed.

ROS_DISTRO_NAME="${ROS_DISTRO_NAME:-jazzy}"
ROS_SETUP="/opt/ros/$ROS_DISTRO_NAME/setup.bash"
DEFAULT_RMW_IMPLEMENTATION="rmw_zenoh_cpp"
DEFAULT_ROS_DOMAIN_ID=16

WIDTH=640
HEIGHT=480

if [[ -t 1 && "${TERM:-dumb}" != "dumb" ]]; then
    YELLOW=$'\033[1;33m'
    CYAN=$'\033[1;36m'
    GREEN=$'\033[1;32m'
    RESET=$'\033[0m'
else
    YELLOW=""
    CYAN=""
    GREEN=""
    RESET=""
fi

RUNTIME_DIR=""
LOG_DIR=""
PID_FILE=""
SPAWNED_PID=""

log() {
    printf '%s\n' "$*"
}

# Per-user private directory for the pid file, logs and generated configs.
# /tmp is world-writable, so fixed paths there can be pre-created as symlinks
# or tampered with by other users; a 0700 directory we own cannot.
init_runtime_dir() {
    local base="${XDG_RUNTIME_DIR:-}"

    [[ -n "$base" && -d "$base" && -w "$base" ]] || base="/tmp"
    RUNTIME_DIR="$base/camera_setup-$(id -u)"
    mkdir -p -m 700 -- "$RUNTIME_DIR"
    if [[ -L "$RUNTIME_DIR" || ! -d "$RUNTIME_DIR" || ! -O "$RUNTIME_DIR" ]]; then
        printf 'ERROR: unsafe runtime directory: %s\n' "$RUNTIME_DIR" >&2
        return 1
    fi
    chmod 700 -- "$RUNTIME_DIR"

    LOG_DIR="$RUNTIME_DIR/logs"
    mkdir -p -m 700 -- "$LOG_DIR"
    PID_FILE="$RUNTIME_DIR/camera_pids.txt"
}

record_pid() {
    printf '%s:%s\n' "$1" "$2" >> "$PID_FILE"
}

# Source ROS and the built driver workspace. Needs ORBBEC_WS.
source_ros_workspace() {
    set +u
    unset AMENT_PREFIX_PATH CMAKE_PREFIX_PATH COLCON_PREFIX_PATH LD_LIBRARY_PATH PYTHONPATH
    source "$ROS_SETUP"
    source "$ORBBEC_WS/install/setup.bash"
    set -u
    export RMW_IMPLEMENTATION="${RMW_IMPLEMENTATION:-$DEFAULT_RMW_IMPLEMENTATION}"
    export ROS_DOMAIN_ID="${ROS_DOMAIN_ID:-$DEFAULT_ROS_DOMAIN_ID}"
}

# Run a command in a clean ROS environment in the background, in its own
# session so that the whole process tree can be signalled by group.
# Everything is passed as positional arguments, never spliced into the script.
# Sets SPAWNED_PID.
spawn_ros_process() {
    local logfile="$1"
    shift

    setsid nohup bash --noprofile --norc -c '
set -Ee
set +u
unset AMENT_PREFIX_PATH CMAKE_PREFIX_PATH COLCON_PREFIX_PATH LD_LIBRARY_PATH PYTHONPATH
source "$1"
source "$2"
set -u
export RMW_IMPLEMENTATION="$3"
export ROS_DOMAIN_ID="$4"
shift 4
exec "$@"
' bash "$ROS_SETUP" "$ORBBEC_WS/install/setup.bash" \
        "${RMW_IMPLEMENTATION:-$DEFAULT_RMW_IMPLEMENTATION}" \
        "${ROS_DOMAIN_ID:-$DEFAULT_ROS_DOMAIN_ID}" "$@" > "$logfile" 2>&1 &
    SPAWNED_PID=$!
}

signal_process_groups() {
    local signal="$1"
    local pid
    shift

    for pid in "$@"; do
        kill "-$signal" -- "-$pid" "$pid" 2>/dev/null || true
    done
}

# Give the drivers time to close their streams after SIGTERM. A camera killed
# while still streaming can come back without delivering frames.
STOP_GRACE_SECONDS=10

# Return once every given process group is gone, or after STOP_GRACE_SECONDS.
wait_for_process_groups_exit() {
    local deadline=$((SECONDS + STOP_GRACE_SECONDS))
    local pid
    local alive

    while (( SECONDS < deadline )); do
        alive=0
        for pid in "$@"; do
            ! kill -0 -- "-$pid" 2>/dev/null || alive=1
        done
        (( alive )) || return 0
        sleep 0.5
    done
}

# Stop the processes recorded by camera.sh (the Zenoh router is left running).
stop_recorded_processes() {
    local -a pids=()

    [[ -f "$PID_FILE" ]] || return 0
    mapfile -t pids < <(awk -F: '$1 !~ /^zenoh/ && $2 ~ /^[0-9]+$/ && $2 > 1 {print $2}' "$PID_FILE")
    if (( ${#pids[@]} > 0 )); then
        signal_process_groups TERM "${pids[@]}"
        wait_for_process_groups_exit "${pids[@]}"
        signal_process_groups KILL "${pids[@]}"
    fi
    : > "$PID_FILE"
}

stop_camera_processes() {
    stop_recorded_processes
    pkill -f 'wrist.launch.py|gemini305.launch.py|gemini_330_series.launch.py' 2>/dev/null || true
}
