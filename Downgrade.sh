#!/bin/bash

show_logo() {
    clear
    echo -e "                      __                      .___\n  _____  __ _________|  | __ _____   ____   __| _/\n /     \|  |  \_  __ \  |/ //     \ /  _ \ / __ | \n|  Y Y  \  |  /|  | \/    <|  Y Y  (  <_> ) /_/ | \n|__|_|  /____/ |__|  |__|_ \__|_|  /\____/\____ | \n      \/                  \/     \/            \/\n"
    echo "The fakemurk plugin manager - ChromeOS Installer"
}

get_recovery_image() {
    local VERSION="$1"
    local release_board=$(grep "CHROMEOS_RELEASE_BOARD" /etc/lsb-release | cut -d '=' -f2 | cut -d '-' -f1)
    local url="https://raw.githubusercontent.com/rainestorme/chrome100-json/main/boards/$release_board.json"
    local json=$(curl -ks "$url")
    
    if [[ -z "$json" || "$json" == "null" ]]; then
        echo "Error: Unable to retrieve data for board '$release_board'. Check network connection or board name."
        exit 1
    fi
    
    chrome_versions=$(echo "$json" | jq -r '.pageProps.images[].chrome')
    echo "Found $(echo "$chrome_versions" | wc -l) versions of ChromeOS for your board."
    echo "Searching for a match..."
    MATCH_FOUND=0
    
    for cros_version in $chrome_versions; do
        if [[ $cros_version == $VERSION* ]]; then
            platform=$(echo "$json" | jq -r --arg version "$cros_version" '.pageProps.images[] | select(.chrome == $version) | .platform')
            channel=$(echo "$json" | jq -r --arg version "$cros_version" '.pageProps.images[] | select(.chrome == $version) | .channel')
            mp_token=$(echo "$json" | jq -r --arg version "$cros_version" '.pageProps.images[] | select(.chrome == $version) | .mp_token')
            mp_key=$(echo "$json" | jq -r --arg version "$cros_version" '.pageProps.images[] | select(.chrome == $version) | .mp_key')
            last_modified=$(echo "$json" | jq -r --arg version "$cros_version" '.pageProps.images[] | select(.chrome == $version) | .last_modified')
            echo "Found a $VERSION match on platform $platform from $last_modified."
            FINAL_URL="https://dl.google.com/dl/edgedl/chromeos/recovery/chromeos_${platform}_${release_board}_recovery_${channel}_${mp_token}-v${mp_key}.bin.zip"
            MATCH_FOUND=1
            break
        fi
    done
    
    if [ $MATCH_FOUND -eq 0 ]; then
        echo "No match found on chrome100. Exiting."
        exit 1
    fi

    mkdir -p /usr/local/tmp
    pushd /mnt/stateful_partition
        echo "Downloading recovery image from '$FINAL_URL'..."
        if ! curl --progress-bar -k "$FINAL_URL" -o recovery.zip; then
            echo "Error: Failed to download recovery image. Check network or URL."
            exit 1
        fi
        echo "Unzipping image..."
        if ! unzip -o recovery.zip; then
            echo "Error: Failed to unzip recovery image."
            exit 1
        fi
        rm recovery.zip
        FILENAME=$(find . -maxdepth 2 -name "chromeos_*.bin")
        if [[ -z "$FILENAME" ]]; then
            echo "Error: No recovery image found after extraction."
            exit 1
        fi
        echo "Found recovery image at $FILENAME"
        
        # Install the image
        echo "Installing recovery image..."
        local dst=$(get_largest_cros_blockdev)
        if [[ $dst == /dev/sd* ]]; then
            echo "WARNING: get_largest_cros_blockdev returned $dst - this doesn't seem correct!"
            echo "Press enter to view output from fdisk - find the correct drive and enter it below"
            read -r
            fdisk -l | more
            echo "Enter the target drive to use:"
            read dst
        fi
        
        # Assuming we need to patch the image
        pushd /usr/local/tmp
            echo "Installing image_patcher.sh..."
            install "image_patcher.sh" ./image_patcher.sh
            chmod 777 ./image_patcher.sh
            echo "Installing ssd_util.sh..."
            mkdir -p ./lib
            install "ssd_util.sh" ./lib/ssd_util.sh
            chmod 777 ./lib/ssd_util.sh
            echo "Installing common_minimal.sh..."
            install "common_minimal.sh" ./lib/common_minimal.sh
            chmod 777 ./lib/common_minimal.sh
        popd
        
        echo "Invoking image_patcher.sh..."
        bash /usr/local/tmp/image_patcher.sh "$FILENAME"
        
        echo "Patching complete. Determining target partitions..."
        local tgt_kern=$(opposite_num $(get_booted_kernnum))
        local tgt_root=$(( $tgt_kern + 1 ))
        local kerndev=${dst}p${tgt_kern}
        local rootdev=${dst}p${tgt_root}
        echo "Targeting $kerndev and $rootdev"
        
        echo "Installing kernel patch to ${kerndev}..."
        dd if="${loop}p4" of="$kerndev" status=progress
        echo "Installing root patch to ${rootdev}..."
        dd if="${loop}p3" of="$rootdev" status=progress
        
        echo "Defogging... (if write-protect is disabled, this will set GBB flags to 0x8091)"
        defog
        echo "Cleaning up..."
        losetup -d "$loop"
        rm -f "$FILENAME"
    popd
}

main() {
    show_logo
    echo "Enter the ChromeOS version you want to install (e.g., 119):"
    read -p "> " VERSION
    if [[ ! "$VERSION" =~ ^[0-9]+$ ]]; then
        echo "Error: Invalid version format. Please enter a numeric value."
        exit 1
    fi
    get_recovery_image "$VERSION"
    echo "Recovery image for ChromeOS $VERSION installed successfully!"
}

main
