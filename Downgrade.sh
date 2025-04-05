#!/bin/bash

CURRENT_MAJOR=6
CURRENT_MINOR=1
CURRENT_VERSION=1

show_logo() {
    clear
    cat << 'EOF'
   ___  _                                 ___                       __ _                _
  / __|| |_   _ _  ___  _ __   ___       |   \  ___  _ __ __  _ _  / _` | _ _  __ _  __| | ___  _ _
 | (__ |   \ | '_|/ _ \| '  \ / -/)      | |) |/ _ \ \ V  V /| ' \ \__. || '_|/ _` |/ _` |/ -_)|'_|
  \___||_||_||_|  \___/|_|_|_|\___|      |___/ \___/  \_/\_/ |_||_||___/ |_|  \__/_|\__/_|\___||_|
EOF
    echo "Yes, I skidded off of MurkMod - v1.6.31 - Developer mode downgrader"
}

list_versions() {
    local release_board=$(lsbval CHROMEOS_RELEASE_BOARD)
    local board=${release_board%%-*}
    echo "Fetching available versions for board: $board..."
    
    # Get ChromeOS versions from chrome100 or chromiumdash
    local url="https://raw.githubusercontent.com/rainestorme/chrome100-json/main/boards/$board.json"
    local json=$(curl -ks "$url")
    
    if [ -z "$json" ]; then
        echo "Failed to fetch versions for board $board. Exiting."
        exit 1
    fi

    local chrome_versions=$(echo "$json" | jq -r '.pageProps.images[].chrome')

    if [ -z "$chrome_versions" ]; then
        echo "No versions found for board $board."
        exit 1
    fi

    # Prepare an array to hold unique major.minor versions
    declare -A unique_versions

    local i=1
    local count=0
    local first_run=true
    local versions=()

    # Loop over all versions and save them to an array
    for cros_version in $(echo "$chrome_versions" | sort -V); do
        # Extract the major.minor version part (e.g., 124.0)
        major_minor=$(echo "$cros_version" | cut -d'.' -f1,2)
        
        # If this major.minor version hasn't been added yet, add it
        if [ -z "${unique_versions[$major_minor]}" ]; then
            unique_versions[$major_minor]=$cros_version
            platform=$(echo "$json" | jq -r --arg version "$cros_version" '.pageProps.images[] | select(.chrome == $version) | .platform')
            channel=$(echo "$json" | jq -r --arg version "$cros_version" '.pageProps.images[] | select(.chrome == $version) | .channel')

            # Save the version and related info into the array
            versions+=("$cros_version | Platform: $platform | Channel: $channel")
        fi
    done

    # Loop through the versions array and show 5 at a time
    total_versions=${#versions[@]}
    total_pages=$((total_versions / 5))
    if [ $((total_versions % 5)) -ne 0 ]; then
        total_pages=$((total_pages + 1))
    fi

    for page in $(seq 0 $((total_pages - 1))); do
        echo "-------------------------------------"
        start_index=$((page * 5))
        end_index=$(((page + 1) * 5 - 1))
        if [ $end_index -ge $total_versions ]; then
            end_index=$((total_versions - 1))
        fi
        # Display versions for the current page
        for i in $(seq $start_index $end_index); do
            echo "$((i + 1))) ${versions[$i]}"
        done
        # Wait for the user to press Enter to show more
        if [ $page -lt $((total_pages - 1)) ]; then
            read -r -p "Press Enter to continue for more versions, or Ctrl+C to exit."
        fi
    done

    echo "-------------------------------------"

    # Prompt if the user wants to go back to the menu before selecting a version
    read -r -p "Do you want to go back to the downgrade menu? (y/n): " back_to_menu
    if [[ "$back_to_menu" =~ ^[Yy]$ ]]; then
        clear  # Clear the terminal screen
        main  # Go back to the main menu
        return  # Exit the list_versions function
    fi

    # Otherwise, proceed to version selection
    read -r -p "Select a version number from the list (1-${#versions[@]}): " selection
    if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le ${#versions[@]} ]; then
        VERSION=$(echo "${versions[$selection-1]}" | cut -d' ' -f1)
        echo "You selected version: $VERSION"
    else
        echo "Invalid selection. Returning to the main menu."
        return  # This will exit the list_versions function and go back to the main menu
    fi

    # Ask if the user wants to go back to the downgrade menu
    read -r -p "Do you want to go back to the downgrade menu? (y/n): " response
    if [[ "$response" =~ ^[Yy]$ ]]; then
        read -r -p "Are you sure you want to go back to the menu? (y/n): " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            clear  # Clear the terminal screen
            main  # Assuming `downgrade_menu` is the function to bring the user back to the menu
        fi
    fi
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
    echo " 1) list versions"
    echo " 2) latest"
    echo " 3) custom"
    read -p "(1-3) > " choice

    case $choice in
        1) list_versions ;;
        2) VERSION="latest" ;;
        3) read -p "Enter milestone: " VERSION ;;
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
    echo "Found $(echo "$chrome_versions" | wc -l) versions of chromeOS for your board on chrome100."
    echo "Searching for a match..."
    MATCH_FOUND=0
    for cros_version in $chrome_versions; do
        platform=$(echo "$json" | jq -r --arg version "$cros_version" '.pageProps.images[] | select(.chrome == $version) | .platform')
        channel=$(echo "$json" | jq -r --arg version "$cros_version" '.pageProps.images[] | select(.chrome == $version) | .channel')
        mp_token=$(echo "$json" | jq -r --arg version "$cros_version" '.pageProps.images[] | select(.chrome == $version) | .mp_token')
        mp_key=$(echo "$json" | jq -r --arg version "$cros_version" '.pageProps.images[] | select(.chrome == $version) | .mp_key')
        last_modified=$(echo "$json" | jq -r --arg version "$cros_version" '.pageProps.images[] | select(.chrome == $version) | .last_modified')
        # if $cros_version starts with $VERSION, then we have a match
        if [[ $cros_version == $VERSION* ]]; then
            echo "Found a $VERSION match on platform $platform from $last_modified."
            MATCH_FOUND=1
            #https://dl.google.com/dl/edgedl/chromeos/recovery/chromeos_15117.112.0_hatch_recovery_stable-channel_mp-v6.bin.zip
            FINAL_URL="https://dl.google.com/dl/edgedl/chromeos/recovery/chromeos_${platform}_${board}_recovery_${channel}_${mp_token}-v${mp_key}.bin.zip"
            break
        fi
    done
    if [ $MATCH_FOUND -eq 0 ]; then
        echo "No match found on chrome100. Falling back to Chromium Dash."
        local builds=$(curl -ks https://chromiumdash.appspot.com/cros/fetch_serving_builds?deviceCategory=Chrome%20OS)
        local hwid=$(jq "(.builds.$board[] | keys)[0]" <<<"$builds")
        local hwid=${hwid:1:-1}

        # Get all milestones for the specified hwid
        milestones=$(jq ".builds.$board[].$hwid.pushRecoveries | keys | .[]" <<<"$builds")

        # Loop through all milestones
        echo "Searching for a match..."
        for milestone in $milestones; do
            milestone=$(echo "$milestone" | tr -d '"')
            if [[ $milestone == $VERSION* ]]; then
                MATCH_FOUND=1
                FINAL_URL=$(jq -r ".builds.$board[].$hwid.pushRecoveries[\"$milestone\"]" <<<"$builds")
                echo "Found a match!"
                break
            fi
        done
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
