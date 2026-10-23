#!/usr/bin/env bash
# Offline tests for the camera scripts (no cameras or ROS needed).
# Usage: tests/run_tests.sh
set -uo pipefail

TESTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPTS_DIR="$(dirname -- "$TESTS_DIR")/scripts"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf -- "$WORK_DIR"' EXIT

export XDG_CONFIG_HOME="$WORK_DIR/config"
export XDG_RUNTIME_DIR="$WORK_DIR/run"
mkdir -p "$XDG_RUNTIME_DIR"

# camera.sh only runs when executed, so sourcing it just loads the functions.
# shellcheck source=../scripts/camera.sh
source "$SCRIPTS_DIR/camera.sh"
set +e +E +u

PASSED=0
FAILED=0

assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        PASSED=$((PASSED + 1))
    else
        FAILED=$((FAILED + 1))
        printf 'FAIL: %s\n  expected: %q\n  actual:   %q\n' "$name" "$expected" "$actual"
    fi
}

assert_ok() {
    local name="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        PASSED=$((PASSED + 1))
    else
        FAILED=$((FAILED + 1))
        printf 'FAIL: %s (expected success)\n' "$name"
    fi
}

assert_fails() {
    local name="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        FAILED=$((FAILED + 1))
        printf 'FAIL: %s (expected failure)\n' "$name"
    else
        PASSED=$((PASSED + 1))
    fi
}

reset_roles() {
    LEFT_WRIST_SERIAL=""; RIGHT_WRIST_SERIAL=""; HEAD_SERIAL=""
    LEFT_WRIST_ROTATION=0; RIGHT_WRIST_ROTATION=0; HEAD_ROTATION=0
}

write_role_config() {
    mkdir -p "$CONFIG_DIR"
    printf '%s\n' "$@" > "$ROLE_CONFIG"
}

test_dimensions_for_rotation() {
    assert_eq "0 keeps landscape" "640 480" "$(dimensions_for_rotation 0)"
    assert_eq "90 swaps" "480 640" "$(dimensions_for_rotation 90)"
    assert_eq "180 keeps landscape" "640 480" "$(dimensions_for_rotation 180)"
    assert_eq "270 swaps" "480 640" "$(dimensions_for_rotation 270)"
}

test_eye_for_rotation() {
    assert_eq "left wrist 0 uses left" "left" "$(eye_for_rotation left 0)"
    assert_eq "left wrist 90 uses right" "right" "$(eye_for_rotation left 90)"
    assert_eq "left wrist 180 uses left" "left" "$(eye_for_rotation left 180)"
    assert_eq "left wrist 270 uses right" "right" "$(eye_for_rotation left 270)"
    assert_eq "right wrist 0 uses right" "right" "$(eye_for_rotation right 0)"
    assert_eq "right wrist 90 uses left" "left" "$(eye_for_rotation right 90)"
    assert_eq "right wrist 180 uses right" "right" "$(eye_for_rotation right 180)"
    assert_eq "right wrist 270 uses left" "left" "$(eye_for_rotation right 270)"
}

test_wrist_topic_follows_eye() {
    assert_eq "left wrist 90 topic uses right eye" \
        "/camera_left_wrist/right_color/image_raw/compressed" \
        "$(wrist_topic camera_left_wrist "$(eye_for_rotation left 90)")"
    assert_eq "right wrist 0 topic uses right eye" \
        "/camera_right_wrist/right_color/image_raw/compressed" \
        "$(wrist_topic camera_right_wrist "$(eye_for_rotation right 0)")"
}

test_valid_rotation_value() {
    local value
    for value in 0 90 180 270; do
        assert_ok "rotation $value valid" valid_rotation_value "$value"
    done
    for value in 45 -1 "" 360 abc "90 "; do
        assert_fails "rotation '$value' invalid" valid_rotation_value "$value"
    done
}

test_load_role_config() {
    reset_roles
    rm -f "$ROLE_CONFIG"
    assert_fails "missing config" load_role_config

    write_role_config "left_wrist=A1" "right_wrist=B2" "head=C3"
    assert_ok "legacy config without rotation keys" load_role_config
    assert_eq "legacy rotation defaults to 0" "0 0 0" "$LEFT_WRIST_ROTATION $RIGHT_WRIST_ROTATION $HEAD_ROTATION"

    write_role_config "left_wrist=A1" "head=C3" "left_wrist_rotation=90" "head_rotation=270"
    assert_ok "config with rotation" load_role_config
    assert_eq "saved rotations are loaded" "90 0 270" "$LEFT_WRIST_ROTATION $RIGHT_WRIST_ROTATION $HEAD_ROTATION"

    write_role_config "head=C3" "head_rotation=45"
    assert_fails "invalid rotation rejected" load_role_config

    write_role_config "left_wrist=A1" "head=A1"
    assert_fails "duplicate serial rejected" load_role_config

    write_role_config "left_wrist=A;rm" "head=C3"
    assert_fails "unsafe serial rejected" load_role_config

    write_role_config "left_wrist=" "right_wrist=" "head="
    assert_fails "config without any camera rejected" load_role_config
}

test_save_role_config_roundtrip() {
    reset_roles
    LEFT_WRIST_SERIAL="L1"; HEAD_SERIAL="H1"
    LEFT_WRIST_ROTATION=180; HEAD_ROTATION=90
    save_role_config >/dev/null
    reset_roles
    load_role_config
    assert_eq "serials roundtrip" "L1||H1" "$LEFT_WRIST_SERIAL|$RIGHT_WRIST_SERIAL|$HEAD_SERIAL"
    assert_eq "rotations roundtrip" "180 0 90" "$LEFT_WRIST_ROTATION $RIGHT_WRIST_ROTATION $HEAD_ROTATION"
    assert_eq "config is private" "600" "$(stat -c %a "$ROLE_CONFIG")"
}

test_prompt_rotation() {
    assert_eq "enter keeps current" "90" "$(printf '\n' | prompt_rotation 头部 90 2>/dev/null)"
    assert_eq "explicit angle" "270" "$(printf '270\n' | prompt_rotation 头部 0 2>/dev/null)"
    assert_eq "invalid then valid" "180" "$(printf '45\n180\n' | prompt_rotation 头部 0 2>/dev/null)"
    assert_fails "EOF stops instead of looping" prompt_rotation 头部 0 < /dev/null
}

test_prompt_for_role() {
    reset_roles
    DEVICE_SERIALS=(S1 S2)
    DEVICE_MODELS=("Gemini 305" "Gemini 335Lg")

    prompt_for_role left_wrist 左腕 <<< $'2\n1\n90' >/dev/null 2>&1
    assert_eq "wrong model skipped, wrist assigned with rotation" "S1:90" "$LEFT_WRIST_SERIAL:$LEFT_WRIST_ROTATION"

    prompt_for_role head 头部 <<< $'1\n2\n' >/dev/null 2>&1
    assert_eq "assigned camera skipped, head assigned" "S2:0" "$HEAD_SERIAL:$HEAD_ROTATION"
    assert_fails "EOF stops instead of looping" prompt_for_role right_wrist 右腕 < /dev/null
}

test_prompt_role_for_device() {
    reset_roles
    DEVICE_SERIALS=(S1 S2)
    DEVICE_MODELS=("Gemini 305" "Gemini 305")
    DEVICE_CONNECTIONS=(USB3 USB3)
    DEVICE_USB_PORTS=(2-1 2-2)

    prompt_role_for_device 0 <<< $'1\n90' >/dev/null 2>&1
    assert_eq "first wrist is left" "S1:90" "$LEFT_WRIST_SERIAL:$LEFT_WRIST_ROTATION"
    prompt_role_for_device 1 <<< $'1\n2\n180' >/dev/null 2>&1
    assert_eq "taken role skipped, second wrist is right" "S2:180" "$RIGHT_WRIST_SERIAL:$RIGHT_WRIST_ROTATION"
}

test_parse_detected_devices() {
    init_runtime_dir
    cat > "$LOG_DIR/list_devices.txt" <<'EOF'
[INFO] name: Gemini 305
[INFO] serial: CP1234
[INFO] connection: USB3.2
[INFO] usb port: 2-1.4
[INFO] name: Gemini 335Lg
[INFO] serial: CP5678
[INFO] usb port: 2-3
[INFO] name: Gemini 335Lg
[INFO] serial: GM0001
[INFO] connection: GMSL2
[INFO] usb port: gmsl2-1
EOF
    parse_detected_devices
    assert_eq "device count" "3" "${#DEVICE_SERIALS[@]}"
    assert_eq "first device" "Gemini 305|CP1234|USB3.2|2-1.4" "${DEVICE_MODELS[0]}|${DEVICE_SERIALS[0]}|${DEVICE_CONNECTIONS[0]}|${DEVICE_USB_PORTS[0]}"
    assert_eq "missing connection becomes unknown" "unknown" "${DEVICE_CONNECTIONS[1]}"
    assert_eq "lookup by serial" "2-3" "$(usb_port_for_serial CP5678)"
    assert_eq "GMSL device parsed" "GMSL2|gmsl2-1" "${DEVICE_CONNECTIONS[2]}|${DEVICE_USB_PORTS[2]}"
}

test_set_yaml_key() {
    local file="$WORK_DIR/sample.yaml"
    printf 'device_preset: a\ncolor_width: 0\n' > "$file"

    set_yaml_key "$file" color_width 480
    assert_eq "existing key replaced" "480" "$(sed -n 's/^color_width: //p' "$file")"
    set_yaml_key "$file" ae_strategy motion device_preset
    assert_eq "missing key inserted after anchor" "ae_strategy: motion" "$(sed -n '2p' "$file")"
    set_yaml_key "$file" unknown_key 1
    assert_eq "missing key without anchor skipped" "0" "$(grep -c '^unknown_key' "$file")"
}

make_fake_driver() {
    ORBBEC_WS="$WORK_DIR/ws"
    mkdir -p "$ORBBEC_WS/orbbec_camera/config"
    cat > "$ORBBEC_WS/orbbec_camera/config/gemini305_dual_color.yaml" <<'EOF'
camera_name: camera
serial_number: ""
usb_port: ""
device_preset: Default
enable_color: true
enable_left_color: false
left_color_width: 0
left_color_height: 0
left_color_rotation: -1
left_color_fps: 0
left_color_format: ANY
enable_right_color: false
right_color_width: 0
right_color_height: 0
right_color_rotation: -1
right_color_fps: 0
right_color_format: ANY
color_powerline_freq: ""
left_color.image_raw.enable_pub_plugins: []
right_color.image_raw.enable_pub_plugins: []
EOF
}

yaml_value() {
    sed -n "s/^$2: //p" "$1"
}

test_make_gemini305_config() {
    local out="$WORK_DIR/wrist.yaml"
    make_fake_driver
    FPS=30

    make_gemini305_config "$out" CP1234 2-1.4 left 90 >/dev/null
    assert_eq "left eye enabled" "true" "$(yaml_value "$out" enable_left_color)"
    assert_eq "right eye disabled" "false" "$(yaml_value "$out" enable_right_color)"
    assert_eq "90 swaps width/height" "480 640" "$(yaml_value "$out" left_color_width) $(yaml_value "$out" left_color_height)"
    assert_eq "rotation applied" "90" "$(yaml_value "$out" left_color_rotation)"
    assert_eq "serial quoted" '"CP1234"' "$(yaml_value "$out" serial_number)"
    assert_eq "ae strategy inserted" "1" "$(grep -c '^ae_strategy: motion' "$out")"
    assert_eq "anti flicker inserted" "1" "$(grep -c '^color_anti_flicker: true' "$out")"
    assert_eq "runtime config is private" "600" "$(stat -c %a "$out")"

    make_gemini305_config "$out" CP1234 2-1.4 right 0 >/dev/null
    assert_eq "right eye 0 keeps landscape" "640 480" "$(yaml_value "$out" right_color_width) $(yaml_value "$out" right_color_height)"
    assert_eq "right format YUYV" "YUYV" "$(yaml_value "$out" right_color_format)"

    ( make_gemini305_config "$out" 'CP;x' 2-1 left 0 ) >/dev/null 2>&1
    assert_eq "unsafe serial rejected" "1" "$?"
    ( make_gemini305_config "$out" CP1 2-1 left 45 ) >/dev/null 2>&1
    assert_eq "invalid rotation rejected" "1" "$?"
}

test_init_runtime_dir() {
    init_runtime_dir
    assert_eq "runtime dir is private" "700" "$(stat -c %a "$RUNTIME_DIR")"
    assert_eq "pid file lives inside" "$RUNTIME_DIR/camera_pids.txt" "$PID_FILE"

    local saved_runtime="$XDG_RUNTIME_DIR"
    export XDG_RUNTIME_DIR="$WORK_DIR/run2"
    mkdir -p "$XDG_RUNTIME_DIR" "$WORK_DIR/elsewhere"
    ln -s "$WORK_DIR/elsewhere" "$XDG_RUNTIME_DIR/camera_setup-$(id -u)"
    assert_fails "symlinked runtime dir rejected" init_runtime_dir
    export XDG_RUNTIME_DIR="$saved_runtime"
    init_runtime_dir
}

test_stop_recorded_processes() {
    init_runtime_dir
    setsid sleep 60 &
    local pid=$!
    : > "$PID_FILE"
    record_pid camera_test "$pid"
    record_pid zenoh_router 1
    printf 'garbage line\ncamera_x:notanumber\ncamera_y:1\n' >> "$PID_FILE"

    stop_recorded_processes
    wait "$pid" 2>/dev/null
    assert_fails "recorded process stopped" kill -0 "$pid"
    assert_eq "pid file emptied" "0" "$(wc -c < "$PID_FILE")"
}

main() {
    local test_fn
    for test_fn in $(declare -F | awk '$3 ~ /^test_/ {print $3}'); do
        "$test_fn"
    done
    printf '%d passed, %d failed\n' "$PASSED" "$FAILED"
    (( FAILED == 0 ))
}

main
