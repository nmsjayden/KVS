#!/bin/bash
set -e

LOGFILE="/var/log/chromeos_downgrade.log"

declare -A KERNVER_MIN_VERSION=(
    [0]="any"
    [1]="any"
    [2]="111"
    [3]="120"
    [4]="125"
    [5]="132.0.6834.201"
    [6]="138.0.7204.221"
)

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "$LOGFILE"
}

lsbval() {
    local key="$1"
    local lsbfile="${2:-/etc/lsb-release}"
    sed -En "s/^${key}=(.*)/\1/p" "$lsbfile"
}

get_kernver() {
    local tpm_file="/sys/class/tpm/tpm0/device/tpm_version_major"
    if [ -r "$tpm_file" ]; then
        local kv=$(cat "$tpm_file")
        log "Detected kernver from TPM: $kv"
        echo "$kv"
    else
        read -p "Unable to auto-detect kernver. Enter TPM kernver (0-6): " kv
        echo "$kv"
    fi
}

check_version_allowed() {
    local kernver="$1"
    local selected="$2"
    local min_version="${KERNVER_MIN_VERSION[$kernver]}"
    if [ "$min_version" != "any" ]; then
        if [[ "$selected" < "$min_version" ]]; then
            log "ERROR: Selected version $selected is below minimum allowed for kernver $kernver ($min_version)"
            echo "Selected version is below minimum allowed for your device!"
            exit 1
        fi
    fi
}

get_board() {
    local release_board
    release_board=$(lsbval CHROMEOS_RELEASE_BOARD)
    echo "${release_board%%-*}"
}

fetch_versions() {
    local board="$1"
    declare -a versions
    declare -A unique_versions

    local json_chrome100=$(curl -ks "https://raw.githubusercontent.com/rainestorme/chrome100-json/main/boards/$board.json")
    local builds=$(curl -ks "https://chromiumdash.appspot.com/cros/fetch_serving_builds?deviceCategory=Chrome%20OS")

    # Chrome100
    if [ -n "$json_chrome100" ]; then
        for cros_version in $(echo "$json_chrome100" | jq -r '.pageProps.images[].chrome'); do
            local major_minor=$(echo "$cros_version" | cut -d'.' -f1,2)
            if [ -z "${unique_versions[$major_minor]}" ]; then
                unique_versions[$major_minor]=$cros_version
                platform=$(echo "$json_chrome100" | jq -r --arg version "$cros_version" '.pageProps.images[] | select(.chrome==$version) | .platform')
                channel=$(echo "$json_chrome100" | jq -r --arg version "$cros_version" '.pageProps.images[] | select(.chrome==$version) | .channel')
                versions+=("$cros_version | $platform | $channel")
            fi
        done
    fi

    # Chromium Dash fallback
    if [ -n "$builds" ]; then
        hwid=$(jq "(.builds.$board[] | keys)[0]" <<<"$builds" 2>/dev/null)
        hwid=${hwid:1:-1}
        milestones=$(jq ".builds.$board[].$hwid.pushRecoveries | keys | .[]" <<<"$builds" 2>/dev/null | tr -d '"')
        for milestone in $milestones; do
            local major_minor=$(echo "$milestone" | cut -d'.' -f1,2)
            if [ -z "${unique_versions[$major_minor]}" ]; then
                unique_versions[$major_minor]=$milestone
                versions+=("$milestone | $board | unknown")
            fi
        done
    fi

    IFS=$'\n' versions=($(printf "%s\n" "${versions[@]}" | sort -V))
    echo "${versions[@]}"
}

download_recovery() {
    local url="$1"
    mkdir -p /usr/local/tmp
    curl -Lko /usr/local/tmp/busybox https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox
    chmod +x /usr/local/tmp/busybox

    log "Downloading recovery image..."
    curl -k -L "$url" -o recovery.zip

    log "Extracting image..."
    /usr/local/tmp/busybox unzip -o recovery.zip
    rm recovery.zip
    local image_file
    image_file=$(find . -maxdepth 2 -name "chromeos_*.bin" | head -n1)
    echo "$image_file"
}

get_largest_cros_blockdev() {
    local largest size=0
    for blockdev in /sys/block/*; do
        local dev_name=${blockdev##*/}
        [[ "$dev_name" =~ ^(loop|ram) ]] && continue
        local tmp_size=$(cat "$blockdev/size")
        local remo=$(cat "$blockdev/removable")
        if [ "$tmp_size" -gt "$size" ] && [ "${remo:-0}" -eq 0 ]; then
            if sfdisk -l -o name "/dev/$dev_name" 2>/dev/null | grep -q "STATE.*KERN-A.*ROOT-A.*KERN-B.*ROOT-B"; then
                largest="/dev/$dev_name"
                size="$tmp_size"
            fi
        fi
    done
    echo "$largest"
}

get_booted_kernnum() {
    local dst="$1"
    local p2p=$(cgpt show -n "$dst" -i 2 -P)
    local p4p=$(cgpt show -n "$dst" -i 4 -P)
    if (( p2p > p4p )); then
        echo 2
    else
        echo 4
    fi
}

defog() {
    futility gbb --set --flash --flags=0x8091 || true
    crossystem block_devmode=0 || true
    vpd -i RW_VPD -s block_devmode=0 || true
    vpd -i RW_VPD -s check_enrollment=1 || true
}

# -------------------------
# Main menu
# -------------------------
main() {
    log "Starting ChromeOS VT2 Downgrader"
    local kernver=$(get_kernver)
    log "Detected kernver: $kernver"

    local board=$(get_board)
    log "Detected board: $board"

    local versions
    IFS=' ' read -r -a versions <<< "$(fetch_versions "$board")"

    echo "ChromeOS Downgrader - Kernver $kernver"
    echo "Available options:"
    echo "1) List all compatible versions"
    echo "2) Latest version"
    echo "3) Enter custom version"
    read -p "Choose an option (1-3): " menu_choice

    case "$menu_choice" in
        1)
            echo "Compatible versions:"
            for i in "${!versions[@]}"; do
                local ver=$(echo "${versions[$i]}" | cut -d' ' -f1)
                if [[ "${KERNVER_MIN_VERSION[$kernver]}" != "any" ]] && [[ "$ver" < "${KERNVER_MIN_VERSION[$kernver]}" ]]; then
                    continue
                fi
                echo "$((i+1))) ${versions[$i]}"
            done
            read -p "Enter version number to install: " selection
            selected_version=$(echo "${versions[$((selection-1))]}" | cut -d' ' -f1)
            ;;
        2)
            selected_version=$(echo "${versions[-1]}" | cut -d' ' -f1)
            ;;
        3)
            read -p "Enter custom version (e.g., 138.0.7204.221): " selected_version
            ;;
        *)
            echo "Invalid choice!"
            exit 1
            ;;
    esac

    check_version_allowed "$kernver" "$selected_version"
    echo "Selected version: $selected_version"

    # Generate recovery URL
    local json_chrome100
    json_chrome100=$(curl -ks "https://raw.githubusercontent.com/rainestorme/chrome100-json/main/boards/$board.json")
    local FINAL_URL
    for cros_version in $(echo "$json_chrome100" | jq -r '.pageProps.images[].chrome'); do
        if [[ $cros_version == $selected_version* ]]; then
            platform=$(echo "$json_chrome100" | jq -r --arg version "$cros_version" '.pageProps.images[] | select(.chrome==$version) | .platform')
            channel=$(echo "$json_chrome100" | jq -r --arg version "$cros_version" '.pageProps.images[] | select(.chrome==$version) | .channel')
            mp_token=$(echo "$json_chrome100" | jq -r --arg version "$cros_version" '.pageProps.images[] | select(.chrome==$version) | .mp_token')
            mp_key=$(echo "$json_chrome100" | jq -r --arg version "$cros_version" '.pageProps.images[] | select(.chrome==$version) | .mp_key')
            FINAL_URL="https://dl.google.com/dl/edgedl/chromeos/recovery/chromeos_${platform}_${board}_recovery_${channel}_${mp_token}-v${mp_key}.bin.zip"
            break
        fi
    done

    [ -z "$FINAL_URL" ] && { echo "Failed to generate download URL"; exit 1; }

    # Download and extract recovery
    local IMAGE_FILE
    IMAGE_FILE=$(download_recovery "$FINAL_URL")

    # Select target drive
    local DST
    DST=$(get_largest_cros_blockdev)
    echo "Detected target drive: $DST"
    read -p "Enter drive to flash or press Enter to use detected ($DST): " input_dst
    DST=${input_dst:-$DST}

    local tgt_kern
    tgt_kern=$(get_booted_kernnum "$DST")
    tgt_kern=$(( tgt_kern == 2 ? 4 : 2 ))
    local tgt_root=$(( tgt_kern + 1 ))
    local kerndev="${DST}p${tgt_kern}"
    local rootdev="${DST}p${tgt_root}"

    # Setup loop device
    local LOOP
    LOOP=$(losetup -f)
    losetup -P "$LOOP" "$IMAGE_FILE"

    echo "Flashing kernel and root partitions..."
    dd if="${LOOP}p4" of="$kerndev" status=progress
    dd if="${LOOP}p3" of="$rootdev" status=progress

    echo "Updating kernel priority..."
    cgpt add "$DST" -i 4 -P 0
    cgpt add "$DST" -i 2 -P 0
    cgpt add "$DST" -i "$tgt_kern" -P 1

    defog
    losetup -d "$LOOP"
    rm -f "$IMAGE_FILE"

    read -p "Done! Press Enter to reboot."
    reboot
}

if [[ "$EUID" -ne 0 ]]; then
    echo "Please run as root."
    exit
fi

main
