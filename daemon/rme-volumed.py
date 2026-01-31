#!/usr/bin/env python3
"""
rme-volumed - RME ADI-2 Pro Volume Daemon for moOde

Monitors MPD volume events and translates them to MIDI SysEx commands
for RME ADI-2 Pro/DAC hardware volume control.

Usage:
    rme-volumed.py [options]

Options:
    --midi-port PORT    MIDI port (default: hw:0,0,0)
    --device-id ID      Device ID: 0x71=DAC, 0x72=Pro, 0x73=Pro SE (default: 0x72)
    --output OUTPUT     Output: line or phones (default: line)
    --mpd-host HOST     MPD host (default: localhost)
    --mpd-port PORT     MPD port (default: 6600)
    --min-db DB         Minimum volume in dB (default: -60)
    --max-db DB         Maximum volume in dB (default: 0)
    --config FILE       Config file path
    --verbose           Enable verbose logging
    --daemon            Run as daemon (background)
"""

import argparse
import configparser
import logging
import os
import signal
import subprocess
import sys
import time
from pathlib import Path
from typing import Optional

# Try to import python-mpd2, fall back to socket-based approach
try:
    from mpd import MPDClient
    HAS_MPD_LIB = True
except ImportError:
    HAS_MPD_LIB = False

# Device IDs
DEVICE_IDS = {
    'dac': 0x71,
    'pro': 0x72,
    'pro_se': 0x73,
}

# Output parameters
OUTPUT_PARAMS = {
    'line': 0x1B,
    'phones': 0x4B,
}

# RME Manufacturer ID
RME_MFG_ID = bytes([0x00, 0x20, 0x0D])

# Mute parameter
MUTE_PARAM = 0x61


class RMEVolumeController:
    """Controls RME ADI-2 volume via MIDI SysEx."""

    def __init__(self, midi_port: str, device_id: int, output: str = 'line'):
        self.midi_port = midi_port
        self.device_id = device_id
        self.output_param = OUTPUT_PARAMS.get(output, OUTPUT_PARAMS['line'])
        self.logger = logging.getLogger('rme-volume')
        self._last_volume_db: Optional[float] = None
        self._muted: bool = False

    def db_to_bytes(self, db: float) -> tuple[int, int]:
        """Convert dB to RME volume bytes.

        Formula: value = (dB * 10) + 4096
        Split into two 7-bit MIDI bytes.
        """
        value = int((db * 10) + 4096)

        # Clamp to valid range (-114dB to +6dB)
        value = max(1140, min(4156, value))

        x = (value >> 7) & 0x1F
        y = value & 0x7F

        return x, y

    def bytes_to_db(self, x: int, y: int) -> float:
        """Convert RME volume bytes back to dB."""
        value = (x << 7) | y
        return (value - 4096) / 10.0

    def build_sysex(self, param: int, x: int, y: int) -> bytes:
        """Build SysEx message for volume/mute command."""
        return bytes([
            0xF0,  # SysEx start
            *RME_MFG_ID,
            self.device_id,
            0x02,  # Send command
            param,
            x,
            y,
            0xF7,  # SysEx end
        ])

    def send_sysex(self, sysex: bytes) -> bool:
        """Send SysEx via amidi."""
        hex_str = ' '.join(f'{b:02X}' for b in sysex)
        self.logger.debug(f"Sending SysEx: {hex_str}")

        try:
            result = subprocess.run(
                ['amidi', '-p', self.midi_port, '-S', hex_str],
                capture_output=True,
                text=True,
                timeout=5
            )
            if result.returncode != 0:
                self.logger.error(f"amidi error: {result.stderr}")
                return False
            return True
        except subprocess.TimeoutExpired:
            self.logger.error("amidi timeout")
            return False
        except FileNotFoundError:
            self.logger.error("amidi not found - install alsa-utils")
            return False

    def set_volume_db(self, db: float) -> bool:
        """Set volume in dB."""
        x, y = self.db_to_bytes(db)
        sysex = self.build_sysex(self.output_param, x, y)

        if self.send_sysex(sysex):
            self._last_volume_db = db
            self.logger.info(f"Volume set to {db:.1f} dB")
            return True
        return False

    def set_mute(self, muted: bool) -> bool:
        """Set mute state."""
        sysex = self.build_sysex(MUTE_PARAM, 0x00, 0x01 if muted else 0x00)

        if self.send_sysex(sysex):
            self._muted = muted
            self.logger.info(f"Mute {'enabled' if muted else 'disabled'}")
            return True
        return False

    @property
    def last_volume_db(self) -> Optional[float]:
        return self._last_volume_db

    @property
    def muted(self) -> bool:
        return self._muted


class MPDVolumeMonitor:
    """Monitors MPD volume events and triggers callbacks."""

    def __init__(self, host: str = 'localhost', port: int = 6600):
        self.host = host
        self.port = port
        self.logger = logging.getLogger('mpd-monitor')
        self._running = False
        self._last_volume: Optional[int] = None

    def connect(self) -> bool:
        """Connect to MPD."""
        if HAS_MPD_LIB:
            try:
                self.client = MPDClient()
                self.client.timeout = 10
                self.client.connect(self.host, self.port)
                self.logger.info(f"Connected to MPD at {self.host}:{self.port}")
                return True
            except Exception as e:
                self.logger.error(f"Failed to connect to MPD: {e}")
                return False
        else:
            self.logger.warning("python-mpd2 not installed, using mpc fallback")
            return True

    def disconnect(self):
        """Disconnect from MPD."""
        if HAS_MPD_LIB and hasattr(self, 'client'):
            try:
                self.client.close()
                self.client.disconnect()
            except Exception:
                pass

    def get_volume(self) -> Optional[int]:
        """Get current MPD volume (0-100)."""
        if HAS_MPD_LIB:
            try:
                status = self.client.status()
                vol = status.get('volume')
                if vol is not None:
                    return int(vol)
            except Exception as e:
                self.logger.error(f"Error getting volume: {e}")
        else:
            # Fallback to mpc
            try:
                result = subprocess.run(
                    ['mpc', '-h', self.host, '-p', str(self.port), 'volume'],
                    capture_output=True,
                    text=True,
                    timeout=5
                )
                if result.returncode == 0:
                    # Parse "volume: 50%"
                    output = result.stdout.strip()
                    if 'volume:' in output:
                        vol_str = output.split(':')[1].strip().rstrip('%')
                        return int(vol_str)
            except Exception as e:
                self.logger.error(f"mpc error: {e}")
        return None

    def wait_for_change(self, timeout: float = 60) -> bool:
        """Wait for mixer change event. Returns True if event received."""
        if HAS_MPD_LIB:
            try:
                self.client.timeout = timeout
                changes = self.client.idle('mixer')
                return 'mixer' in changes
            except Exception as e:
                self.logger.error(f"Error waiting for changes: {e}")
                return False
        else:
            # Fallback to mpc idleloop
            try:
                result = subprocess.run(
                    ['mpc', '-h', self.host, '-p', str(self.port),
                     'idle', 'mixer'],
                    capture_output=True,
                    text=True,
                    timeout=timeout
                )
                return result.returncode == 0 and 'mixer' in result.stdout
            except subprocess.TimeoutExpired:
                return False
            except Exception as e:
                self.logger.error(f"mpc idle error: {e}")
                return False

    def run(self, callback):
        """Run the monitor loop, calling callback on volume changes."""
        self._running = True

        while self._running:
            if not self.connect():
                self.logger.info("Reconnecting in 5 seconds...")
                time.sleep(5)
                continue

            # Get initial volume
            current_vol = self.get_volume()
            if current_vol is not None and current_vol != self._last_volume:
                self._last_volume = current_vol
                callback(current_vol)

            # Wait for changes
            while self._running:
                try:
                    if self.wait_for_change(timeout=60):
                        current_vol = self.get_volume()
                        if current_vol is not None and current_vol != self._last_volume:
                            self._last_volume = current_vol
                            callback(current_vol)
                except KeyboardInterrupt:
                    self._running = False
                    break
                except Exception as e:
                    self.logger.error(f"Monitor error: {e}")
                    break

            self.disconnect()

    def stop(self):
        """Stop the monitor loop."""
        self._running = False


class VolumeMapper:
    """Maps MPD volume (0-100) to dB range."""

    def __init__(self, min_db: float = -60.0, max_db: float = 0.0):
        self.min_db = min_db
        self.max_db = max_db

    def pct_to_db(self, pct: int) -> float:
        """Convert percentage (0-100) to dB."""
        if pct <= 0:
            return self.min_db
        if pct >= 100:
            return self.max_db

        # Linear mapping (could be changed to logarithmic)
        db_range = self.max_db - self.min_db
        return self.min_db + (pct / 100.0) * db_range

    def db_to_pct(self, db: float) -> int:
        """Convert dB to percentage (0-100)."""
        db_range = self.max_db - self.min_db
        if db_range == 0:
            return 100
        pct = ((db - self.min_db) / db_range) * 100
        return max(0, min(100, int(pct)))


def load_config(config_path: Optional[str]) -> dict:
    """Load configuration from file."""
    config = {
        'midi_port': 'hw:0,0,0',
        'device_id': 0x72,
        'output': 'line',
        'mpd_host': 'localhost',
        'mpd_port': 6600,
        'min_db': -60.0,
        'max_db': 0.0,
    }

    if config_path and Path(config_path).exists():
        parser = configparser.ConfigParser()
        parser.read(config_path)

        if 'device' in parser:
            dev = parser['device']
            config['midi_port'] = dev.get('midi_port', config['midi_port'])
            if 'device_id' in dev:
                val = dev['device_id']
                if val.startswith('0x'):
                    config['device_id'] = int(val, 16)
                else:
                    config['device_id'] = int(val)
            config['output'] = dev.get('output', config['output'])

        if 'volume' in parser:
            vol = parser['volume']
            config['min_db'] = float(vol.get('min_db', config['min_db']))
            config['max_db'] = float(vol.get('max_db', config['max_db']))

        if 'mpd' in parser:
            mpd = parser['mpd']
            config['mpd_host'] = mpd.get('host', config['mpd_host'])
            config['mpd_port'] = int(mpd.get('port', config['mpd_port']))

    return config


def main():
    parser = argparse.ArgumentParser(
        description='RME ADI-2 Pro Volume Daemon for moOde'
    )
    parser.add_argument('--midi-port', default='hw:0,0,0',
                        help='MIDI port (default: hw:0,0,0)')
    parser.add_argument('--device-id', default='0x72',
                        help='Device ID: 0x71=DAC, 0x72=Pro, 0x73=Pro SE')
    parser.add_argument('--output', choices=['line', 'phones'], default='line',
                        help='Output: line or phones')
    parser.add_argument('--mpd-host', default='localhost',
                        help='MPD host')
    parser.add_argument('--mpd-port', type=int, default=6600,
                        help='MPD port')
    parser.add_argument('--min-db', type=float, default=-60.0,
                        help='Minimum volume in dB')
    parser.add_argument('--max-db', type=float, default=0.0,
                        help='Maximum volume in dB')
    parser.add_argument('--config', help='Config file path')
    parser.add_argument('--verbose', '-v', action='store_true',
                        help='Enable verbose logging')
    parser.add_argument('--daemon', '-d', action='store_true',
                        help='Run as daemon')
    parser.add_argument('--set-volume', type=float, metavar='DB',
                        help='Set volume and exit')
    parser.add_argument('--mute', action='store_true',
                        help='Mute and exit')
    parser.add_argument('--unmute', action='store_true',
                        help='Unmute and exit')

    args = parser.parse_args()

    # Setup logging
    log_level = logging.DEBUG if args.verbose else logging.INFO
    logging.basicConfig(
        level=log_level,
        format='%(asctime)s %(name)s %(levelname)s: %(message)s',
        datefmt='%Y-%m-%d %H:%M:%S'
    )
    logger = logging.getLogger('rme-volumed')

    # Load config
    config = load_config(args.config)

    # Override with command line args
    if args.midi_port != 'hw:0,0,0':
        config['midi_port'] = args.midi_port
    if args.device_id != '0x72':
        if args.device_id.startswith('0x'):
            config['device_id'] = int(args.device_id, 16)
        else:
            config['device_id'] = int(args.device_id)
    if args.output != 'line':
        config['output'] = args.output
    if args.mpd_host != 'localhost':
        config['mpd_host'] = args.mpd_host
    if args.mpd_port != 6600:
        config['mpd_port'] = args.mpd_port
    if args.min_db != -60.0:
        config['min_db'] = args.min_db
    if args.max_db != 0.0:
        config['max_db'] = args.max_db

    # Create controller
    controller = RMEVolumeController(
        midi_port=config['midi_port'],
        device_id=config['device_id'],
        output=config['output']
    )

    # One-shot commands
    if args.set_volume is not None:
        controller.set_volume_db(args.set_volume)
        return 0
    if args.mute:
        controller.set_mute(True)
        return 0
    if args.unmute:
        controller.set_mute(False)
        return 0

    # Create mapper and monitor
    mapper = VolumeMapper(min_db=config['min_db'], max_db=config['max_db'])
    monitor = MPDVolumeMonitor(host=config['mpd_host'], port=config['mpd_port'])

    def on_volume_change(volume_pct: int):
        """Handle MPD volume change."""
        db = mapper.pct_to_db(volume_pct)
        logger.info(f"MPD volume: {volume_pct}% -> {db:.1f} dB")
        controller.set_volume_db(db)

    # Handle signals
    def signal_handler(signum, frame):
        logger.info("Shutting down...")
        monitor.stop()

    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)

    # Run
    logger.info(f"Starting RME ADI-2 volume daemon")
    logger.info(f"  MIDI port: {config['midi_port']}")
    logger.info(f"  Device ID: 0x{config['device_id']:02X}")
    logger.info(f"  Output: {config['output']}")
    logger.info(f"  Volume range: {config['min_db']:.1f} to {config['max_db']:.1f} dB")
    logger.info(f"  MPD: {config['mpd_host']}:{config['mpd_port']}")

    if args.daemon:
        # Fork to background
        if os.fork() > 0:
            sys.exit(0)
        os.setsid()
        if os.fork() > 0:
            sys.exit(0)

        # Redirect stdio
        sys.stdin = open('/dev/null', 'r')
        sys.stdout = open('/dev/null', 'w')
        sys.stderr = open('/dev/null', 'w')

    try:
        monitor.run(on_volume_change)
    except Exception as e:
        logger.error(f"Fatal error: {e}")
        return 1

    return 0


if __name__ == '__main__':
    sys.exit(main())
