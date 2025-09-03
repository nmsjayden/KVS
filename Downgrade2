#!/bin/bash
fail() {
    echo "[!] $1"
    exit 1
}

show_logo() {
    clear
    cat << 'EOF'
   ___  _                                 ___                       __ _                _
  / __|| |_   _ _  ___  _ __   ___       |   \  ___  _ __ __  _ _  / _` | _ _  __ _  __| | ___  _ _
 | (__ |   \ | '_|/ _ \| '  \ / -/)      | |) |/ _ \ \ V  V /| ' \ \__. || '_|/ _` |/ _` |/ -_)|'_|
  \___||_||_||_|  \___/|_|_|_|\___|      |___/ \___/  \_/\_/ |_||_||___/ |_|  \__/_|\__/_|\___||_|
EOF
    echo "ChromeOS version downloader & installer (VT2 terminal)"
}

detect_board() {
    if [ -f /etc/lsb-release ]; then
        BOARD=$(grep -m1 "^CHROMEOS_RELEASE_BOARD=" /etc/lsb-release | cut -d'=' -f2)
        BOARD="${BOARD%%-*}"
    else
        fail "Cannot detect board automatically. Please run on Chrome OS."
    fi
    echo "[*] Detected board: $BOARD"
}

select_version() {
    echo "Select Chrome OS version:"
    echo "1) latest"
    echo "2) oldest"
    echo "3) custom"
    read -p "(1-3) > " choice
    case $choice in
        1) VERSION="latest" ;;
        2) VERSION="oldest" ;;
        3) read -p "Enter milestone version: " VERSION ;;
        *) fail "Invalid choice" ;;
    esac
    echo "[*] Selected version: $VERSION"
}

download_image() {
    echo "[*] Downloading recovery image using cros.download..."
    if [[ "$VERSION" == "latest" || "$VERSION" == "oldest" ]]; then
        cros.download "$BOARD" "$VERSION" || fail "Download failed"
    else
        cros.download "$BOARD" "$VERSION" || fail "Download failed"
    fi
    echo "[*] Download complete."
}

install_image() {
    read -p "Do you want to install the downloaded image? This will overwrite partitions. [y/N]: " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        # Find downloaded file
        IMAGE_FILE=$(find . -maxdepth 1 -name "*${BOARD}*.bin" | head -n1)
        [ -f "$IMAGE_FILE" ] || fail "Downloaded image not found"

        # Detect largest non-removable ChromeOS block device
        DST=$(lsblk -d -o NAME,SIZE,MODEL | grep -v 'loop\|ram' | awk '{print "/dev/"$1}' | head -n1)
        echo "[*] Installing to $DST"

        # Use losetup and dd to write image (like your previous script)
        LOOP=$(losetup -f)
        losetup "$LOOP" "$IMAGE_FILE"
        dd if="${LOOP}" of="$DST" bs=4M status=progress
        losetup -d "$LOOP"

        echo "[*] Installation complete. Reboot to use new ChromeOS image."
    else
        echo "[*] Installation skipped."
    fi
}

main() {
    show_logo
    detect_board
    select_version
    download_image
    install_image
}

main
