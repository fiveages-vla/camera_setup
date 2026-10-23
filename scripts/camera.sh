#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_DIR="$(dirname -- "$SCRIPT_DIR")"
ORBBEC_WS="$REPO_DIR/OrbbecSDK_ROS2"

# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/roles.sh
source "$SCRIPT_DIR/lib/roles.sh"

BUILD_FIRST=0
FPS="${1:-}"
AE_MAX_EXPOSURE="${CAM_AE_MAX_EXPOSURE:-120}"
WRIST_EXPOSURE="${CAM_WRIST_EXPOSURE:-50}"
WRIST_GAIN="${CAM_WRIST_GAIN:-16}"
COLOR_WHITE_BALANCE="${CAM_COLOR_WHITE_BALANCE:-5600}"
WAIT_TIMEOUT="${CAM_WAIT_TIMEOUT:-180}"

LEFT_RUNTIME_CONFIG=""
RIGHT_RUNTIME_CONFIG=""

LEFT_TOPIC="/camera_left_wrist/left_color/image_raw/compressed"
RIGHT_TOPIC="/camera_right_wrist/right_color/image_raw/compressed"
HEAD_TOPIC="/camera_head/color/image_raw/compressed"

# Set by resolve_active_cameras: whether each configured camera is plugged in.
HAS_LEFT=0
HAS_RIGHT=0
HAS_HEAD=0
LEFT_USB_PORT=""
RIGHT_USB_PORT=""
HEAD_USB_PORT=""

if (( $# > 1 )); then
    printf 'Usage: %s [30|60]\n' "${0##*/}" >&2
    exit 2
fi

case "$FPS" in
    ''|30|60) ;;
    *)
        printf 'ERROR: unsupported FPS %q; choose 30 or 60\n' "$FPS" >&2
        exit 2
        ;;
esac

select_startup_mode() {
    local choice
    BUILD_FIRST=0
    [[ -t 0 ]] || return 0

    printf '请选择相机启动方式：\n'
    printf '  1) 正常启动（默认）\n'
    printf '  2) 首次配置 / 重新编译，然后启动\n'
    while true; do
        read -r -p '请输入选项 [1-2]（回车正常启动）: ' choice || return 1
        case "$choice" in
            ''|1) return 0 ;;
            2) BUILD_FIRST=1; return 0 ;;
            *) printf '无效选项，请输入 1 或 2。\n' >&2 ;;
        esac
    done
}

select_frame_rate() {
    local fps_choice
    if [[ -z "$FPS" ]]; then
        if [[ -t 0 ]]; then
            printf '请选择相机帧率：\n'
            printf '  1) 30 Hz\n'
            printf '  2) 60 Hz（实验性：Gemini 305 可能无法稳定出图）\n'
            while true; do
                read -r -p '请输入选项 [1-2]（默认 30）: ' fps_choice || return 1
                case "$fps_choice" in
                    ''|1|30) FPS=30; break ;;
                    2|60) FPS=60; break ;;
                    *) printf '无效选项，请输入 1 或 2。\n' >&2 ;;
                esac
            done
        else
            FPS=30
        fi
    fi

    if [[ "$FPS" == 60 ]]; then
        printf 'WARN: 60 Hz 在 Gemini 335Lg 上测试正常，但 Gemini 305 可能无法稳定出图。\n' >&2
    fi
}

require_file() {
    if [[ ! -f "$1" ]]; then
        log "ERROR: missing file: $1"
        exit 1
    fi
}

install_udev_rule() {
    local rule_src="$ORBBEC_WS/orbbec_camera/scripts/99-obsensor-libusb.rules"
    local rule_dst="/etc/udev/rules.d/99-obsensor-libusb.rules"

    [[ ! -f "$rule_dst" ]] || return 0
    if [[ ! -f "$rule_src" ]]; then
        log "ERROR: Orbbec udev rule not found: $rule_src"
        return 1
    fi
    log "Installing Orbbec udev rule. sudo may ask for your password."
    sudo cp "$rule_src" "$rule_dst"
    sudo udevadm control --reload-rules
    sudo udevadm trigger
    sleep 1
}

# Make one USB device writable for the current user only; never for everyone.
grant_usb_access() {
    local dev="$1"

    [[ ! -w "$dev" ]] || return 0
    log "Orbbec USB device is not writable yet: ${YELLOW}${dev}${RESET}"
    log "Reloading udev rules. sudo may ask for your password."
    sudo udevadm control --reload-rules
    sudo udevadm trigger
    sleep 1
    [[ ! -w "$dev" ]] || return 0

    if command -v setfacl >/dev/null 2>&1; then
        log "Granting $(id -un) access to ${YELLOW}${dev}${RESET}. sudo may ask for your password."
        sudo setfacl -m "u:$(id -un):rw" "$dev"
    else
        log "ERROR: cannot write to $dev. Re-plug the camera, or install the udev rules (scripts/install.sh)."
        return 1
    fi
}

ensure_usb_permissions() {
    local dev
    local listing
    local -a devs=()

    # Permissions only matter for USB cameras. GMSL cameras do not show up in lsusb,
    # so having no USB device is not an error here; scan_devices reports "no camera".
    if ! command -v lsusb >/dev/null 2>&1; then
        log "WARN: lsusb not found; skipping USB permission check (install usbutils for USB cameras)."
        return 0
    fi
    mapfile -t devs < <(lsusb | awk '/Orbbec|2bc5:/{printf "/dev/bus/usb/%s/%s\n",$2,$4}' | tr -d :)
    if [[ "${#devs[@]}" -eq 0 ]]; then
        log "No Orbbec USB camera found; continuing (GMSL cameras are detected by the SDK scan)."
        return 0
    fi

    install_udev_rule
    for dev in "${devs[@]}"; do
        if [[ ! -e "$dev" ]]; then
            log "WARN: Orbbec USB device path disappeared: ${YELLOW}${dev}${RESET}"
            continue
        fi
        grant_usb_access "$dev"
        listing="$(ls -l -- "$dev")"
        printf '%s %s%s%s\n' "${listing% "$dev"}" "$YELLOW" "$dev" "$RESET"
    done
}

stop_old_camera_processes() {
    log "Stopping old camera processes..."
    stop_camera_processes
}

build_driver() {
    local expected_commit="cb24b007cd3309bc5340fa89d5082b69eba20601"
    if [[ ! -e "$ORBBEC_WS/.git" ]]; then
        log "ERROR: initialize the driver first: git submodule update --init"
        return 1
    fi
    if [[ "$(git -C "$ORBBEC_WS" rev-parse HEAD)" != "$expected_commit" ]]; then
        log "ERROR: OrbbecSDK_ROS2 must be at $expected_commit"
        return 1
    fi

    env -i HOME="$HOME" LANG="${LANG:-C.UTF-8}" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
        bash --noprofile --norc -c '
set -Ee
source "$1"
cd -- "$2"
exec colcon build
' bash "$ROS_SETUP" "$ORBBEC_WS"
}

# Set "key: value" in a yaml file. A missing key is inserted after the anchor
# key when one is given, and skipped otherwise.
set_yaml_key() {
    local file="$1"
    local key="$2"
    local value="$3"
    local anchor="${4:-}"

    if grep -q "^${key}:" "$file"; then
        sed -i "s|^${key}:.*|${key}: ${value}|" "$file"
    elif [[ -n "$anchor" ]]; then
        sed -i "/^${anchor}:/a ${key}: ${value}" "$file"
    fi
}

apply_yaml_settings() {
    local file="$1"
    local entry
    shift

    for entry in "$@"; do
        set_yaml_key "$file" "${entry%%=*}" "${entry#*=}"
    done
}

valid_config_token() {
    [[ "$1" =~ ^[A-Za-z0-9._:-]+$ ]]
}

make_gemini305_config() {
    local output="$1"
    local serial="$2"
    local usb_port="$3"
    local eye="$4"
    local rotation="$5"
    local template="$ORBBEC_WS/orbbec_camera/config/gemini305_dual_color.yaml"
    local format="ANY"
    local color_width
    local color_height

    case "$eye" in
        left) format="MJPG" ;;
        right) format="YUYV" ;;
        *) log "ERROR: unknown Gemini305 eye: $eye"; exit 1 ;;
    esac
    valid_config_token "$serial" || { log "ERROR: invalid serial: $serial"; exit 1; }
    valid_config_token "$usb_port" || { log "ERROR: invalid USB port: $usb_port"; exit 1; }
    valid_rotation_value "$rotation" || { log "ERROR: invalid rotation: $rotation"; exit 1; }
    read -r color_width color_height < <(dimensions_for_rotation "$rotation")

    log "Gemini305 $serial: fixed wrist exposure=$WRIST_EXPOSURE gain=$WRIST_GAIN white_balance=$COLOR_WHITE_BALANCE"
    require_file "$template"
    cp -- "$template" "$output"
    chmod 600 -- "$output"

    # Only the selected eye is enabled; its stream gets the requested size and rotation.
    apply_yaml_settings "$output" \
        "camera_name=camera" \
        "serial_number=\"$serial\"" \
        "usb_port=\"$usb_port\"" \
        "enable_color=false" \
        "enable_left_color=$([[ $eye == left ]] && echo true || echo false)" \
        "enable_right_color=$([[ $eye == right ]] && echo true || echo false)" \
        "${eye}_color_width=$color_width" \
        "${eye}_color_height=$color_height" \
        "${eye}_color_rotation=$rotation" \
        "${eye}_color_fps=$FPS" \
        "${eye}_color_format=$format" \
        "${eye}_color.image_raw.enable_pub_plugins=[\"image_transport/compressed\"]" \
        "enable_depth=false" \
        "enable_left_ir=false" \
        "enable_right_ir=false"
    apply_wrist_color_settings "$output"
}

apply_wrist_color_settings() {
    local output="$1"

    apply_yaml_settings "$output" \
        "enable_color_auto_exposure_priority=false" \
        "enable_color_auto_white_balance=false" \
        "enable_color_auto_exposure=false" \
        "color_exposure=$WRIST_EXPOSURE" \
        "color_gain=$WRIST_GAIN" \
        "color_white_balance=$COLOR_WHITE_BALANCE" \
        "color_ae_max_exposure=$AE_MAX_EXPOSURE" \
        'color_powerline_freq="50hz"'
    set_yaml_key "$output" ae_reference_stream color device_preset
    set_yaml_key "$output" ae_strategy motion ae_reference_stream
    set_yaml_key "$output" color_anti_flicker true color_powerline_freq
}

start_background() {
    local name="$1"
    local logfile="$2"
    shift 2

    spawn_ros_process "$logfile" "$@"
    record_pid "$name" "$SPAWNED_PID"
    log "Started $name pid=$SPAWNED_PID log=$logfile"
}

ensure_zenoh_router() {
    local existing_pids
    existing_pids="$(pgrep -f '[r]mw_zenohd' || true)"
    if [[ -n "$existing_pids" ]]; then
        log "Using existing Zenoh router pid=$existing_pids"
        return 0
    fi

    spawn_ros_process "$LOG_DIR/rmw_zenohd.log" ros2 run rmw_zenoh_cpp rmw_zenohd
    log "Started Zenoh router pid=$SPAWNED_PID log=$LOG_DIR/rmw_zenohd.log"
}

wait_for_topic_once() {
    local topic="$1"
    local deadline=$((SECONDS + WAIT_TIMEOUT))

    log "Waiting for $topic ..."
    while (( SECONDS < deadline )); do
        if timeout 6s ros2 topic echo --once "$topic" >/dev/null 2>&1; then
            log "OK: $topic"
            return 0
        fi
        sleep 2
    done

    log "ERROR: timeout waiting for $topic"
    log "Logs are in $LOG_DIR"
    return 1
}

scan_devices() {
    log "Scanning Orbbec devices..."
    ros2 run orbbec_camera list_devices_node > "$LOG_DIR/list_devices.txt" 2>&1 || {
        log "ERROR: failed to scan devices"
        cat "$LOG_DIR/list_devices.txt"
        exit 1
    }
    parse_detected_devices
    print_detected_devices
    confirm_partial_camera_set
    select_role_configuration
}

# resolve_role <label> <serial> <found_var> <usb_port_var>
resolve_role() {
    local label="$1"
    local serial="$2"
    local -n found_ref="$3"
    local -n usb_port_ref="$4"

    found_ref=0
    usb_port_ref=""
    if [[ -z "$serial" ]]; then
        log "$label: 未配置，本次跳过。"
        return 0
    fi
    if ! has_serial "$serial"; then
        warn_missing_serial "$label" "$serial"
        return 0
    fi

    found_ref=1
    usb_port_ref="$(usb_port_for_serial "$serial")"
    log "$label: 型号=$(model_for_serial "$serial") 序列号=${GREEN}${serial}${RESET} 连接=${GREEN}$(connection_for_serial "$serial")${RESET} 端口=${GREEN}${usb_port_ref}${RESET}"
}

resolve_active_cameras() {
    log ""
    log "${GREEN}本次启用的相机配置：${RESET}"
    resolve_role "左腕" "$LEFT_WRIST_SERIAL" HAS_LEFT LEFT_USB_PORT
    resolve_role "右腕" "$RIGHT_WRIST_SERIAL" HAS_RIGHT RIGHT_USB_PORT
    resolve_role "头部" "$HEAD_SERIAL" HAS_HEAD HEAD_USB_PORT

    if (( HAS_LEFT == 0 && HAS_RIGHT == 0 && HAS_HEAD == 0 )); then
        log "ERROR: no configured cameras found"
        log "Connected devices:"
        cat "$LOG_DIR/list_devices.txt"
        exit 1
    fi
}

# start_wrist <name> <eye> <serial> <usb_port> <rotation> <runtime_config> <topic>
start_wrist() {
    local name="$1"
    local eye="$2"
    local serial="$3"
    local usb_port="$4"
    local rotation="$5"
    local runtime_config="$6"
    local topic="$7"

    make_gemini305_config "$runtime_config" "$serial" "$usb_port" "$eye" "$rotation"
    start_background "$name" "$LOG_DIR/$name.log" \
        ros2 launch orbbec_camera gemini305.launch.py \
        camera_name:="$name" \
        serial_number:="$serial" \
        usb_port:="$usb_port" \
        config_file_path:="$runtime_config"
    wait_for_topic_once "$topic"
}

start_head() {
    local head_width
    local head_height
    read -r head_width head_height < <(dimensions_for_rotation "$HEAD_ROTATION")

    start_background "camera_head" "$LOG_DIR/camera_head.log" \
        ros2 launch orbbec_camera gemini_330_series.launch.py \
        camera_name:=camera_head \
        serial_number:="$HEAD_SERIAL" \
        usb_port:="$HEAD_USB_PORT" \
        enable_color:=true \
        color_width:="$head_width" \
        color_height:="$head_height" \
        color_rotation:="$HEAD_ROTATION" \
        color_fps:="$FPS" \
        enable_color_auto_exposure_priority:=false \
        enable_color_auto_exposure:=true \
        enable_color_auto_white_balance:=false \
        color_exposure:=-1 \
        color_gain:=-1 \
        color_white_balance:="$COLOR_WHITE_BALANCE" \
        color_ae_max_exposure:="$AE_MAX_EXPOSURE" \
        color_anti_flicker:=true \
        color_powerline_freq:=50hz \
        'color.image_raw.enable_pub_plugins:=["image_transport/compressed"]' \
        enable_depth:=false \
        enable_left_ir:=false \
        enable_right_ir:=false \
        enable_point_cloud:=false
    wait_for_topic_once "$HEAD_TOPIC"
}

start_cameras() {
    if (( HAS_LEFT == 1 )); then
        start_wrist camera_left_wrist left "$LEFT_WRIST_SERIAL" "$LEFT_USB_PORT" \
            "$LEFT_WRIST_ROTATION" "$LEFT_RUNTIME_CONFIG" "$LEFT_TOPIC"
    fi
    if (( HAS_RIGHT == 1 )); then
        start_wrist camera_right_wrist right "$RIGHT_WRIST_SERIAL" "$RIGHT_USB_PORT" \
            "$RIGHT_WRIST_ROTATION" "$RIGHT_RUNTIME_CONFIG" "$RIGHT_TOPIC"
    fi
    if (( HAS_HEAD == 1 )); then
        start_head
    fi
}

print_ready_topics() {
    log ""
    log "Camera topics ready:"
    (( HAS_LEFT == 0 )) || log "  $LEFT_TOPIC"
    (( HAS_RIGHT == 0 )) || log "  $RIGHT_TOPIC"
    (( HAS_HEAD == 0 )) || log "  $HEAD_TOPIC"
    log ""
    log "Use killcam to stop them. Logs: $LOG_DIR"
}

main() {
    require_file "$ORBBEC_WS/install/setup.bash"
    require_file "$ORBBEC_WS/orbbec_camera/launch/gemini305.launch.py"
    require_file "$ORBBEC_WS/orbbec_camera/launch/gemini_330_series.launch.py"
    ensure_usb_permissions

    stop_old_camera_processes
    source_ros_workspace

    scan_devices
    resolve_active_cameras
    ensure_zenoh_router
    start_cameras
    print_ready_topics
}

run_camera() {
    init_runtime_dir
    LEFT_RUNTIME_CONFIG="$RUNTIME_DIR/gemini305_left_wrist_runtime.yaml"
    RIGHT_RUNTIME_CONFIG="$RUNTIME_DIR/gemini305_right_wrist_runtime.yaml"

    select_startup_mode
    if (( BUILD_FIRST )); then
        build_driver
    fi
    if [[ ! -f "$ORBBEC_WS/install/setup.bash" ]]; then
        log "ERROR: 尚未编译相机驱动，请运行 ./quick_start.sh 选择「启动相机」 并选择 2（首次配置）。"
        return 1
    fi
    select_frame_rate
    main
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    run_camera
fi
