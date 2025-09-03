#!/bin/bash
fail() {
    echo "[!] $1"
    exit 1
}

show_logo() {
    clear
    cat <<'EOF'
   ___  _                                 ___                       __ _                _
  / __|| |_   _ _  ___  _ __   ___       |   \  ___  _ __ __  _ _  / _` | _ _  __ _  __| | ___  _ _
 | (__ |   \ | '_|/ _ \| '  \ / -/)      | |) |/ _ \ \ V  V /| ' \ \__. || '_|/ _` |/ _` |/ -_)|'_|
  \___||_||_||_|  \___/|_|_|_|\___|      |___/ \___/  \_/\_/ |_||_||___/ |_|  \__/_|\__/_|\___||_|
EOF
    echo "ChromeOS Downgrade/Install Script (VT2 compatible)"
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
        1) VERSION="latest"; FINAL_URL="https://dl.google.com/dl/edgedl/chromeos/recovery/chromeos_16295.74.0_nissa_recovery_stable-channel_NissaMPKeys-v58.bin.zip" ;;
        2) VERSION="oldest"; FINAL_URL="https://dl.google.com/dl/edgedl/chromeos/recovery/chromeos_15117.112.0_hatch_recovery_stable-channel_mp-v6.bin.zip" ;;
        3) 
            echo -n "Enter full recovery URL: "
            read FINAL_URL < /dev/tty
            VERSION="custom"
            ;;
        *) fail "Invalid choice" ;;
    esac
    echo "[*] Selected version: $VERSION"
    echo "[*] URL: $FINAL_URL"
}

download_image() {
    echo "[*] Downloading recovery image..."
    curl -L -o recovery.zip "$FINAL_URL" || fail "Download failed"
    echo "[*] Unzipping recovery image..."
    unzip -o recovery.zip || fail "Unzip failed"
    rm recovery.zip
    echo "[*] Recovery image ready."
}

install_image() {
    echo -n "Do you want to install the downloaded image? This will overwrite your partitions. [y/N]: "
    read confirm < /dev/tty
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        IMAGE_FILE=$(find . -maxdepth 1 -name "*.bin" | head -n1)
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
    choose_version
    download_image
    install_image
}

main
