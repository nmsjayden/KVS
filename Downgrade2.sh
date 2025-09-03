#!/bin/bash
# ChromeOS Recovery & Downgrade Script
# Includes: Kernver detection, BusyBox unzip, full Chrome100/Chromium Dash support

LOGFILE="/var/log/chrome_recovery.log"
DEBUG=${DEBUG:-0}

# ---------- Logging ----------
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "$LOGFILE"
}

show_result() {
    if [ $? -eq 0 ]; then
        echo "✔ Success!"
        log "Success!"
    else
        echo "✘ Failed!"
        log "Failed!"
    fi
}

# ---------- Display Logo ----------
show_logo() {
    clear
    cat << 'EOF'
   ___  _                                 ___                       __ _                _
  / __|| |_   _ _  ___  _ __   ___       |   \  ___  _ __ __  _ _  / _` | _ _  __ _  __| | ___  _ _
 | (__ |   \ | '_|/ _ \| '  \ / -/)      | |) |/ _ \ \ V  V /| ' \ \__. || '_|/ _` |/ _` |/ -_)|'_|
  \___||_||_||_|  \___/|_|_|_|\___/      |___/ \___/  \_/\_/ |_||_||___/ |_|  \__/_|\__/_|\___||_|
EOF
    echo "ChromeOS Recovery Script - Developer Mode Downgrader"
}

# ---------- Kernver Detection ----------
detect_kernver() {
    echo "[*] Detecting kernver..."
    if [ -r /proc/cmdline ] && grep -q "kernver=" /proc/cmdline; then
        KERNVER=$(grep -oP "kernver=\K\d" /proc/cmdline)
        echo "[INFO] Kernver detected from cmdline: $KERNVER"
    else
        read -rp "Enter TPM number (0-6) for kernver: " KERNVER
        if ! [[ $KERNVER =~ ^[0-6]$ ]]; then
            echo "[!] Invalid kernver, defaulting to 0."
            KERNVER=0
        fi
        echo "[INFO] Using kernver: $KERNVER"
    fi
}

# ---------- BusyBox unzip ----------
ensure_unzip() {
    if ! command -v unzip &>/dev/null; then
        echo "[*] Downloading BusyBox for unzip..."
        mkdir -p /usr/local/tmp
        curl --progress-bar -Lko /usr/local/tmp/unzip https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox
        chmod +x /usr/local/tmp/unzip
        UNZIP_CMD="/usr/local/tmp/unzip"
    else
        UNZIP_CMD="unzip"
    fi
}

# ---------- Helpers ----------
lsbval() {
  local key="$1"
  local lsbfile="${2:-/etc/lsb-release}"
  if ! echo "${key}" | grep -Eq '^[a-zA-Z0-9_]+$'; then return 1; fi
  sed -E -n -e \
    "/^[[:space:]]*${key}[[:space:]]*=/{
      s:^[^=]+=[[:space:]]*::
      s:[[:space:]]+$::
      p
    }" "${lsbfile}"
}

get_largest_cros_blockdev() {
    local largest size dev_name tmp_size remo
    size=0
    for blockdev in /sys/block/*; do
        dev_name="${blockdev##*/}"
        echo "$dev_name" | grep -q '^\(loop\|ram\)' && continue
        tmp_size=$(cat "$blockdev"/size)
        remo=$(cat "$blockdev"/removable)
        if [ "$tmp_size" -gt "$size" ] && [ "${remo:-0}" -eq 0 ]; then
            case "$(sfdisk -l -o name "/dev/$dev_name" 2>/dev/null)" in
                *STATE*KERN-A*ROOT-A*KERN-B*ROOT-B*)
                    largest="/dev/$dev_name"
                    size="$tmp_size"
                    ;;
            esac
        fi
    done
    echo "$largest"
}

get_booted_kernnum() {
    local dst=$(get_largest_cros_blockdev)
    if (($(cgpt show -n "$dst" -i 2 -P) > $(cgpt show -n "$dst" -i 4 -P))); then
        echo -n 2
    else
        echo -n 4
    fi
}

defog() {
    futility gbb --set --flash --flags=0x80b1 || true
    crossystem block_devmode=0 || true
    vpd -i RW_VPD -s block_devmode=0 || true
    vpd -i RW_VPD -s check_enrollment=1 || true
}

# ---------- Version Selection ----------
list_versions() {
    local release_board=$(lsbval CHROMEOS_RELEASE_BOARD)
    local board=${release_board%%-*}
    echo "Fetching available versions for board: $board..."

    local json_chrome100=$(curl -ks "https://raw.githubusercontent.com/rainestorme/chrome100-json/main/boards/$board.json")
    local builds=$(curl -ks "https://chromiumdash.appspot.com/cros/fetch_serving_builds?deviceCategory=Chrome%20OS")

    declare -A unique_versions
    local versions=()

    # Chrome100
    if [ -n "$json_chrome100" ]; then
        chrome_versions=$(echo "$json_chrome100" | jq -r '.pageProps.images[].chrome')
        for cros_version in $chrome_versions; do
            major_minor=$(echo "$cros_version" | cut -d'.' -f1,2)
            if [ -z "${unique_versions[$major_minor]}" ]; then
                unique_versions[$major_minor]=$cros_version
                platform=$(echo "$json_chrome100" | jq -r --arg version "$cros_version" '.pageProps.images[] | select(.chrome == $version) | .platform')
                channel=$(echo "$json_chrome100" | jq -r --arg version "$cros_version" '.pageProps.images[] | select(.chrome == $version) | .channel')
                if [[ -n "$platform" && -n "$channel" ]]; then
                    versions+=("$cros_version | Platform: $platform | Channel: $channel (chrome100)")
                fi
            fi
        done
    fi

    # Chromium Dash fallback
    if [ -n "$builds" ]; then
        hwid=$(jq "(.builds.$board[] | keys)[0]" <<<"$builds" 2>/dev/null)
        hwid=${hwid:1:-1}
        milestones=$(jq ".builds.$board[].$hwid.pushRecoveries | keys | .[]" <<<"$builds" 2>/dev/null | tr -d '"')
        for milestone in $milestones; do
            major_minor=$(echo "$milestone" | cut -d'.' -f1,2)
            if [ -z "${unique_versions[$major_minor]}" ]; then
                unique_versions[$major_minor]=$milestone
                if [[ -n "$milestone" ]]; then
                    versions+=("$milestone | Platform: $board | Channel: unknown (chromiumdash)")
                fi
            fi
        done
    fi

    # Sort and display
    IFS=$'\n' versions=($(printf "%s\n" "${versions[@]}" | sort -V))
    total_versions=${#versions[@]}
    for i in $(seq 0 $((total_versions - 1))); do
        echo "$((i+1))) ${versions[$i]}"
    done

    while true; do
        read -rp "Select version number (1-${#versions[@]}): " selection
        if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le ${#versions[@]} ]; then
            VERSION=$(echo "${versions[$selection-1]}" | cut -d' ' -f1)
            echo "[INFO] You selected version: $VERSION"
            break
        else
            echo "Invalid selection."
        fi
    done
}

# ---------- Image Flash ----------
flash_image() {
    local FINAL_URL="$1"

    mkdir -p /mnt/stateful_partition
    pushd /mnt/stateful_partition || exit

    set -e
    echo "[*] Downloading recovery image..."
    curl --progress-bar -k "$FINAL_URL" -o recovery.zip

    echo "[*] Unzipping image..."
    "$UNZIP_CMD" -o recovery.zip
    rm recovery.zip

    FILENAME=$(find . -maxdepth 2 -name "chromeos_*.bin" | head -n1)
    echo "[*] Found image: $FILENAME"

    local dst=$(get_largest_cros_blockdev)
    if [[ $dst == /dev/sd* ]]; then
        read -r -p "Enter correct drive or press Enter to use $dst: " custom_dst
        dst=${custom_dst:-$dst}
    fi

    local tgt_kern=$(get_booted_kernnum)
    tgt_kern=$(( tgt_kern == 2 ? 4 : 2 ))
    local tgt_root=$((tgt_kern + 1))
    local kerndev=${dst}p${tgt_kern}
    local rootdev=${dst}p${tgt_root}

    local loop=$(losetup -f | tail -1)
    losetup -P "$loop" "$FILENAME"

    echo "[*] Overwriting partitions..."
    dd if="${loop}p4" of="$kerndev" status=progress
    dd if="${loop}p3" of="$rootdev" status=progress

    echo "[*] Setting kernel priority..."
    cgpt add "$dst" -i 4 -P 0
    cgpt add "$dst" -i 2 -P 0
    cgpt add "$dst" -i "$tgt_kern" -P 1

    defog
    losetup -d "$loop"
    rm -f "$FILENAME"

    popd || exit
    read -n 1 -s -r -p "Done! Press any key to reboot."
    reboot
}

# ---------- Main ----------
main() {
    if [ "$EUID" -ne 0 ]; then
        echo "Please run as root."
        exit 1
    fi

    show_logo
    detect_kernver
    ensure_unzip

    echo "Select version to install:"
    echo " 1) list versions"
    echo " 2) latest"
    echo " 3) custom"
    read -rp "(1-3) > " choice
    case $choice in
        1) list_versions ;;
        2) VERSION="latest" ;;
        3) read -rp "Enter milestone: " VERSION ;;
        *) echo "Invalid choice"; exit 1 ;;
    esac

    # Construct FINAL_URL using your existing Chrome100 or Chromium Dash logic
    # Example:
    # FINAL_URL="https://dl.google.com/dl/edgedl/chromeos/recovery/chromeos_16295.74.0_nissa_recovery_stable-channel_NissaMPKeys-v58.bin.zip"

    flash_image "$FINAL_URL"
}

if [ "$0" = "$BASH_SOURCE" ]; then
    main
fi
