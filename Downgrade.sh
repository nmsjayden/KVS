#!/bin/bash

CURRENT_MAJOR=6
CURRENT_MINOR=1
CURRENT_VERSION=1

show_logo() {
    clear
    echo -e "   ___  _                                 ___                       __ _                _\n  / __|| |_   _ _  ___  _ __   ___       |   \\  ___  _ __ __  _ _  / _\` | _ _  __ _  __| | ___  _ _\n | (__ |   \\ | '_|/ _ \\| '  \\ / -/)      | |) |/ _ \\ \\ V  V /| ' \\ \\__. || '_|/ _\` |/ _\` |/ -/| '_|\n  \\___||_||_||_|  \\___/|_|_|_|\\___|      |___/ \\___/  \\_/\\_/ |_||_||___/ |_|  \\__/|_\\__/|\\___||_|"
    echo "The fakemurk plugin manager - v$CURRENT_MAJOR.$CURRENT_MINOR.$CURRENT_VERSION - Developer mode installer"
}

lsbval() {
  local key="$1"
  local lsbfile="${2:-/etc/lsb-release}"

  if ! echo "${key}" | grep -Eq '^[a-zA-Z0-9_]+$'; then
    return 1
  fi

  sed -E -n -e \
    "/^[[:space:]]*${key}[[:space:]]*=/{
      s:^[^=]+=[[:space:]]*::
      s:[[:space:]]+$::
      p
    }" "${lsbfile}"
}

install() {
    echo "Skipping install of $1 (Murkmode GitHub script disabled)."
    echo "#!/bin/true" > "$2"
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
    if (($(cgpt show -n "$dst" -i 2 -P) > $(cgpt show -n "$dst" -i 4 -P))); then
        echo -n 2
    else
        echo -n 4
    fi
}

defog() {
    futility gbb --set --flash --flags=0x8091 || true
    crossystem block_devmode=0 || true
    vpd -i RW_VPD -s block_devmode=0 || true
    vpd -i RW_VPD -s check_enrollment=1 || true
}

main() {
    show_logo
    echo "Starting ChromeOS image recovery process..."

    echo "What version do you want to install?"
    echo " 1) 105"
    echo " 2) 107"
    echo " 3) 117"
    echo " 4) 118"
    echo " 5) latest"
    echo " 6) custom"
    read -p "(1-6) > " choice

    case $choice in
        1) VERSION="105" ;;
        2) VERSION="107" ;;
        3) VERSION="117" ;;
        4) VERSION="118" ;;
        5) VERSION="latest" ;;
        6) read -p "Enter milestone: " VERSION ;;
        *) echo "Invalid choice, exiting." && exit ;;
    esac

    read -p "Use default bootsplash? [y/N] " use_orig_bootsplash
    case "$use_orig_bootsplash" in
        [yY]*) USE_ORIG_SPLASH="1" ;;
        *)     USE_ORIG_SPLASH="0" ;;
    esac

    local release_board=$(lsbval CHROMEOS_RELEASE_BOARD)
    local board=${release_board%%-*}

    if [ $VERSION == "latest" ]; then
        builds=$(curl -ks https://chromiumdash.appspot.com/cros/fetch_serving_builds?deviceCategory=Chrome%20OS)
        hwid=$(jq "(.builds.$board[] | keys)[0]" <<<"$builds")
        hwid=${hwid:1:-1}
        milestones=$(jq ".builds.$board[].$hwid.pushRecoveries | keys | .[]" <<<"$builds")
        VERSION=$(echo "$milestones" | tail -n 1 | tr -d '"')
        echo "Latest version is $VERSION"
    fi

    local url="https://raw.githubusercontent.com/rainestorme/chrome100-json/main/boards/$board.json"
    local json=$(curl -ks "$url")
    chrome_versions=$(echo "$json" | jq -r '.pageProps.images[].chrome')
    echo "Found ChromeOS versions for $board. Searching for $VERSION..."

    MATCH_FOUND=0
    for cros_version in $chrome_versions; do
        if [[ $cros_version == $VERSION* ]]; then
            platform=$(echo "$json" | jq -r --arg version "$cros_version" '.pageProps.images[] | select(.chrome == $version) | .platform')
            channel=$(echo "$json" | jq -r --arg version "$cros_version" '.pageProps.images[] | select(.chrome == $version) | .channel')
            mp_token=$(echo "$json" | jq -r --arg version "$cros_version" '.pageProps.images[] | select(.chrome == $version) | .mp_token')
            mp_key=$(echo "$json" | jq -r --arg version "$cros_version" '.pageProps.images[] | select(.chrome == $version) | .mp_key')
            FINAL_URL="https://dl.google.com/dl/edgedl/chromeos/recovery/chromeos_${platform}_${board}_recovery_${channel}_${mp_token}-v${mp_key}.bin.zip"
            MATCH_FOUND=1
            break
        fi
    done

    if [ $MATCH_FOUND -eq 0 ]; then
        echo "No match found on chrome100. Exiting."
        exit
    fi

    mkdir -p /usr/local/tmp
    pushd /mnt/stateful_partition
        set -e
        echo "Installing unzip..."
        curl --progress-bar -Lko /usr/local/tmp/unzip https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox
        chmod 777 /usr/local/tmp/unzip
        echo "Downloading recovery image..."
        curl --progress-bar -k "$FINAL_URL" -o recovery.zip
        echo "Unzipping image..."
        /usr/local/tmp/unzip -o recovery.zip
        rm recovery.zip
        FILENAME=$(find . -maxdepth 2 -name "chromeos_*.bin")
        echo "Found image: $FILENAME"

        echo "Skipping image patcher... ensure the image is already patched if necessary."

        local dst=$(get_largest_cros_blockdev)
        if [[ $dst == /dev/sd* ]]; then
            echo "WARNING: Detected $dst, please confirm it is correct."
            read -r -p "Enter correct drive or press Enter to use $dst: " custom_dst
            dst=${custom_dst:-$dst}
        fi

        local tgt_kern=$(get_booted_kernnum)
        tgt_kern=$( [ "$tgt_kern" = 2 ] && echo 4 || echo 2 )
        local tgt_root=$((tgt_kern + 1))
        local kerndev=${dst}p${tgt_kern}
        local rootdev=${dst}p${tgt_root}

        local loop=$(losetup -f | tail -1)
        losetup -P "$loop" "$FILENAME"

        echo "Overwriting partitions..."
        dd if="${loop}p4" of="$kerndev" status=progress
        dd if="${loop}p3" of="$rootdev" status=progress

        echo "Setting kernel priority..."
        cgpt add "$dst" -i 4 -P 0
        cgpt add "$dst" -i 2 -P 0
        cgpt add "$dst" -i "$tgt_kern" -P 1

        defog
        losetup -d "$loop"
        rm -f "$FILENAME"
    popd

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
