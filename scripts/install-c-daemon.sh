#!/bin/bash
#
# install-c-daemon.sh - Build and install the RME ADI-2 ALSA control bridge
#
# This script:
# 1. Installs build dependencies
# 2. Compiles rme-adi2-ctl
# 3. Installs the binary and systemd service
# 4. Configures moOde for hardware mixer mode
#
# Usage: sudo ./install-c-daemon.sh [options]
#
# Options:
#   --device-id ID    RME device ID: 0x71=DAC, 0x72=Pro (default), 0x73=Pro SE
#   --output TYPE     Output type: line (default) or phones
#   --no-moode        Skip moOde-specific configuration
#   --uninstall       Remove installation

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Defaults
DEVICE_ID="0x72"
OUTPUT="line"
MIN_DB="-70"
MAX_DB="-15"
CONFIGURE_MOODE=1
UNINSTALL=0

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --device-id)
            DEVICE_ID="$2"
            shift 2
            ;;
        --output)
            OUTPUT="$2"
            shift 2
            ;;
        --min-db)
            MIN_DB="$2"
            shift 2
            ;;
        --max-db)
            MAX_DB="$2"
            shift 2
            ;;
        --no-moode)
            CONFIGURE_MOODE=0
            shift
            ;;
        --uninstall)
            UNINSTALL=1
            shift
            ;;
        -h|--help)
            echo "Usage: sudo $0 [options]"
            echo ""
            echo "Options:"
            echo "  --device-id ID    RME device ID: 0x71=DAC, 0x72=Pro, 0x73=Pro SE"
            echo "  --output TYPE     Output type: line or phones"
            echo "  --min-db DB       Minimum dB at 0% volume (default: -60)"
            echo "  --max-db DB       Maximum dB at 100% volume (default: -15)"
            echo "  --no-moode        Skip moOde-specific configuration"
            echo "  --uninstall       Remove installation"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Check root
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root (sudo)"
    exit 1
fi

# Uninstall
if [[ $UNINSTALL -eq 1 ]]; then
    echo "Uninstalling rme-adi2-ctl..."
    systemctl stop rme-adi2-ctl 2>/dev/null || true
    systemctl disable rme-adi2-ctl 2>/dev/null || true
    rm -f /etc/systemd/system/rme-adi2-ctl.service
    rm -f /usr/local/bin/rme-adi2-ctl
    rm -f /etc/udev/rules.d/99-rme-adi2.rules
    udevadm control --reload-rules 2>/dev/null || true
    systemctl daemon-reload
    echo "Uninstalled."
    exit 0
fi

echo "=== RME ADI-2 ALSA Control Bridge Installation ==="
echo ""
echo "Configuration:"
echo "  Device ID: $DEVICE_ID"
echo "  Output: $OUTPUT"
echo "  Volume range: $MIN_DB dB to $MAX_DB dB"
echo "  Configure moOde: $([ $CONFIGURE_MOODE -eq 1 ] && echo yes || echo no)"
echo ""

# Install build dependencies
echo "Installing build dependencies..."
if command -v apt-get &>/dev/null; then
    apt-get update -qq
    apt-get install -y -qq build-essential libasound2-dev pkg-config
elif command -v dnf &>/dev/null; then
    dnf install -y gcc make alsa-lib-devel pkgconfig
elif command -v pacman &>/dev/null; then
    pacman -S --noconfirm gcc make alsa-lib pkgconf
else
    echo "Warning: Unknown package manager. Please install: gcc, make, libasound2-dev"
fi

# Build
echo "Building rme-adi2-ctl..."
cd "$PROJECT_DIR/alsa-plugin"
make clean 2>/dev/null || true
make

# Install binary
echo "Installing binary..."
make install

# Create service file with configured options
echo "Installing systemd service..."
cat > /etc/systemd/system/rme-adi2-ctl.service << EOF
[Unit]
Description=RME ADI-2 ALSA Control Bridge
Documentation=https://github.com/JendaT/rme-adi-2-pro-volume
After=sound.target
Before=mpd.service

[Service]
Type=simple
ExecStart=/usr/local/bin/rme-adi2-ctl --card ADI-2 --device $DEVICE_ID --output $OUTPUT --min-db $MIN_DB --max-db $MAX_DB
Restart=on-failure
RestartSec=5

NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload

# Configure moOde
if [[ $CONFIGURE_MOODE -eq 1 ]] && [[ -f /var/local/www/db/moode-sqlite3.db ]]; then
    echo "Configuring moOde for hardware mixer..."
    sqlite3 /var/local/www/db/moode-sqlite3.db \
        "UPDATE cfg_mpd SET value='hardware' WHERE param='mixer_type';"
    sqlite3 /var/local/www/db/moode-sqlite3.db \
        "UPDATE cfg_mpd SET value='ADI2' WHERE param='mixer_control';"
fi

# Install udev rule for hotplug support
echo "Installing udev rule for hotplug..."
if [[ -f "$PROJECT_DIR/udev/99-rme-adi2.rules" ]]; then
    cp "$PROJECT_DIR/udev/99-rme-adi2.rules" /etc/udev/rules.d/
    udevadm control --reload-rules
fi

# Enable and start
echo "Enabling and starting service..."
systemctl enable rme-adi2-ctl
systemctl start rme-adi2-ctl

# Restart MPD if running
if systemctl is-active --quiet mpd; then
    echo "Restarting MPD..."
    systemctl restart mpd
fi

echo ""
echo "=== Installation Complete ==="
echo ""
echo "Service status:"
systemctl status rme-adi2-ctl --no-pager || true
echo ""
echo "Verify the control exists:"
echo "  amixer sget ADI2"
echo ""
echo "Test volume change:"
echo "  amixer sset ADI2 300  # Set to -30 dB"
