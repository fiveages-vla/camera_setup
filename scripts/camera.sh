#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_DIR="$(dirname -- "$SCRIPT_DIR")"
ORBBEC_WS="$REPO_DIR/OrbbecSDK_ROS2"
WRIST_LAUNCH="$SCRIPT_DIR/launch/gemini305.launch.py"
LOG_DIR="/tmp/camera_logs"
PID_FILE="/tmp/camera_pids.txt"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/camup"
ROLE_CONFIG="$CONFIG_DIR/camera_roles.conf"
LEFT_WRIST_SERIAL=""
RIGHT_WRIST_SERIAL=""
HEAD_SERIAL=""

declare -a DEVICE_MODELS=()
declare -a DEVICE_SERIALS=()
declare -a DEVICE_CONNECTIONS=()
declare -a DEVICE_USB_PORTS=()

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

WIDTH=640
HEIGHT=480
FPS="${1:-}"
AE_MAX_EXPOSURE="${CAM_AE_MAX_EXPOSURE:-120}"
WRIST_EXPOSURE="${CAM_WRIST_EXPOSURE:-50}"
WRIST_GAIN="${CAM_WRIST_GAIN:-16}"
COLOR_WHITE_BALANCE="${CAM_COLOR_WHITE_BALANCE:-5600}"
WAIT_TIMEOUT="${CAM_WAIT_TIMEOUT:-180}"

LEFT_RUNTIME_CONFIG="/tmp/gemini305_left_wrist_runtime.yaml"
RIGHT_RUNTIME_CONFIG="/tmp/gemini305_right_wrist_runtime.yaml"

LEFT_TOPIC="/camera_left_wrist/color/image_raw/compressed"
RIGHT_TOPIC="/camera_right_wrist/color/image_raw/compressed"
HEAD_TOPIC="/camera_head/color/image_raw/compressed"

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

mkdir -p "$LOG_DIR"

log() {
    printf '%s\n' "$*"
}

ensure_usb_permissions() {
    local rule_src="$ORBBEC_WS/orbbec_camera/scripts/99-obsensor-libusb.rules"
    local rule_dst="/etc/udev/rules.d/99-obsensor-libusb.rules"
    local dev
    local devs
    local listing
    local listing_prefix

    mapfile -t devs < <(lsusb | awk '/Orbbec|2bc5:/{printf "/dev/bus/usb/%s/%s\n",$2,$4}' | tr -d :)
    if [[ "${#devs[@]}" -eq 0 ]]; then
        log "ERROR: Orbbec camera not found. Plug in the cameras first."
        return 1
    fi

    if [[ ! -f "$rule_dst" ]]; then
        if [[ ! -f "$rule_src" ]]; then
            log "ERROR: Orbbec udev rule not found: $rule_src"
            return 1
        fi
        log "Installing Orbbec udev rule. sudo may ask for your password."
        sudo cp "$rule_src" "$rule_dst"
        sudo udevadm control --reload-rules
        sudo udevadm trigger
        sleep 1
    fi

    for dev in "${devs[@]}"; do
        if [[ ! -e "$dev" ]]; then
            log "WARN: Orbbec USB device path disappeared: ${YELLOW}${dev}${RESET}"
            continue
        fi

        if [[ ! -w "$dev" ]]; then
            log "Orbbec USB device is not writable yet: ${YELLOW}${dev}${RESET}"
            log "Reloading udev rules. sudo may ask for your password."
            sudo udevadm control --reload-rules
            sudo udevadm trigger
            sleep 1
        fi

        if [[ ! -w "$dev" ]]; then
            log "Applying temporary permission fallback to ${YELLOW}${dev}${RESET}. sudo may ask for your password."
            sudo chmod a+rw "$dev"
        fi

        listing="$(ls -l -- "$dev")"
        listing_prefix="${listing% "$dev"}"
        printf '%s %s%s%s\n' "$listing_prefix" "$YELLOW" "$dev" "$RESET"
    done
}

source_ros() {
    set +u
    unset AMENT_PREFIX_PATH CMAKE_PREFIX_PATH COLCON_PREFIX_PATH LD_LIBRARY_PATH PYTHONPATH
    source /opt/ros/jazzy/setup.bash
    source "$ORBBEC_WS/install/setup.bash"
    set -u
    export RMW_IMPLEMENTATION="${RMW_IMPLEMENTATION:-rmw_zenoh_cpp}"
    export ROS_DOMAIN_ID="${ROS_DOMAIN_ID:-16}"
}

record_pid() {
    printf '%s:%s\n' "$1" "$2" >> "$PID_FILE"
}

stop_old_camera_processes() {
    log "Stopping old camera processes..."

    if [[ -f "$PID_FILE" ]]; then
        awk -F: '$1 !~ /^zenoh/ {print $2}' "$PID_FILE" | xargs -r kill 2>/dev/null || true
        sleep 1
        awk -F: '$1 !~ /^zenoh/ {print $2}' "$PID_FILE" | xargs -r kill -9 2>/dev/null || true
    fi

    pkill -f 'gemini305.launch.py|gemini_330_series.launch.py|relay_compressed_image.py|component_container' 2>/dev/null || true
    : > "$PID_FILE"
}

require_file() {
    if [[ ! -f "$1" ]]; then
        log "ERROR: missing file: $1"
        exit 1
    fi
}

parse_detected_devices() {
    local line
    local model=""
    local serial=""
    local connection=""
    local usb_port=""

    DEVICE_MODELS=()
    DEVICE_SERIALS=()
    DEVICE_CONNECTIONS=()
    DEVICE_USB_PORTS=()

    while IFS= read -r line; do
        case "$line" in
            *"name: "*)
                model="${line##*name: }"
                ;;
            *"serial: "*)
                serial="${line##*serial: }"
                ;;
            *"connection: "*)
                connection="${line##*connection: }"
                ;;
            *"usb port: "*)
                usb_port="${line##*usb port: }"
                if [[ -n "$model" && -n "$serial" && -n "$usb_port" ]]; then
                    DEVICE_MODELS+=("$model")
                    DEVICE_SERIALS+=("$serial")
                    DEVICE_CONNECTIONS+=("${connection:-unknown}")
                    DEVICE_USB_PORTS+=("$usb_port")
                fi
                model=""
                serial=""
                connection=""
                usb_port=""
                ;;
        esac
    done < "$LOG_DIR/list_devices.txt"

    if (( ${#DEVICE_SERIALS[@]} == 0 )); then
        log "ERROR: no Orbbec device details found in scan output"
        return 1
    fi
}

print_detected_devices() {
    local index

    log ""
    log "${YELLOW}本次检测到 ${#DEVICE_SERIALS[@]} 台 Orbbec 相机：${RESET}"
    for index in "${!DEVICE_SERIALS[@]}"; do
        printf '  [%d] 型号: %s | 序列号: %s%s%s | 连接: %s%s%s | USB口: %s%s%s\n' \
            "$((index + 1))" \
            "${DEVICE_MODELS[$index]}" \
            "$YELLOW" \
            "${DEVICE_SERIALS[$index]}" \
            "$RESET" \
            "$YELLOW" \
            "${DEVICE_CONNECTIONS[$index]}" \
            "$RESET" \
            "$YELLOW" \
            "${DEVICE_USB_PORTS[$index]}" \
            "$RESET"
    done
    log ""
}

confirm_partial_camera_set() {
    local choice
    local count="${#DEVICE_SERIALS[@]}"

    (( count < 3 )) || return 0

    log ""
    log "${YELLOW}!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!${RESET}"
    log "${YELLOW}[WARNING] CAMERA COUNT: $count / 3${RESET}"
    log "${YELLOW}[WARNING] 正常配置需要 3 台相机，本次只检测到 $count 台。${RESET}"
    log "${YELLOW}[WARNING] 继续启动将缺少一个或多个相机话题。${RESET}"
    log "${YELLOW}!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!${RESET}"
    if [[ ! -t 0 ]]; then
        log "ERROR: 少于 3 台相机时必须在交互终端确认后才能继续。"
        return 1
    fi

    while true; do
        read -r -p "确认只使用这 $count 台相机启动吗？[y/N]: " choice
        case "$choice" in
            y|Y|yes|YES|是)
                return 0
                ;;
            ''|n|N|no|NO|否)
                log "已取消启动。"
                return 1
                ;;
            *)
                printf '请输入 y 或 n。\n' >&2
                ;;
        esac
    done
}

device_index_for_serial() {
    local serial="$1"
    local index

    for index in "${!DEVICE_SERIALS[@]}"; do
        if [[ "${DEVICE_SERIALS[$index]}" == "$serial" ]]; then
            printf '%s\n' "$index"
            return 0
        fi
    done
    return 1
}

has_serial() {
    device_index_for_serial "$1" >/dev/null
}

usb_port_for_serial() {
    local index
    index="$(device_index_for_serial "$1")" || return 1
    printf '%s\n' "${DEVICE_USB_PORTS[$index]}"
}

model_for_serial() {
    local index
    index="$(device_index_for_serial "$1")" || return 1
    printf '%s\n' "${DEVICE_MODELS[$index]}"
}

connection_for_serial() {
    local index
    index="$(device_index_for_serial "$1")" || return 1
    printf '%s\n' "${DEVICE_CONNECTIONS[$index]}"
}

read_role_config_value() {
    local key="$1"
    awk -F= -v key="$key" '$1 == key {sub(/^[^=]*=/, ""); print; exit}' "$ROLE_CONFIG"
}

valid_serial_value() {
    [[ -z "$1" || "$1" =~ ^[A-Za-z0-9._-]+$ ]]
}

load_role_config() {
    [[ -f "$ROLE_CONFIG" ]] || return 1

    LEFT_WRIST_SERIAL="$(read_role_config_value left_wrist)"
    RIGHT_WRIST_SERIAL="$(read_role_config_value right_wrist)"
    HEAD_SERIAL="$(read_role_config_value head)"

    valid_serial_value "$LEFT_WRIST_SERIAL" || return 1
    valid_serial_value "$RIGHT_WRIST_SERIAL" || return 1
    valid_serial_value "$HEAD_SERIAL" || return 1
    [[ -n "$LEFT_WRIST_SERIAL" || -n "$RIGHT_WRIST_SERIAL" || -n "$HEAD_SERIAL" ]] || return 1
    [[ -z "$LEFT_WRIST_SERIAL" || -z "$RIGHT_WRIST_SERIAL" || "$LEFT_WRIST_SERIAL" != "$RIGHT_WRIST_SERIAL" ]] || return 1
    [[ -z "$LEFT_WRIST_SERIAL" || -z "$HEAD_SERIAL" || "$LEFT_WRIST_SERIAL" != "$HEAD_SERIAL" ]] || return 1
    [[ -z "$RIGHT_WRIST_SERIAL" || -z "$HEAD_SERIAL" || "$RIGHT_WRIST_SERIAL" != "$HEAD_SERIAL" ]] || return 1
}

print_role() {
    local label="$1"
    local serial="$2"
    local color="$3"
    local model
    local connection
    local usb_port

    if [[ -z "$serial" ]]; then
        printf '  %-6s %s未配置%s\n' "$label:" "$color" "$RESET"
        return 0
    fi

    if model="$(model_for_serial "$serial")"; then
        connection="$(connection_for_serial "$serial")"
        usb_port="$(usb_port_for_serial "$serial")"
        printf '  %-6s 型号: %s | 序列号: %s%s%s | 连接: %s%s%s | USB口: %s%s%s\n' \
            "$label:" "$model" "$color" "$serial" "$RESET" \
            "$color" "$connection" "$RESET" "$color" "$usb_port" "$RESET"
    else
        printf '  %-6s 序列号: %s%s%s（当前未连接）\n' "$label:" "$color" "$serial" "$RESET"
    fi
}

print_saved_roles() {
    log "${CYAN}上次保存的相机角色配置：${RESET}"
    print_role "左腕" "$LEFT_WRIST_SERIAL" "$CYAN"
    print_role "右腕" "$RIGHT_WRIST_SERIAL" "$CYAN"
    print_role "头部" "$HEAD_SERIAL" "$CYAN"
}

model_matches_role() {
    local role="$1"
    local model="$2"

    case "$role" in
        left_wrist|right_wrist)
            [[ "$model" == *"Gemini 305"* ]]
            ;;
        head)
            [[ "$model" == *"Gemini 33"* && "$model" != *"Gemini 305"* ]]
            ;;
        *)
            return 1
            ;;
    esac
}

prompt_for_role() {
    local role="$1"
    local label="$2"
    local choice
    local index
    local serial
    local model

    while true; do
        read -r -p "请选择${label}相机编号: " choice
        if [[ ! "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#DEVICE_SERIALS[@]} )); then
            printf '无效编号，请输入 1-%d。\n' "${#DEVICE_SERIALS[@]}" >&2
            continue
        fi

        index=$((choice - 1))
        serial="${DEVICE_SERIALS[$index]}"
        model="${DEVICE_MODELS[$index]}"

        if ! model_matches_role "$role" "$model"; then
            if [[ "$role" == "head" ]]; then
                printf '%s 不能作为头部相机；头部需要 Gemini 330 系列。\n' "$model" >&2
            else
                printf '%s 不能作为腕部相机；腕部需要 Gemini 305。\n' "$model" >&2
            fi
            continue
        fi

        if [[ "$serial" == "$LEFT_WRIST_SERIAL" || "$serial" == "$RIGHT_WRIST_SERIAL" || "$serial" == "$HEAD_SERIAL" ]]; then
            printf '该相机已经分配给其他位置，请重新选择。\n' >&2
            continue
        fi

        case "$role" in
            left_wrist) LEFT_WRIST_SERIAL="$serial" ;;
            right_wrist) RIGHT_WRIST_SERIAL="$serial" ;;
            head) HEAD_SERIAL="$serial" ;;
        esac
        return 0
    done
}

prompt_role_for_device() {
    local index="$1"
    local choice
    local role
    local serial="${DEVICE_SERIALS[$index]}"
    local model="${DEVICE_MODELS[$index]}"

    printf '\n为相机 [%d] 分配位置：型号: %s | 序列号: %s%s%s | 连接: %s%s%s | USB口: %s%s%s\n' \
        "$((index + 1))" "$model" "$YELLOW" "$serial" "$RESET" \
        "$YELLOW" "${DEVICE_CONNECTIONS[$index]}" "$RESET" \
        "$YELLOW" "${DEVICE_USB_PORTS[$index]}" "$RESET"

    while true; do
        printf '  1) 左腕\n'
        printf '  2) 右腕\n'
        printf '  3) 头部\n'
        read -r -p '请选择位置 [1-3]: ' choice

        case "$choice" in
            1) role="left_wrist" ;;
            2) role="right_wrist" ;;
            3) role="head" ;;
            *) printf '无效选项，请输入 1、2 或 3。\n' >&2; continue ;;
        esac

        if ! model_matches_role "$role" "$model"; then
            if [[ "$role" == "head" ]]; then
                printf '%s 不能作为头部相机；头部需要 Gemini 330 系列。\n' "$model" >&2
            else
                printf '%s 不能作为腕部相机；腕部需要 Gemini 305。\n' "$model" >&2
            fi
            continue
        fi

        case "$role" in
            left_wrist)
                [[ -z "$LEFT_WRIST_SERIAL" ]] || { printf '左腕已经分配，请选择其他位置。\n' >&2; continue; }
                LEFT_WRIST_SERIAL="$serial"
                ;;
            right_wrist)
                [[ -z "$RIGHT_WRIST_SERIAL" ]] || { printf '右腕已经分配，请选择其他位置。\n' >&2; continue; }
                RIGHT_WRIST_SERIAL="$serial"
                ;;
            head)
                [[ -z "$HEAD_SERIAL" ]] || { printf '头部已经分配，请选择其他位置。\n' >&2; continue; }
                HEAD_SERIAL="$serial"
                ;;
        esac
        return 0
    done
}

save_role_config() {
    local temp_config

    mkdir -p "$CONFIG_DIR"
    temp_config="$(mktemp "$CONFIG_DIR/.camera_roles.conf.XXXXXX")"
    {
        printf '# camup camera role mapping\n'
        printf 'left_wrist=%s\n' "$LEFT_WRIST_SERIAL"
        printf 'right_wrist=%s\n' "$RIGHT_WRIST_SERIAL"
        printf 'head=%s\n' "$HEAD_SERIAL"
    } > "$temp_config"
    chmod 600 "$temp_config"
    mv "$temp_config" "$ROLE_CONFIG"
    log "配置已保存到 $ROLE_CONFIG"
}

configure_roles() {
    if [[ ! -t 0 ]]; then
        log "ERROR: no saved camera configuration; run camup in an interactive terminal"
        return 1
    fi

    LEFT_WRIST_SERIAL=""
    RIGHT_WRIST_SERIAL=""
    HEAD_SERIAL=""

    log "请根据上面的型号和序列号分配相机位置。"
    if (( ${#DEVICE_SERIALS[@]} < 3 )); then
        local index
        for index in "${!DEVICE_SERIALS[@]}"; do
            prompt_role_for_device "$index"
        done
    else
        prompt_for_role left_wrist "左腕"
        prompt_for_role right_wrist "右腕"
        prompt_for_role head "头部"
    fi
    save_role_config
    print_saved_roles
}

select_role_configuration() {
    local choice

    if load_role_config; then
        print_saved_roles
        if [[ ! -t 0 ]]; then
            log "非交互启动，自动使用上次配置。"
            return 0
        fi

        while true; do
            printf '\n请选择启动配置：\n'
            printf '  1) 使用上次配置（默认）\n'
            printf '  2) 重新检测并填写相机位置\n'
            read -r -p '请输入选项 [1-2]: ' choice
            case "$choice" in
                ''|1) return 0 ;;
                2) configure_roles; return ;;
                *) printf '无效选项，请输入 1 或 2。\n' >&2 ;;
            esac
        done
    fi

    if [[ -f "$ROLE_CONFIG" ]]; then
        log "WARN: saved camera configuration is invalid; configure it again"
    else
        log "没有保存过相机角色配置，开始首次配置。"
    fi
    configure_roles
}

warn_missing_serial() {
    local label="$1"
    local serial="$2"
    log "WARN: $label serial not found, skipping it: $serial"
}

make_gemini305_config() {
    local output="$1"
    local serial="$2"
    local usb_port="$3"
    local eye="$4"
    local template="$ORBBEC_WS/orbbec_camera/config/gemini305_dual_color.yaml"
    local enable_left=false
    local enable_right=false
    local left_color_format=ANY
    local right_color_format=ANY

    case "$eye" in
        left)
            enable_left=true
            left_color_format=MJPG
            ;;
        right)
            enable_right=true
            right_color_format=YUYV
            ;;
        *) log "ERROR: unknown Gemini305 eye: $eye"; exit 1 ;;
    esac

    log "Gemini305 $serial: fixed wrist exposure=$WRIST_EXPOSURE gain=$WRIST_GAIN white_balance=$COLOR_WHITE_BALANCE"
    require_file "$template"
    cp "$template" "$output"
    sed -i \
        -e 's/^camera_name:.*/camera_name: camera/' \
        -e "s/^serial_number:.*/serial_number: \"$serial\"/" \
        -e "s/^usb_port:.*/usb_port: \"$usb_port\"/" \
        -e 's/^enable_color:.*/enable_color: false/' \
        -e "s/^ae_reference_stream:.*/ae_reference_stream: color/" \
        -e "s/^ae_strategy:.*/ae_strategy: motion/" \
        -e "s/^enable_left_color:.*/enable_left_color: $enable_left/" \
        -e 's/^left_color_width:.*/left_color_width: 640/' \
        -e 's/^left_color_height:.*/left_color_height: 480/' \
        -e "s/^left_color_fps:.*/left_color_fps: $FPS/" \
        -e "s/^left_color_format:.*/left_color_format: $left_color_format/" \
        -e "s/^enable_right_color:.*/enable_right_color: $enable_right/" \
        -e 's/^right_color_width:.*/right_color_width: 640/' \
        -e 's/^right_color_height:.*/right_color_height: 480/' \
        -e "s/^right_color_fps:.*/right_color_fps: $FPS/" \
        -e "s/^right_color_format:.*/right_color_format: $right_color_format/" \
        -e 's/^enable_color_auto_exposure_priority:.*/enable_color_auto_exposure_priority: false/' \
        -e 's/^enable_color_auto_white_balance:.*/enable_color_auto_white_balance: false/' \
        -e 's/^enable_color_auto_exposure:.*/enable_color_auto_exposure: false/' \
        -e "s/^color_exposure:.*/color_exposure: $WRIST_EXPOSURE/" \
        -e "s/^color_gain:.*/color_gain: $WRIST_GAIN/" \
        -e "s/^color_white_balance:.*/color_white_balance: $COLOR_WHITE_BALANCE/" \
        -e "s/^color_ae_max_exposure:.*/color_ae_max_exposure: $AE_MAX_EXPOSURE/" \
        -e 's/^color_powerline_freq:.*/color_powerline_freq: "50hz"/' \
        -e 's|^left_color.image_raw.enable_pub_plugins:.*|left_color.image_raw.enable_pub_plugins: ["image_transport/compressed"]|' \
        -e 's|^right_color.image_raw.enable_pub_plugins:.*|right_color.image_raw.enable_pub_plugins: ["image_transport/compressed"]|' \
        -e 's/^enable_depth:.*/enable_depth: false/' \
        -e 's/^enable_left_ir:.*/enable_left_ir: false/' \
        -e 's/^enable_right_ir:.*/enable_right_ir: false/' \
        "$output"

    if grep -q '^ae_reference_stream:' "$output"; then
        sed -i 's/^ae_reference_stream:.*/ae_reference_stream: color/' "$output"
    else
        sed -i '/^device_preset:/a ae_reference_stream: color' "$output"
    fi

    if grep -q '^ae_strategy:' "$output"; then
        sed -i 's/^ae_strategy:.*/ae_strategy: motion/' "$output"
    else
        sed -i '/^ae_reference_stream:/a ae_strategy: motion' "$output"
    fi

    if grep -q '^color_anti_flicker:' "$output"; then
        sed -i 's/^color_anti_flicker:.*/color_anti_flicker: true/' "$output"
    else
        sed -i '/^color_powerline_freq:/a color_anti_flicker: true' "$output"
    fi
}

start_background() {
    local name="$1"
    local logfile="$2"
    shift 2

    nohup bash --noprofile --norc -c "
set -Ee
set +u
unset AMENT_PREFIX_PATH CMAKE_PREFIX_PATH COLCON_PREFIX_PATH LD_LIBRARY_PATH PYTHONPATH
source /opt/ros/jazzy/setup.bash
source '$ORBBEC_WS/install/setup.bash'
set -u
export RMW_IMPLEMENTATION='${RMW_IMPLEMENTATION:-rmw_zenoh_cpp}'
export ROS_DOMAIN_ID='${ROS_DOMAIN_ID:-16}'
exec \"\$@\"
" bash "$@" > "$logfile" 2>&1 &

    local pid=$!
    record_pid "$name" "$pid"
    log "Started $name pid=$pid log=$logfile"
}

ensure_zenoh_router() {
    local existing_pids
    existing_pids="$(pgrep -f '[r]mw_zenohd' || true)"
    if [[ -n "$existing_pids" ]]; then
        log "Using existing Zenoh router pid=$existing_pids"
        return 0
    fi

    nohup bash --noprofile --norc -c "
set -Ee
set +u
unset AMENT_PREFIX_PATH CMAKE_PREFIX_PATH COLCON_PREFIX_PATH LD_LIBRARY_PATH PYTHONPATH
source /opt/ros/jazzy/setup.bash
source '$ORBBEC_WS/install/setup.bash'
set -u
export RMW_IMPLEMENTATION='${RMW_IMPLEMENTATION:-rmw_zenoh_cpp}'
export ROS_DOMAIN_ID='${ROS_DOMAIN_ID:-16}'
exec ros2 run rmw_zenoh_cpp rmw_zenohd
" > "$LOG_DIR/rmw_zenohd.log" 2>&1 &

    local pid=$!
    log "Started Zenoh router pid=$pid log=$LOG_DIR/rmw_zenohd.log"
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

main() {
    require_file "$ORBBEC_WS/install/setup.bash"
    require_file "$WRIST_LAUNCH"
    ensure_usb_permissions
    require_file "$ORBBEC_WS/orbbec_camera/launch/gemini305.launch.py"
    require_file "$ORBBEC_WS/orbbec_camera/launch/gemini_330_series.launch.py"

    stop_old_camera_processes
    source_ros

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

    local has_left=0
    local has_right=0
    local has_head=0
    local left_usb_port=""
    local right_usb_port=""
    local head_usb_port=""

    log ""
    log "${GREEN}本次启用的相机配置：${RESET}"

    if [[ -z "$LEFT_WRIST_SERIAL" ]]; then
        log "左腕: 未配置，本次跳过。"
    elif has_serial "$LEFT_WRIST_SERIAL"; then
        has_left=1
        left_usb_port="$(usb_port_for_serial "$LEFT_WRIST_SERIAL")"
        log "左腕: 型号=$(model_for_serial "$LEFT_WRIST_SERIAL") 序列号=${GREEN}${LEFT_WRIST_SERIAL}${RESET} 连接=${GREEN}$(connection_for_serial "$LEFT_WRIST_SERIAL")${RESET} USB口=${GREEN}${left_usb_port}${RESET}"
    else
        warn_missing_serial "left wrist" "$LEFT_WRIST_SERIAL"
    fi

    if [[ -z "$RIGHT_WRIST_SERIAL" ]]; then
        log "右腕: 未配置，本次跳过。"
    elif has_serial "$RIGHT_WRIST_SERIAL"; then
        has_right=1
        right_usb_port="$(usb_port_for_serial "$RIGHT_WRIST_SERIAL")"
        log "右腕: 型号=$(model_for_serial "$RIGHT_WRIST_SERIAL") 序列号=${GREEN}${RIGHT_WRIST_SERIAL}${RESET} 连接=${GREEN}$(connection_for_serial "$RIGHT_WRIST_SERIAL")${RESET} USB口=${GREEN}${right_usb_port}${RESET}"
    else
        warn_missing_serial "right wrist" "$RIGHT_WRIST_SERIAL"
    fi

    if [[ -z "$HEAD_SERIAL" ]]; then
        log "头部: 未配置，本次跳过。"
    elif has_serial "$HEAD_SERIAL"; then
        has_head=1
        head_usb_port="$(usb_port_for_serial "$HEAD_SERIAL")"
        log "头部: 型号=$(model_for_serial "$HEAD_SERIAL") 序列号=${GREEN}${HEAD_SERIAL}${RESET} 连接=${GREEN}$(connection_for_serial "$HEAD_SERIAL")${RESET} USB口=${GREEN}${head_usb_port}${RESET}"
    else
        warn_missing_serial "head" "$HEAD_SERIAL"
    fi

    if (( has_left == 0 && has_right == 0 && has_head == 0 )); then
        log "ERROR: no configured cameras found"
        log "Connected devices:"
        cat "$LOG_DIR/list_devices.txt"
        exit 1
    fi

    ensure_zenoh_router

    if (( has_left == 1 )); then
        make_gemini305_config "$LEFT_RUNTIME_CONFIG" "$LEFT_WRIST_SERIAL" "$left_usb_port" left
        start_background "camera_left_wrist" "$LOG_DIR/camera_left_wrist.log" \
            ros2 launch "$WRIST_LAUNCH" \
            camera_name:=camera_left_wrist \
            serial_number:="$LEFT_WRIST_SERIAL" \
            usb_port:="$left_usb_port" \
            config_file_path:="$LEFT_RUNTIME_CONFIG"
        wait_for_topic_once "$LEFT_TOPIC"
    fi

    if (( has_right == 1 )); then
        make_gemini305_config "$RIGHT_RUNTIME_CONFIG" "$RIGHT_WRIST_SERIAL" "$right_usb_port" right
        start_background "camera_right_wrist" "$LOG_DIR/camera_right_wrist.log" \
            ros2 launch "$WRIST_LAUNCH" \
            camera_name:=camera_right_wrist \
            serial_number:="$RIGHT_WRIST_SERIAL" \
            usb_port:="$right_usb_port" \
            config_file_path:="$RIGHT_RUNTIME_CONFIG"
        wait_for_topic_once "$RIGHT_TOPIC"
    fi

    if (( has_head == 1 )); then
        start_background "camera_head" "$LOG_DIR/camera_head.log" \
            ros2 launch orbbec_camera gemini_330_series.launch.py \
            camera_name:=camera_head \
            serial_number:="$HEAD_SERIAL" \
            usb_port:="$head_usb_port" \
            enable_color:=true \
            color_width:="$WIDTH" \
            color_height:="$HEIGHT" \
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
    fi

    log ""
    log "Camera topics ready:"
    (( has_left == 1 )) && log "  $LEFT_TOPIC"
    (( has_right == 1 )) && log "  $RIGHT_TOPIC"
    (( has_head == 1 )) && log "  $HEAD_TOPIC"
    log ""
    log "Use killcam to stop them. Logs: $LOG_DIR"
}

run_camera() {
    if [[ ! -f "$ORBBEC_WS/install/setup.bash" ]]; then
        log "ERROR: 尚未编译相机驱动，请运行 ./quick_start.sh 选择 1（安装依赖并编译）。"
        return 1
    fi
    select_frame_rate
    main
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    run_camera
fi
