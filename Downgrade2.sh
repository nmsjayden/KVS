#!/bin/bash
fail() { echo "[!] $1"; exit 1; }

# Ensure unzip is available
if ! command -v unzip &>/dev/null; then
    echo "[*] unzip not found. Installing via dev_install..."
    sudo dev_install unzip || fail "Failed to install unzip"
fi

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

detect_board() {
    if [ -f /etc/lsb-release ]; then
        BOARD=$(grep -m1 "^CHROMEOS_RELEASE_BOARD=" /etc/lsb-release | cut -d'=' -f2)
        BOARD="${BOARD%%-*}"
    else
        fail "Cannot detect board automatically."
    fi
    echo "[*] Detected board: $BOARD"
}

fetch_versions() {
    echo "[*] Fetching Chromium Dash data..."
    BUILDS_JSON=$(curl -s "https://chromiumdash.appspot.com/cros/fetch_serving_builds?deviceCategory=Chrome%20OS")
    HWID=$(jq -r "(.builds.$BOARD[] | keys[0])" <<<"$BUILDS_JSON")
    MILESTONES=$(jq -r ".builds.$BOARD[].$HWID.pushRecoveries | keys | .[]" <<<"$BUILDS_JSON" | sort -V)
    
    OLDEST_MILESTONE=$(echo "$MILESTONES" | head -n1)
    LATEST_MILESTONE=$(echo "$MILESTONES" | tail -n1)
    
    OLDEST_URL=$(jq -r ".builds.$BOARD[].$HWID.pushRecoveries[\"$OLDEST_MILESTONE\"]" <<<"$BUILDS_JSON")
    LATEST_URL=$(jq -r ".builds.$BOARD[].$HWID.pushRecoveries[\"$LATEST_MILESTONE\"]" <<<"$BUILDS_JSON")
    
    echo "[*] Latest milestone: $LATEST_MILESTONE"
    echo "[*] Oldest milestone: $OLDEST_MILESTONE"
}

choose_version() {
    echo
    echo "Select ChromeOS version to install:"
    echo "1) latest"
    echo "2) oldest"
    echo "3) custom URL"
    echo -n "(1-3) > "
    read choice < /dev/tty

    case $choice in
        1) VERSION="latest"; FINAL_URL="$LATEST_URL" ;;
        2) VERSION="oldest"; FINAL_URL="$OLDEST_URL" ;;
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
    detect_board
    fetch_versions
    choose_version
    download_image
    install_image
}

main
