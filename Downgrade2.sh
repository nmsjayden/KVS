#!/bin/bash
# ChromeOS Downgrade2 VT2-Compatible Script with kernver check
# Uses TPM kernver to prevent installing too-old versions

fail() {
    echo "[!] $1"
    exit 1
}

# -------------------------------
# Kernver detection
# -------------------------------
get_kernver() {
    echo "[*] Detecting kernver..."
    TPM_LINE=$(crossystem 2>/dev/null | grep "^tpm_")
    if [ -z "$TPM_LINE" ]; then
        echo "[!] Could not read TPM info. Are you in dev mode / VT2?"
        KERNVER=-1
        return
    fi

    KERNVER=$(echo "$TPM_LINE" | grep -o '[0-6]$')
    echo "[*] Detected kernver: $KERNVER"

    case $KERNVER in
        0|1) MIN_VERSION="any" ;;
        2) MIN_VERSION="v111" ;;
        3) MIN_VERSION="v120" ;;
        4) MIN_VERSION="v125" ;;
        5) MIN_VERSION="v132.0.6834.201" ;;
        6) MIN_VERSION="v138.0.7204.221" ;;
        *) MIN_VERSION="unknown" ;;
    esac

    echo "[*] Minimum ChromeOS version allowed: $MIN_VERSION"
}

warn_version() {
    TARGET_VERSION=$1
    get_kernver
    [ "$KERNVER" -lt 0 ] && return

    if [ "$MIN_VERSION" != "any" ] && [[ "$TARGET_VERSION" < "$MIN_VERSION" ]]; then
        echo "[!] Warning: Your kernver ($KERNVER) requires minimum version $MIN_VERSION."
        echo "[!] Installing $TARGET_VERSION may fail."
        read -p "Continue anyway? [y/N]: " confirm < /dev/tty
        [[ ! "$confirm" =~ ^[Yy]$ ]] && fail "Aborted by user."
    fi
}

# -------------------------------
# Download & unzip recovery image
# -------------------------------
install_image() {
    IMAGE_URL=$1
    echo "[*] Downloading recovery image..."
    curl --progress-bar -L -o recovery.zip "$IMAGE_URL" || fail "Download failed"

    # Check for unzip
    if command -v unzip >/dev/null 2>&1; then
        unzip recovery.zip || fail "Failed to unzip"
    elif command -v python3 >/dev/null 2>&1; then
        echo "[*] unzip not found, using Python fallback..."
        python3 -m zipfile -e recovery.zip . || fail "Python unzip failed"
    else
        fail "No unzip method found (install unzip or python3)"
    fi

    FILENAME=$(find . -maxdepth 2 -name "chromeos_*.bin" | head -n1)
    [ -f "$FILENAME" ] || fail "Recovery image not found"
    echo "[*] Found recovery image: $FILENAME"

    # Detect target device
    DST=$(lsblk -d -o NAME,SIZE,MODEL | grep -v 'loop\|ram' | awk '{print "/dev/"$1}' | head -n1)
    read -p "Detected target: $DST. Use this? [Y/n]: " confirm < /dev/tty
    [[ "$confirm" =~ ^[Nn]$ ]] && read -p "Enter target device: " DST < /dev/tty

    echo "[*] Writing partitions..."
    LOOP=$(losetup -f --show "$FILENAME")
    losetup -P "$LOOP"

    KERN_PART=2
    ROOT_PART=3
    dd if="${LOOP}p4" of="${DST}p${KERN_PART}" status=progress
    dd if="${LOOP}p3" of="${DST}p${ROOT_PART}" status=progress

    # Set kernel priority
    cgpt add "$DST" -i 4 -P 0
    cgpt add "$DST" -i 2 -P 0
    cgpt add "$DST" -i "$KERN_PART" -P 1

    losetup -d "$LOOP"
    rm -f "$FILENAME" recovery.zip
    echo "[*] Image installation complete."
}

# -------------------------------
# Main menu
# -------------------------------
main() {
    echo "ChromeOS Downgrade2 VT2 Script"
    read -p "Enter recovery image URL: " IMAGE_URL < /dev/tty

    # Parse version from URL if possible (e.g., chromeos_16295.74.0)
    VERSION=$(echo "$IMAGE_URL" | grep -o 'chromeos_[0-9]*\.[0-9]*\.[0-9]*' | cut -d_ -f2)
    [ -z "$VERSION" ] && VERSION="unknown"
    echo "[*] Parsed version: $VERSION"

    warn_version "$VERSION"
    install_image "$IMAGE_URL"

    read -n 1 -s -r -p "Done! Press any key to reboot."
    reboot
}

if [ "$0" = "$BASH_SOURCE" ]; then
    if [ "$EUID" -ne 0 ]; then
        echo "Please run as root."
        exit
    fi
    main
fi
