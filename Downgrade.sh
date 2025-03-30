#!/bin/bash

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

install() {
    TMP=$(mktemp)
    get_asset "$1" >"$TMP"
    if [ "$?" == "1" ] || ! grep -q '[^[:space:]]' "$TMP"; then
        echo "Failed to install $1 to $2"
        rm -f "$TMP"
        exit
    fi
    cat "$TMP" >"$2"
    rm -f "$TMP"
}

get_asset() {
    curl -s -f "https://api.github.com/repos/rainestorme/murkmod/contents/$1" | jq -r ".content" | base64 -d
}

download_chrome_version() {
    local release_board=$(lsbval CHROMEOS_RELEASE_BOARD)
    local board=${release_board%%-*}

    local builds=$(curl -ks https://chromiumdash.appspot.com/cros/fetch_serving_builds?deviceCategory=Chrome%20OS)
    local hwid=$(jq "(.builds.$board[] | keys)[0]" <<<"$builds")
    local hwid=${hwid:1:-1}
    local milestones=$(jq ".builds.$board[].$hwid.pushRecoveries | keys | .[]" <<<"$builds")
    local VERSION=$(echo "$milestones" | tail -n 1 | tr -d '"')
    echo "Latest version is $VERSION"

    local url="https://raw.githubusercontent.com/rainestorme/chrome100-json/main/boards/$board.json"
    local json=$(curl -ks "$url")
    chrome_versions=$(echo "$json" | jq -r '.pageProps.images[].chrome')
    echo "Found $(echo "$chrome_versions" | wc -l) versions of ChromeOS for your board on chrome100."
    echo "Searching for a match..."
    MATCH_FOUND=0
    for cros_version in $chrome_versions; do
        platform=$(echo "$json" | jq -r --arg version "$cros_version" '.pageProps.images[] | select(.chrome == $version) | .platform')
        channel=$(echo "$json" | jq -r --arg version "$cros_version" '.pageProps.images[] | select(.chrome == $version) | .channel')
        mp_token=$(echo "$json" | jq -r --arg version "$cros_version" '.pageProps.images[] | select(.chrome == $version) | .mp_token')
        mp_key=$(echo "$json" | jq -r --arg version "$cros_version" '.pageProps.images[] | select(.chrome == $version) | .mp_key')
        last_modified=$(echo "$json" | jq -r --arg version "$cros_version" '.pageProps.images[] | select(.chrome == $version) | .last_modified')

        # If $cros_version starts with $VERSION, then we have a match
        if [[ $cros_version == $VERSION* ]]; then
            echo "Found a $VERSION match on platform $platform from $last_modified."
            MATCH_FOUND=1
            FINAL_URL="https://dl.google.com/dl/edgedl/chromeos/recovery/chromeos_${platform}_${board}_recovery_${channel}_${mp_token}-v${mp_key}.bin.zip"
            break
        fi
    done

    if [ $MATCH_FOUND -eq 0 ]; then
        echo "No match found on chrome100. Falling back to Chromium Dash."
        local builds=$(curl -ks https://chromiumdash.appspot.com/cros/fetch_serving_builds?deviceCategory=Chrome%20OS)
        local hwid=$(jq "(.builds.$board[] | keys)[0]" <<<"$builds")
        local hwid=${hwid:1:-1}

        milestones=$(jq ".builds.$board[].$hwid.pushRecoveries | keys | .[]" <<<"$builds")
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

    if [ $MATCH_FOUND -eq 0 ]; then
        echo "No recovery image found for your board and target version. Exiting."
        exit
    fi

    # Begin Downloading and Installing Recovery Image
    echo "Downloading recovery image from '$FINAL_URL'..."
    curl --progress-bar -k "$FINAL_URL" -o recovery.zip
    echo "Unzipping image... (this may take a while)"
    unzip -o recovery.zip
    rm recovery.zip

    FILENAME=$(find . -maxdepth 2 -name "chromeos_*.bin")
    echo "Found recovery image from archive at $FILENAME"
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

    # Invoke Image Patcher
    echo "Invoking image_patcher.sh..."
    bash ./image_patcher.sh "$FILENAME"
    echo "Patching complete."
}

download_chrome_version
EOF
