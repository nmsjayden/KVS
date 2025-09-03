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
    echo "ChromeOS Downgrade/Upgrade Script (VT2 terminal compatible)"
}

detect_board() {
    if [ -f /etc/lsb-release ]; then
        BOARD=$(grep -m1 "^CHROMEOS_RELEASE_BOARD=" /etc/lsb-release | cut -d'=' -f2)
        BOARD="${BOARD%%-*}"
    else
        fail "Cannot detect board automatically."
    fi
    echo "[*] Detected board: $BOARD"
}

choose_version() {
    echo
    echo "Select ChromeOS version to install:"
    echo "1) latest"
    echo "2) oldest"
    echo "3) custom"
    echo -n "(1-3) > "
    read choice < /dev/tty
    case $choice in
        1) VERSION="latest" ;;
        2) VERSION="oldest" ;;
        3)
            echo -n "Enter milestone version: "
            read VERSION < /dev/tty
            ;;
        *) fail "Invalid choice" ;;
    esac
    echo "[*] Selected version: $VERSION"
}

download_image() {
    echo "[*] Downloading recovery image from cros.download..."
    cros.download "$BOARD" "$VERSION" || fail "Download failed."
    echo "[*] Download complete."
}

install_image() {
    echo
    echo -n "Do you want to install the downloaded image? This will overwrite your partitions. [y/N]: "
    read confirm < /dev/tty
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        IMAGE_FILE=$(find . -maxdepth 1 -name "*${BOARD}*.bin" | head -n1)
        [ -f "$IMAGE_FILE" ] || fail "Downloaded image not found"

        DST=$(lsblk -d -o NAME,SIZE,MODEL | grep -v 'loop\|ram' | awk '{print "/dev/"$1}' | head -n1)
        echo "[*] Installing to $DST"

        LOOP=$(losetup -f)
        losetup "$LOOP" "$IMAGE_FILE"
        dd if="${LOOP}" of="$DST" bs=4M status=progress
        losetup -d "$LOOP"

        echo "[*] Installation complete. Reboot to use the new ChromeOS image."
    else
        echo "[*] Installation skipped."
    fi
}

main() {
    show_logo
    detect_board
    choose_version
    download_image
    install_image
}

main
