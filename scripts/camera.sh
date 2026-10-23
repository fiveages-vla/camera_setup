#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_DIR="$(dirname -- "$SCRIPT_DIR")"
ORBBEC_WS="$REPO_DIR/OrbbecSDK_ROS2"

# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/roles.sh
source "$SCRIPT_DIR/lib/roles.sh"

FPS="${1:-}"
AE_MAX_EXPOSURE="${CAM_AE_MAX_EXPOSURE:-120}"
WRIST_EXPOSURE="${CAM_WRIST_EXPOSURE:-50}"
WRIST_GAIN="${CAM_WRIST_GAIN:-16}"
COLOR_WHITE_BALANCE="${CAM_COLOR_WHITE_BALANCE:-5600}"
WAIT_TIMEOUT="${CAM_WAIT_TIMEOUT:-180}"

RESOURCE_DIR="$REPO_DIR/resources"
WRIST_CONFIG_DIR="$RESOURCE_DIR/config"
WRIST_LAUNCH="$RESOURCE_DIR/launch/wrist.launch.py"

# Topic names never change: wrist.launch.py publishes the eye in use under
# <camera_name>/color, and the rotation angle does not affect the names.
LEFT_TOPIC="/camera_left_wrist/color/image_raw/compressed"
RIGHT_TOPIC="/camera_right_wrist/color/image_raw/compressed"
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
    local -a devs=()

    # Permissions only matter for USB cameras. GMSL cameras do not show up in lsusb,
    # so having no USB device is not an error here; scan_devices reports "no camera".
    if ! command -v lsusb >/dev/null 2>&1; then
        log "WARN: lsusb not found; skipping USB permission check (install usbutils for USB cameras)."
        return 0
    fi
    mapfile -t devs < <(lsusb | awk '/Orbbec|2bc5:/{printf "/dev/bus/usb/%s/%s\n",$2,$4}' | tr -d :)
    if [[ "${#devs[@]}" -eq 0 ]]; then
        return 0
    fi

    install_udev_rule
    for dev in "${devs[@]}"; do
        if [[ ! -e "$dev" ]]; then
            log "WARN: Orbbec USB device path disappeared: ${YELLOW}${dev}${RESET}"
            continue
        fi
        grant_usb_access "$dev"
    done
}

stop_old_camera_processes() {
    log "Stopping old camera processes..."
    stop_camera_processes
}

# Replace "key: value" in a yaml file. The key must already exist.
set_yaml_key() {
    local file="$1"
    local key="$2"
    local value="$3"

    grep -q "^${key}:" "$file" || { log "ERROR: key $key missing in $file"; return 1; }
    sed -i "s|^${key}:.*|${key}: ${value}|" "$file"
}

valid_config_token() {
    [[ "$1" =~ ^[A-Za-z0-9._:-]+$ ]]
}

# wrist_config_file <eye> <rotation> <fps>: print the yaml for gemini305.launch.py.
# Rotation 0 at 30 fps uses resources/config as is; otherwise a private copy with only
# *_rotation/*_fps changed goes to the runtime dir. Other params stay on the command line.
wrist_config_file() {
    local eye="$1"
    local rotation="$2"
    local fps="$3"
    local source="$WRIST_CONFIG_DIR/gemini305_${eye}_wrist.yaml"
    local output

    case "$eye" in left|right) ;; *) log "ERROR: unknown Gemini305 eye: $eye"; return 1 ;; esac
    valid_rotation_value "$rotation" || { log "ERROR: invalid rotation: $rotation"; return 1; }
    require_file "$source"
    if [[ "$rotation" == 0 && "$fps" == 30 ]]; then
        printf '%s\n' "$source"
        return 0
    fi

    output="$RUNTIME_DIR/gemini305_${eye}_wrist_${rotation}_${fps}.yaml"
    cp -- "$source" "$output"
    chmod 600 -- "$output"
    set_yaml_key "$output" "${eye}_color_rotation" "$rotation"
    set_yaml_key "$output" "${eye}_color_fps" "$fps"
    printf '%s\n' "$output"
}

# Color settings shared by both wrists, as launch arguments.
wrist_color_args() {
    printf '%s\n' \
        enable_color_auto_exposure_priority:=false \
        enable_color_auto_white_balance:=false \
        enable_color_auto_exposure:=false \
        color_exposure:="$WRIST_EXPOSURE" \
        color_gain:="$WRIST_GAIN" \
        color_white_balance:="$COLOR_WHITE_BALANCE" \
        color_ae_max_exposure:="$AE_MAX_EXPOSURE" \
        color_powerline_freq:=50hz \
        color_anti_flicker:=true \
        ae_reference_stream:=color \
        publish_tf:=false \
        diagnostic_period:=0.0 \
        ae_strategy:=motion
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
    pgrep -f '[r]mw_zenohd' >/dev/null && return 0

    spawn_ros_process "$LOG_DIR/rmw_zenohd.log" ros2 run rmw_zenoh_cpp rmw_zenohd
    log "Started Zenoh router pid=$SPAWNED_PID log=$LOG_DIR/rmw_zenohd.log"
}

wait_for_topic_once() {
    local topic="$1"
    local deadline=$((SECONDS + WAIT_TIMEOUT))

    log "Waiting for $topic ..."
    while (( SECONDS < deadline )); do
        if timeout -k 2 6s ros2 topic echo --once "$topic" >/dev/null 2>&1; then
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

# start_wrist <name> <eye> <serial> <usb_port> <rotation> <topic>
start_wrist() {
    local name="$1"
    local eye="$2"
    local serial="$3"
    local usb_port="$4"
    local rotation="$5"
    local topic="$6"
    local config
    local -a color_args

    valid_config_token "$serial" || { log "ERROR: invalid serial: $serial"; exit 1; }
    valid_config_token "$usb_port" || { log "ERROR: invalid USB port: $usb_port"; exit 1; }
    config="$(wrist_config_file "$eye" "$rotation" "$FPS")" || exit 1
    mapfile -t color_args < <(wrist_color_args)

    log "Gemini305 $serial: ${eye} eye, rotation ${rotation}°, exposure=$WRIST_EXPOSURE gain=$WRIST_GAIN white_balance=$COLOR_WHITE_BALANCE, config=$config"
    start_background "$name" "$LOG_DIR/$name.log" \
        ros2 launch "$WRIST_LAUNCH" \
        camera_name:="$name" \
        eye:="$eye" \
        serial_number:="$serial" \
        usb_port:="$usb_port" \
        config_file_path:="$config" \
        "${color_args[@]}"
    wait_for_topic_once "$topic"
}

# YUYV at 640x480 needs about 18 MB/s at 30 fps; 60 fps does not fit USB 2.
warn_usb2_frame_rate() {
    local label="$1"
    local connection="$2"

    if [[ "$FPS" == 60 && "$connection" == USB2* ]]; then
        log "WARN: $label 通过 $connection 连接，YUYV 60 Hz 可能超出 USB 2 带宽，建议改接 USB 3 口。"
    fi
}

start_head() {
    warn_usb2_frame_rate "头部" "$(connection_for_serial "$HEAD_SERIAL")"

    # The profile is always the native 640x480; the SDK frame processor rotates
    # the decoded frames, so the format must be uncompressed (not MJPG).
    start_background "camera_head" "$LOG_DIR/camera_head.log" \
        ros2 launch orbbec_camera gemini_330_series.launch.py \
        camera_name:=camera_head \
        serial_number:="$HEAD_SERIAL" \
        usb_port:="$HEAD_USB_PORT" \
        enable_color:=true \
        color_width:="$WIDTH" \
        color_height:="$HEIGHT" \
        color_format:=YUYV \
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
        enable_point_cloud:=false \
        publish_tf:=false \
        diagnostic_period:=0.0
    wait_for_topic_once "$HEAD_TOPIC"
}

start_cameras() {
    local eye

    if (( HAS_LEFT == 1 )); then
        warn_usb2_frame_rate "左腕" "$(connection_for_serial "$LEFT_WRIST_SERIAL")"
        eye="$(eye_for_rotation right "$LEFT_WRIST_ROTATION")"
        log "左腕: 旋转 ${LEFT_WRIST_ROTATION}° 使用${eye}目"
        start_wrist camera_left_wrist "$eye" "$LEFT_WRIST_SERIAL" "$LEFT_USB_PORT" \
            "$LEFT_WRIST_ROTATION" "$LEFT_TOPIC"
    fi
    if (( HAS_RIGHT == 1 )); then
        warn_usb2_frame_rate "右腕" "$(connection_for_serial "$RIGHT_WRIST_SERIAL")"
        eye="$(eye_for_rotation right "$RIGHT_WRIST_ROTATION")"
        log "右腕: 旋转 ${RIGHT_WRIST_ROTATION}° 使用${eye}目"
        start_wrist camera_right_wrist "$eye" "$RIGHT_WRIST_SERIAL" "$RIGHT_USB_PORT" \
            "$RIGHT_WRIST_ROTATION" "$RIGHT_TOPIC"
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
    require_file "$WRIST_LAUNCH"
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

    if [[ ! -f "$ORBBEC_WS/install/setup.bash" ]]; then
        log "ERROR: 尚未编译相机驱动，请先运行 ./quick_start.sh 选择 1（安装依赖并编译）。"
        return 1
    fi
    select_frame_rate
    main
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    run_camera
fi
