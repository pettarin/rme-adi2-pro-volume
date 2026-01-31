#!/bin/bash
#
# Installation script for RME ADI-2 Volume Control for moOde
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

info() { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# Check if running as root for system-wide install
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root (use sudo)"
    fi
}

# Detect system architecture
detect_arch() {
    case "$(uname -m)" in
        aarch64) echo "aarch64-linux-gnu" ;;
        armv7l|armv6l) echo "arm-linux-gnueabihf" ;;
        x86_64) echo "x86_64-linux-gnu" ;;
        *) echo "unknown" ;;
    esac
}

# Install dependencies
install_deps() {
    info "Installing dependencies..."

    apt-get update
    apt-get install -y \
        alsa-utils \
        libasound2-dev \
        python3 \
        python3-pip \
        mpc

    # Optional: python-mpd2 for better MPD integration
    pip3 install python-mpd2 || warn "python-mpd2 not installed (optional)"
}

# Install shell script
install_shell_script() {
    info "Installing shell script..."

    cp "$PROJECT_DIR/scripts/rme-volume.sh" /usr/local/bin/
    chmod +x /usr/local/bin/rme-volume.sh

    info "Shell script installed: /usr/local/bin/rme-volume.sh"
}

# Install Python daemon
install_daemon() {
    info "Installing Python daemon..."

    cp "$PROJECT_DIR/daemon/rme-volumed.py" /usr/local/bin/
    chmod +x /usr/local/bin/rme-volumed.py

    # Install config if not exists
    if [[ ! -f /etc/rme-volumed.conf ]]; then
        cp "$PROJECT_DIR/daemon/rme-volumed.conf" /etc/
        info "Config installed: /etc/rme-volumed.conf"
    else
        warn "Config already exists at /etc/rme-volumed.conf - not overwriting"
    fi

    # Install systemd service
    cp "$PROJECT_DIR/systemd/rme-volumed.service" /etc/systemd/system/
    systemctl daemon-reload

    info "Daemon installed: /usr/local/bin/rme-volumed.py"
    info "Systemd service installed: /etc/systemd/system/rme-volumed.service"
}

# Build and install ALSA plugin
install_alsa_plugin() {
    info "Building ALSA control plugin..."

    cd "$PROJECT_DIR/alsa-plugin"

    # Detect plugin directory
    ARCH=$(detect_arch)
    if [[ "$ARCH" != "unknown" ]]; then
        ALSA_PLUGIN_DIR="/usr/lib/$ARCH/alsa-lib"
    else
        ALSA_PLUGIN_DIR="/usr/lib/alsa-lib"
    fi

    # Build plugin
    make clean
    make

    # Install plugin
    mkdir -p "$ALSA_PLUGIN_DIR"
    cp libasound_module_ctl_rme_adi2.so "$ALSA_PLUGIN_DIR/"

    info "ALSA plugin installed: $ALSA_PLUGIN_DIR/libasound_module_ctl_rme_adi2.so"

    # Install example config
    if [[ ! -f /etc/asound.conf ]]; then
        cp asound.conf.example /etc/asound.conf
        info "ALSA config installed: /etc/asound.conf"
    else
        warn "ALSA config already exists - see alsa-plugin/asound.conf.example"
    fi
}

# Configure moOde
configure_moode() {
    info "Configuring moOde..."

    # Check if moOde database exists
    MOODE_DB="/var/local/www/db/moode-sqlite3.db"
    if [[ -f "$MOODE_DB" ]]; then
        # Set volume type to Null (External Control)
        # Note: This modifies moOde's SQLite database directly
        # Volume type 3 = Null
        sqlite3 "$MOODE_DB" "UPDATE cfg_mpd SET value='3' WHERE param='mixer_type';"
        info "moOde volume type set to Null (External Control)"
        info "Restart moOde for changes to take effect"
    else
        warn "moOde database not found - configure volume type manually"
        warn "Set Volume type to 'Null (External Control)' in moOde settings"
    fi
}

# Enable and start service
enable_service() {
    info "Enabling rme-volumed service..."

    systemctl enable rme-volumed
    systemctl start rme-volumed

    if systemctl is-active --quiet rme-volumed; then
        info "Service started successfully"
    else
        warn "Service failed to start - check: journalctl -u rme-volumed"
    fi
}

# Show status
show_status() {
    echo ""
    info "Installation complete!"
    echo ""
    echo "MIDI devices:"
    amidi -l || true
    echo ""
    echo "Service status:"
    systemctl status rme-volumed --no-pager || true
    echo ""
    echo "Next steps:"
    echo "1. Edit /etc/rme-volumed.conf if needed"
    echo "2. Set moOde volume type to 'Null (External Control)'"
    echo "3. Restart moOde: sudo systemctl restart mpd"
    echo "4. Test: rme-volume.sh -30"
    echo ""
}

# Main installation
main() {
    echo ""
    echo "==================================="
    echo "RME ADI-2 Volume Control Installer"
    echo "==================================="
    echo ""

    check_root

    case "${1:-all}" in
        deps)
            install_deps
            ;;
        shell)
            install_shell_script
            ;;
        daemon)
            install_daemon
            ;;
        alsa)
            install_alsa_plugin
            ;;
        moode)
            configure_moode
            ;;
        enable)
            enable_service
            ;;
        all)
            install_deps
            install_shell_script
            install_daemon
            # ALSA plugin is optional - uncomment if needed
            # install_alsa_plugin
            configure_moode
            enable_service
            show_status
            ;;
        *)
            echo "Usage: $0 {all|deps|shell|daemon|alsa|moode|enable}"
            echo ""
            echo "  all    - Full installation (recommended)"
            echo "  deps   - Install dependencies only"
            echo "  shell  - Install shell script only"
            echo "  daemon - Install Python daemon only"
            echo "  alsa   - Build and install ALSA plugin"
            echo "  moode  - Configure moOde settings"
            echo "  enable - Enable and start systemd service"
            exit 1
            ;;
    esac
}

main "$@"
