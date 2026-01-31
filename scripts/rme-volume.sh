#!/bin/bash
#
# rme-volume.sh - Control RME ADI-2 Pro volume via MIDI SysEx
#
# Usage:
#   rme-volume.sh <volume_db>    Set volume in dB (e.g., -30, -45.5)
#   rme-volume.sh mute           Mute output
#   rme-volume.sh unmute         Unmute output
#   rme-volume.sh toggle         Toggle mute
#   rme-volume.sh status         Query current volume (if supported)
#
# Environment variables:
#   RME_MIDI_PORT   - MIDI port (default: hw:0,0,0)
#   RME_DEVICE_ID   - Device ID: 71=DAC, 72=Pro, 73=Pro SE (default: 72)
#   RME_OUTPUT      - Output: line or phones (default: line)

set -euo pipefail

# Configuration
MIDI_PORT="${RME_MIDI_PORT:-hw:0,0,0}"
DEVICE_ID="${RME_DEVICE_ID:-72}"
OUTPUT="${RME_OUTPUT:-line}"

# Output parameter codes
declare -A OUTPUT_PARAMS=(
    ["line"]="1B"
    ["phones"]="4B"
)

# Mute parameter
MUTE_PARAM="61"

# RME Manufacturer ID
MFG_ID="00 20 0D"

# Convert dB to RME volume bytes
# Formula: value = (dB * 10) + 4096
# Then split into two 7-bit MIDI bytes: X = (value >> 7) & 0x1F, Y = value & 0x7F
db_to_bytes() {
    local db="$1"
    local value

    # Use awk for math (handles both integer and floating point)
    value=$(awk "BEGIN { printf \"%.0f\", ($db * 10) + 4096 }")

    # Clamp to valid range (1140 = -114dB to 4156 = +6dB)
    if (( value < 1140 )); then
        value=1140
    elif (( value > 4156 )); then
        value=4156
    fi

    # Split into two 7-bit bytes
    local x=$(( (value >> 7) & 0x1F ))
    local y=$(( value & 0x7F ))

    # Format as hex
    printf "%02X %02X" "$x" "$y"
}

# Send SysEx command to ADI-2
send_sysex() {
    local cmd="$1"
    local full_cmd="F0 $MFG_ID $DEVICE_ID 02 $cmd F7"

    if [[ "${VERBOSE:-}" == "1" ]]; then
        echo "Sending: $full_cmd" >&2
    fi

    amidi -p "$MIDI_PORT" -S "$full_cmd"
}

# Set volume in dB
set_volume() {
    local db="$1"
    local param="${OUTPUT_PARAMS[$OUTPUT]}"
    local bytes
    bytes=$(db_to_bytes "$db")

    send_sysex "$param $bytes"
    echo "Volume set to ${db} dB on $OUTPUT output"
}

# Set mute state (0=unmute, 1=mute)
set_mute() {
    local state="$1"
    # Mute uses same byte format, state is 0 or 1
    send_sysex "$MUTE_PARAM 00 0$state"

    if [[ "$state" == "1" ]]; then
        echo "Muted"
    else
        echo "Unmuted"
    fi
}

# Query device status (reads response)
query_status() {
    local response_file
    response_file=$(mktemp)

    # Send query command (03 09 = request all settings)
    echo "Querying device status..."
    amidi -p "$MIDI_PORT" -S "F0 $MFG_ID $DEVICE_ID 03 09 F7" -r "$response_file" -t 2

    if [[ -s "$response_file" ]]; then
        echo "Response received:"
        xxd "$response_file"
    else
        echo "No response (device may not support query or timeout too short)"
    fi

    rm -f "$response_file"
}

# Show usage
usage() {
    cat <<EOF
Usage: $(basename "$0") <command>

Commands:
    <dB>      Set volume in dB (e.g., -30, -45.5, 0)
    mute      Mute output
    unmute    Unmute output
    toggle    Toggle mute state
    status    Query current device status

Environment:
    RME_MIDI_PORT=$MIDI_PORT
    RME_DEVICE_ID=$DEVICE_ID (71=DAC, 72=Pro, 73=Pro SE)
    RME_OUTPUT=$OUTPUT (line, phones)
    VERBOSE=1 to show SysEx commands

Examples:
    $(basename "$0") -30        # Set to -30 dB
    $(basename "$0") -45.5      # Set to -45.5 dB
    $(basename "$0") mute       # Mute output
    VERBOSE=1 $(basename "$0") -20  # Set with debug output
EOF
    exit 1
}

# Main
main() {
    if [[ $# -lt 1 ]]; then
        usage
    fi

    local cmd="$1"

    case "$cmd" in
        -h|--help)
            usage
            ;;
        mute)
            set_mute 1
            ;;
        unmute)
            set_mute 0
            ;;
        toggle)
            # Toggle requires state tracking - for now just mute
            echo "Toggle not implemented (requires state tracking)"
            exit 1
            ;;
        status)
            query_status
            ;;
        *)
            # Assume it's a dB value
            if [[ "$cmd" =~ ^-?[0-9]+\.?[0-9]*$ ]]; then
                set_volume "$cmd"
            else
                echo "Error: Invalid command or volume value: $cmd" >&2
                usage
            fi
            ;;
    esac
}

main "$@"
