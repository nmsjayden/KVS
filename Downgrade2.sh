#!/bin/bash
# ChromeOS Recovery & Downgrade Script with Kernver Check & BusyBox unzip

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

# ---------- Kernver Detection ----------
detect_kernver() {
    # Enter recovery screen, press Tab, read TPM number
    echo "[*] Detecting kernver from /proc/cmdline or TPM info..."
    if [ -r /proc/cmdline ]; then
        if grep -q "kernver=" /proc/cmdline; then
            KERNVER=$(grep -oP "kernver=\K\d" /proc/cmdline)
            echo "[INFO] Kernver detected from cmdline: $KERNVER"
            return
        fi
    fi
    # Fallback: prompt user for TPM number
    read -rp "Unable to detect kernver automatically. Enter TPM number (0-6): " KERNVER
    if ! [[ $KERNVER =~ ^[0-6]$ ]]; then
        echo "[!] Invalid kernver, defaulting to 0."
        KERNVER=0
    fi
    echo "[INFO] Using kernver: $KERNVER"
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

# ---------- Recovery Image Flash ----------
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
        echo "Detected target drive: $dst"
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

    echo "Select version to install (list/latest/custom):"
    read -rp "(1-3) > " choice
    case $choice in
        1) list_versions ;;
        2) VERSION="latest" ;;
        3) read -rp "Enter milestone: " VERSION ;;
        *) echo "Invalid choice"; exit 1 ;;
    esac

    # Compute FINAL_URL based on your Chrome100/Chromium Dash logic
    # ... same as your existing script

    flash_image "$FINAL_URL"
}

if [ "$0" = "$BASH_SOURCE" ]; then
    main
fi
