#!/bin/bash

LOGFILE="/var/log/kernver.log"
DEBUG=${DEBUG:-0}

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "$LOGFILE"
}

if [ "$DEBUG" -eq 1 ]; then
    set -x
    log "Debug mode enabled."
fi

show_result() {
    if [ $? -eq 0 ]; then
        echo "✔ Success!"
        log "Success!"
    else
        echo "✘ Failed! See error above."
        log "Failed!"
    fi
}

set_kernver_tpmc() {
    log "Stopping trunksd..."
    sudo initctl stop trunksd 2>/dev/null || sudo pkill -f trunksd
    log "Stopping tcsd..."
    sudo initctl stop tcsd 2>/dev/null || sudo pkill -f tcsd

    log "Setting kernver with tpmc..."
    sudo tpmc write 0x1008 02 4c 57 52 47 0 0 0 0 0 0 0 e8 2>&1
    show_result
}

set_kernver_echo() {
    log "Setting kernver with echo..."
    if [ -w /dev/mem ]; then
        echo -n -e '\x02\x4c\x57\x52\x47\x00\x00\x00\x00\x00\x00\x00\xe8' | sudo tee /dev/mem > /dev/null 2>&1
        show_result
    else
        echo "✘ /dev/mem is not writable!"
        log "Failed: /dev/mem is not writable!"
    fi
}

set_kernver_sysctl() {
    log "Setting kernver with sysctl..."
    if sysctl -a 2>/dev/null | grep -q "kernel.kernver"; then
        sudo sysctl -w kernel.kernver=0x00000000 2>&1
        show_result
    else
        echo "✘ kernel.kernver not found!"
        log "Failed: kernel.kernver not found!"
    fi
}

set_kernver_dd() {
    log "Setting kernver with dd..."
    if [ -w /dev/mem ]; then
        echo -n -e '\x02\x4c\x57\x52\x47\x00\x00\x00\x00\x00\x00\x00\xe8' | sudo dd of=/dev/mem bs=1 seek=0x1008 2>&1
        show_result
    else
        echo "✘ /dev/mem is not writable!"
        log "Failed: /dev/mem is not writable!"
    fi
}

set_kernver_cmdline() {
    log "Setting kernver with cmdline..."
    if [ -w /proc/cmdline ]; then
        sudo sh -c "echo 'kernver=0x00000000' > /proc/cmdline" 2>&1
        show_result
    else
        echo "✘ /proc/cmdline is not writable!"
        log "Failed: /proc/cmdline is not writable!"
    fi
}

set_kernver_fw_off_dd() {
    log "Setting kernver (FWP off) with dd..."
    if [ -w /dev/mem ]; then
        echo -n -e '\x02\x4c\x57\x52\x47\x00\x00\x00\x00\x00\x00\x00\xe8' | sudo dd of=/dev/mem bs=1 seek=0x1008 2>&1
        show_result
    else
        echo "✘ /dev/mem is not writable!"
        log "Failed: /dev/mem is not writable!"
    fi
}

set_kernver_fw_off_flashrom() {
    log "Setting kernver (FWP off) with flashrom..."
    if command -v flashrom &> /dev/null; then
        sudo flashrom --wp-disable --programmer internal -w /path/to/kernver_flash.bin 2>&1
        show_result
    else
        echo "✘ flashrom not installed!"
        log "Failed: flashrom not installed!"
    fi
}

menu() {
    while true; do
        echo "----------------------"
        echo "  Kernver Modifier   "
        echo "----------------------"
        echo "1) tpmc"
        echo "2) echo"
        echo "3) sysctl"
        echo "4) dd"
        echo "5) cmdline"
        echo "----------------------"
        echo "6) FWP Off Methods"
        echo "7) Exit"
        echo "----------------------"
        read -rp "Choose an option: " choice

        case "$choice" in
            1) set_kernver_tpmc ;;
            2) set_kernver_echo ;;
            3) set_kernver_sysctl ;;
            4) set_kernver_dd ;;
            5) set_kernver_cmdline ;;
            6)
                echo "FWP Off Options:"
                echo "1) dd"
                echo "2) flashrom"
                read -rp "Choose an option: " fwp_choice
                case "$fwp_choice" in
                    1) set_kernver_fw_off_dd ;;
                    2) set_kernver_fw_off_flashrom ;;
                    *) echo "Invalid option." ;;
                esac
                ;;
            7) log "Exiting..."; exit 0 ;;
            *) echo "Invalid option." ;;
        esac
    done
}

menu
