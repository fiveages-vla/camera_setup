#!/usr/bin/env bash
set -euo pipefail

if [[ -t 1 && "${TERM:-dumb}" != "dumb" && -z "${NO_COLOR:-}" ]]; then
    color_driver=$'\033[1;33m'
    color_success=$'\033[1;32m'
    color_error=$'\033[1;31m'
    color_reset=$'\033[0m'
else
    color_driver=""
    color_success=""
    color_error=""
    color_reset=""
fi

usage() {
    cat <<'EOF'
Usage: canup

The script interactively asks for:
  1. CAN FD (1M/5M) or Classic CAN (500K)
  2. All detected CAN ports or selected ports

The bound driver is detected and displayed for every CAN interface.
EOF
}

die() {
    printf '%sERROR:%s %s\n' "$color_error" "$color_reset" "$*" >&2
    exit 1
}

detect_can_interfaces() {
    local net_path iface

    for net_path in /sys/class/net/can[0-9]*; do
        [[ -e "$net_path" ]] || continue
        iface="${net_path##*/}"
        [[ "$iface" =~ ^can[0-9]+$ ]] || continue
        [[ -r "$net_path/type" ]] || continue
        [[ "$(<"$net_path/type")" == "280" ]] || continue
        printf '%s\n' "$iface"
    done
}

get_interface_driver() {
    local iface="$1"
    local driver_path driver

    driver_path="$(readlink -f "/sys/class/net/$iface/device/driver" 2>/dev/null || true)"
    if [[ -n "$driver_path" && -e "$driver_path" ]]; then
        printf '%s\n' "${driver_path##*/}"
        return
    fi

    if command -v ethtool >/dev/null 2>&1; then
        driver="$(ethtool -i "$iface" 2>/dev/null | sed -n 's/^driver: //p' | head -n 1 || true)"
        if [[ -n "$driver" ]]; then
            printf '%s\n' "$driver"
            return
        fi
    fi

    printf '%s\n' "unknown"
}

ensure_can_interfaces() {
    local module
    local -a detected=()
    local -a candidate_modules=(
        kcan
        peak_usb
        gs_usb
        kvaser_usb
        usb_8dev
        ems_usb
        esd_usb
        esd_usb2
        mcba_usb
        etas_es58x
        ucan
    )

    mapfile -t detected < <(detect_can_interfaces)
    if ((${#detected[@]} > 0)); then
        return
    fi

    command -v modinfo >/dev/null 2>&1 || die "no CAN interfaces detected and modinfo is unavailable."
    echo "No CAN interfaces detected. Trying installed SocketCAN USB drivers..."

    for module in "${candidate_modules[@]}"; do
        modinfo "$module" >/dev/null 2>&1 || continue
        echo "  Trying driver: $module"
        sudo modprobe "$module" 2>/dev/null || continue
        if command -v udevadm >/dev/null 2>&1; then
            udevadm settle --timeout=2 2>/dev/null || true
        fi
        mapfile -t detected < <(detect_can_interfaces)
        if ((${#detected[@]} > 0)); then
            printf '  CAN interface detected with driver: %s%s%s\n' \
                "$color_driver" "$(get_interface_driver "${detected[0]}")" "$color_reset"
            return
        fi
    done

    die "no canN interfaces found. Connect the adapter or install its Linux SocketCAN driver."
}

select_mode() {
    local choice

    echo "CAN mode:"
    echo "  1) CAN FD      bitrate 1M, data bitrate 5M"
    echo "  2) Classic CAN bitrate 500K"
    read -r -p "Select mode [1]: " choice || die "interactive input is required."

    case "$choice" in
        ""|1)
            mode="fd"
            bitrate="1000000"
            dbitrate="5000000"
            ;;
        2)
            mode="classic"
            bitrate="500000"
            dbitrate="0"
            ;;
        *)
            die "invalid mode selection: $choice"
            ;;
    esac
}

select_interfaces() {
    local selection choice iface index driver
    local -a choices=()
    local -A seen=()

    mapfile -t detected_interfaces < <(detect_can_interfaces)
    ((${#detected_interfaces[@]} > 0)) || die "no canN interfaces detected."

    echo
    echo "Detected CAN interfaces:"
    for index in "${!detected_interfaces[@]}"; do
        iface="${detected_interfaces[$index]}"
        driver="$(get_interface_driver "$iface")"
        printf '  %d) driver=%s%-12s%s ' \
            "$((index + 1))" "$color_driver" "$driver" "$color_reset"
        ip -brief link show "$iface"
    done

    echo "  all) All detected CAN interfaces"
    read -r -p "Select ports (all, 1 3, or can0 can2) [1]: " selection || die "interactive input is required."
    if [[ -z "${selection//[[:space:]]/}" ]]; then
        selection="1"
    fi

    read -r -a choices <<< "$selection"
    ((${#choices[@]} > 0)) || die "no CAN ports selected."
    if [[ "${choices[0]}" == "all" ]]; then
        ((${#choices[@]} == 1)) || die "'all' cannot be combined with other ports."
        interfaces=("${detected_interfaces[@]}")
        return
    fi

    interfaces=()
    for choice in "${choices[@]}"; do
        iface=""
        if [[ "$choice" =~ ^[0-9]+$ ]]; then
            index=$((10#$choice - 1))
            ((index >= 0 && index < ${#detected_interfaces[@]})) || die "port number out of range: $choice"
            iface="${detected_interfaces[$index]}"
        else
            for iface in "${detected_interfaces[@]}"; do
                [[ "$choice" == "$iface" ]] && break
            done
            [[ "$choice" == "$iface" ]] || die "CAN interface not detected: $choice"
        fi

        if [[ -z "${seen[$iface]+present}" ]]; then
            interfaces+=("$iface")
            seen["$iface"]=1
        fi
    done
}

configure_interface() {
    local iface="$1"
    local driver

    driver="$(get_interface_driver "$iface")"
    printf 'Starting %s with driver=%s%s%s...\n' \
        "$iface" "$color_driver" "$driver" "$color_reset"
    sudo ip link set "$iface" down 2>/dev/null || true
    if [[ "$mode" == "classic" ]]; then
        sudo ip link set "$iface" type can bitrate "$bitrate" restart-ms "$restart_ms"
    else
        sudo ip link set "$iface" type can bitrate "$bitrate" dbitrate "$dbitrate" fd on restart-ms "$restart_ms"
    fi
    sudo ip link set "$iface" up

    printf '%s%s is ready%s (driver=%s%s%s):\n' \
        "$color_success" "$iface" "$color_reset" \
        "$color_driver" "$(get_interface_driver "$iface")" "$color_reset"
    ip -details link show "$iface"
    echo
}

case "${1:-}" in
    "")
        ;;
    -h|--help)
        usage
        exit 0
        ;;
    *)
        usage >&2
        die "run canup without arguments and select ports interactively."
        ;;
esac

command -v ip >/dev/null 2>&1 || die "ip command not found. Install iproute2 first."

restart_ms="100"
mode=""
bitrate=""
dbitrate=""
detected_interfaces=()
interfaces=()

ensure_can_interfaces

select_mode
select_interfaces

echo
echo "Mode: $mode"
echo "Selected CAN interfaces: ${interfaces[*]}"
read -r -p "Start these interfaces? [Y/n]: " confirmation || die "interactive input is required."
case "$confirmation" in
    ""|y|Y|yes|YES)
        ;;
    *)
        echo "Cancelled."
        exit 0
        ;;
esac

for iface in "${interfaces[@]}"; do
    configure_interface "$iface"
done

printf '%sAll selected CAN interfaces are ready:%s\n' "$color_success" "$color_reset"
for iface in "${interfaces[@]}"; do
    printf '  %s: driver=%s%s%s\n' \
        "$iface" "$color_driver" "$(get_interface_driver "$iface")" "$color_reset"
done
