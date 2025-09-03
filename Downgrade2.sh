#!/bin/bash
# ChromeOS Downgrade Script - Updated for TTY-safe and non-interactive execution
# Includes BusyBox unzip download and kernver detection

show_logo() {
    clear
    cat << 'EOF'
   ___  _                                 ___                       __ _                _
  / __|| |_   _ _  ___  _ __   ___       |   \  ___  _ __ __  _ _  / _` | _ _  __ _  __| | ___  _ _
 | (__ |   \ | '_|/ _ \| '  \ / -/)      | |) |/ _ \ \ V  V /| ' \ \__. || '_|/ _` |/ _` |/ -_)|'_|
  \___||_||_||_|  \___/|_|_|_|\___|      |___/ \___/  \_/\_/ |_||_||___/ |_|  \__/_|\__/_|\___||_|
EOF
    echo "Downgrade2 - Developer Mode ChromeOS Recovery"
}

# ---------------------------
# TTY-safe read helper
# ---------------------------
read_safe() {
    local prompt="$1"
    local default="$2"
    local varname="$3"

    if [ -t 0 ] && [ -r /dev/tty ]; then
        read -rp "$prompt" "$varname" < /dev/tty
    else
        echo "[*] No TTY detected, using default '$default' for $varname"
        eval "$varname=\"$default\""
    fi
}

# ---------------------------
# Kernver detection
# ---------------------------
detect_kernver() {
    local tpm_line
    tpm_line=$(sudo crossystem 2>/dev/null | grep "TPM:" || echo "TPM: 0")
    KERNVER=${tpm_line: -1}
    echo "[*] Detected kernver: $KERNVER"
}

# ---------------------------
# BusyBox unzip downloader
# ---------------------------
ensure_unzip() {
    if ! command -v unzip &> /dev/null; then
        echo "[*] unzip not found. Downloading BusyBox..."
        mkdir -p /usr/local/tmp
        curl -L https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox \
     -o /usr/local/tmp/unzip \
     --progress-bar
        chmod +x /usr/local/tmp/unzip
        UNZIP_CMD="/usr/local/tmp/unzip"
    else
        UNZIP_CMD="unzip"
    fi
}

# ---------------------------
# Helper: Get largest ChromeOS block device
# ---------------------------
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

# ---------------------------
# Main recovery flow
# ---------------------------
main() {
    if [ "$EUID" -ne 0 ]; then
        echo "[!] Please run as root."
        exit 1
    fi

    show_logo
    detect_kernver
    ensure_unzip

    # Default environment variables
    : "${VMODE:=N}"
    : "${VERSION:=latest}"
    : "${USE_ORIG_SPLASH:=0}"

    # Prompt for Verified/Dev Mode if TTY
    read_safe "Do you want Verified Mode (Y/N)? " "$VMODE" VMODE
    read_safe "ChromeOS version to install (latest/custom)? " "$VERSION" VERSION

    local release_board
    release_board=$(grep -m1 "^CHROMEOS_RELEASE_BOARD=" /etc/lsb-release | cut -d= -f2)
    local board=${release_board%%-*}

    echo "[*] Fetching recovery image URL for $board version $VERSION..."
    local FINAL_URL

    if [ "$VERSION" = "latest" ]; then
        local builds hwid milestones
        builds=$(curl -ks https://chromiumdash.appspot.com/cros/fetch_serving_builds?deviceCategory=Chrome%20OS)
        hwid=$(jq "(.builds.$board[] | keys)[0]" <<<"$builds")
        hwid=${hwid:1:-1}
        milestones=$(jq ".builds.$board[].$hwid.pushRecoveries | keys | .[]" <<<"$builds")
        VERSION=$(echo "$milestones" | tail -n 1 | tr -d '"')
        echo "[*] Latest version detected: $VERSION"
    fi

    # Compose recovery URL
    FINAL_URL="https://dl.google.com/dl/edgedl/chromeos/recovery/chromeos_${board}_${board}_recovery_stable-channel_mp-v0.bin.zip"
    echo "[*] Using recovery image URL: $FINAL_URL"

    mkdir -p /usr/local/tmp
    pushd /usr/local/tmp >/dev/null || exit 1

    echo "[*] Downloading recovery image..."
    curl -L -o recovery.zip "$FINAL_URL"

    echo "[*] Extracting image..."
    "$UNZIP_CMD" -o recovery.zip
    rm recovery.zip
    local FILENAME
    FILENAME=$(find . -maxdepth 2 -name "chromeos_*.bin" | head -n1)
    echo "[*] Found recovery image: $FILENAME"

    local dst tgt_kern tgt_root kerndev rootdev loop
    dst=$(get_largest_cros_blockdev)
    if [[ $dst == /dev/sd* ]]; then
        read_safe "Detected $dst, press Enter to confirm or type correct drive: " "$dst" dst
    fi

    tgt_kern=2
    tgt_root=$((tgt_kern + 1))
    kerndev=${dst}p${tgt_kern}
    rootdev=${dst}p${tgt_root}

    loop=$(losetup -f)
    losetup -P "$loop" "$FILENAME"

    echo "[*] Flashing partitions..."
    dd if="${loop}p4" of="$kerndev" status=progress
    dd if="${loop}p3" of="$rootdev" status=progress

    echo "[*] Setting kernel priority..."
    cgpt add "$dst" -i 4 -P 0
    cgpt add "$dst" -i 2 -P 0
    cgpt add "$dst" -i "$tgt_kern" -P 1

    losetup -d "$loop"
    rm -f "$FILENAME"

    read -n 1 -s -r -p "Done! Press any key to reboot."
    reboot
}

if [ "$0" = "$BASH_SOURCE" ]; then
    main
fi
