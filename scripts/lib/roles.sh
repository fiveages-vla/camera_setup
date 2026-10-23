#!/usr/bin/env bash
# Camera role assignment (left wrist / right wrist / head), per-camera rotation
# and the saved role configuration. Meant to be sourced after lib/common.sh.

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/camera_setup"
ROLE_CONFIG="$CONFIG_DIR/camera_roles.conf"
LEFT_WRIST_SERIAL=""
RIGHT_WRIST_SERIAL=""
HEAD_SERIAL=""
LEFT_WRIST_ROTATION=0
RIGHT_WRIST_ROTATION=0
HEAD_ROTATION=0

declare -a DEVICE_MODELS=()
declare -a DEVICE_SERIALS=()
declare -a DEVICE_CONNECTIONS=()
declare -a DEVICE_USB_PORTS=()


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
        printf '  [%d] 型号: %s | 序列号: %s%s%s | 连接: %s%s%s | 端口: %s%s%s\n' \
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
        read -r -p "确认只使用这 $count 台相机启动吗？[y/N]: " choice || return 1
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

valid_rotation_value() {
    [[ "$1" == 0 || "$1" == 90 || "$1" == 180 || "$1" == 270 ]]
}

read_rotation_config_value() {
    local value
    value="$(read_role_config_value "$1")"
    printf '%s\n' "${value:-0}"
}

dimensions_for_rotation() {
    case "$1" in
        90|270) printf '%s %s\n' "$HEIGHT" "$WIDTH" ;;
        *)      printf '%s %s\n' "$WIDTH" "$HEIGHT" ;;
    esac
}

load_role_config() {
    [[ -f "$ROLE_CONFIG" ]] || return 1

    LEFT_WRIST_SERIAL="$(read_role_config_value left_wrist)"
    RIGHT_WRIST_SERIAL="$(read_role_config_value right_wrist)"
    HEAD_SERIAL="$(read_role_config_value head)"
    LEFT_WRIST_ROTATION="$(read_rotation_config_value left_wrist_rotation)"
    RIGHT_WRIST_ROTATION="$(read_rotation_config_value right_wrist_rotation)"
    HEAD_ROTATION="$(read_rotation_config_value head_rotation)"

    valid_rotation_value "$LEFT_WRIST_ROTATION" || return 1
    valid_rotation_value "$RIGHT_WRIST_ROTATION" || return 1
    valid_rotation_value "$HEAD_ROTATION" || return 1
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
    local rotation="$4"
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
        printf '  %-6s 型号: %s | 序列号: %s%s%s | 连接: %s%s%s | 端口: %s%s%s | 旋转: %s°\n' \
            "$label:" "$model" "$color" "$serial" "$RESET" \
            "$color" "$connection" "$RESET" "$color" "$usb_port" "$RESET" "$rotation"
    else
        printf '  %-6s 序列号: %s%s%s | 旋转: %s°（当前未连接）\n' "$label:" "$color" "$serial" "$RESET" "$rotation"
    fi
}

print_saved_roles() {
    log "${CYAN}上次保存的相机角色配置：${RESET}"
    print_role "左腕" "$LEFT_WRIST_SERIAL" "$CYAN" "$LEFT_WRIST_ROTATION"
    print_role "右腕" "$RIGHT_WRIST_SERIAL" "$CYAN" "$RIGHT_WRIST_ROTATION"
    print_role "头部" "$HEAD_SERIAL" "$CYAN" "$HEAD_ROTATION"
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

report_role_mismatch() {
    local role="$1"
    local model="$2"

    if [[ "$role" == "head" ]]; then
        printf '%s 不能作为头部相机；头部需要 Gemini 330 系列。\n' "$model" >&2
    else
        printf '%s 不能作为腕部相机；腕部需要 Gemini 305。\n' "$model" >&2
    fi
}

role_label() {
    case "$1" in
        left_wrist) printf '左腕\n' ;;
        right_wrist) printf '右腕\n' ;;
        head) printf '头部\n' ;;
    esac
}

role_serial() {
    case "$1" in
        left_wrist) printf '%s\n' "$LEFT_WRIST_SERIAL" ;;
        right_wrist) printf '%s\n' "$RIGHT_WRIST_SERIAL" ;;
        head) printf '%s\n' "$HEAD_SERIAL" ;;
    esac
}

prompt_rotation() {
    local label="$1"
    local current="$2"
    local choice

    while true; do
        read -r -p "请选择${label}相机画面旋转角度 [0/90/180/270]（回车保持 ${current}）: " choice || return 1
        choice="${choice:-$current}"
        if valid_rotation_value "$choice"; then
            printf '%s\n' "$choice"
            return 0
        fi
        printf '无效角度，请输入 0、90、180 或 270。\n' >&2
    done
}

# Record the camera for a role and immediately ask for its rotation angle.
assign_role() {
    local role="$1"
    local serial="$2"
    local label
    label="$(role_label "$role")"

    case "$role" in
        left_wrist)
            LEFT_WRIST_SERIAL="$serial"
            LEFT_WRIST_ROTATION="$(prompt_rotation "$label" "$LEFT_WRIST_ROTATION")"
            ;;
        right_wrist)
            RIGHT_WRIST_SERIAL="$serial"
            RIGHT_WRIST_ROTATION="$(prompt_rotation "$label" "$RIGHT_WRIST_ROTATION")"
            ;;
        head)
            HEAD_SERIAL="$serial"
            HEAD_ROTATION="$(prompt_rotation "$label" "$HEAD_ROTATION")"
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
        read -r -p "请选择${label}相机编号: " choice || return 1
        if [[ ! "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#DEVICE_SERIALS[@]} )); then
            printf '无效编号，请输入 1-%d。\n' "${#DEVICE_SERIALS[@]}" >&2
            continue
        fi

        index=$((choice - 1))
        serial="${DEVICE_SERIALS[$index]}"
        model="${DEVICE_MODELS[$index]}"

        if ! model_matches_role "$role" "$model"; then
            report_role_mismatch "$role" "$model"
            continue
        fi

        if [[ "$serial" == "$LEFT_WRIST_SERIAL" || "$serial" == "$RIGHT_WRIST_SERIAL" || "$serial" == "$HEAD_SERIAL" ]]; then
            printf '该相机已经分配给其他位置，请重新选择。\n' >&2
            continue
        fi

        assign_role "$role" "$serial"
        return 0
    done
}

prompt_role_for_device() {
    local index="$1"
    local choice
    local role
    local serial="${DEVICE_SERIALS[$index]}"
    local model="${DEVICE_MODELS[$index]}"

    printf '\n为相机 [%d] 分配位置：型号: %s | 序列号: %s%s%s | 连接: %s%s%s | 端口: %s%s%s\n' \
        "$((index + 1))" "$model" "$YELLOW" "$serial" "$RESET" \
        "$YELLOW" "${DEVICE_CONNECTIONS[$index]}" "$RESET" \
        "$YELLOW" "${DEVICE_USB_PORTS[$index]}" "$RESET"

    while true; do
        printf '  1) 左腕\n'
        printf '  2) 右腕\n'
        printf '  3) 头部\n'
        read -r -p '请选择位置 [1-3]: ' choice || return 1

        case "$choice" in
            1) role="left_wrist" ;;
            2) role="right_wrist" ;;
            3) role="head" ;;
            *) printf '无效选项，请输入 1、2 或 3。\n' >&2; continue ;;
        esac

        if ! model_matches_role "$role" "$model"; then
            report_role_mismatch "$role" "$model"
            continue
        fi

        if [[ -n "$(role_serial "$role")" ]]; then
            printf '%s已经分配，请选择其他位置。\n' "$(role_label "$role")" >&2
            continue
        fi

        assign_role "$role" "$serial"
        return 0
    done
}

save_role_config() {
    local temp_config

    mkdir -p "$CONFIG_DIR"
    temp_config="$(mktemp "$CONFIG_DIR/.camera_roles.conf.XXXXXX")"
    {
        printf '# camera_setup camera role mapping\n'
        printf 'left_wrist=%s\n' "$LEFT_WRIST_SERIAL"
        printf 'right_wrist=%s\n' "$RIGHT_WRIST_SERIAL"
        printf 'head=%s\n' "$HEAD_SERIAL"
        printf 'left_wrist_rotation=%s\n' "$LEFT_WRIST_ROTATION"
        printf 'right_wrist_rotation=%s\n' "$RIGHT_WRIST_ROTATION"
        printf 'head_rotation=%s\n' "$HEAD_ROTATION"
    } > "$temp_config"
    chmod 600 "$temp_config"
    mv "$temp_config" "$ROLE_CONFIG"
    log "配置已保存到 $ROLE_CONFIG"
}

configure_roles() {
    if [[ ! -t 0 ]]; then
        log "ERROR: no saved camera configuration; run camera_setup in an interactive terminal"
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
            read -r -p '请输入选项 [1-2]: ' choice || return 1
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
    log "WARN: $label 序列号未找到，本次跳过: $serial"
}
