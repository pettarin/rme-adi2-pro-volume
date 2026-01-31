# RME ADI-2 Volume Control for Linux

Hardware volume control for RME ADI-2 Pro/DAC series on Linux audio systems.

## Problem

The RME ADI-2 Pro (and other ADI-2 series devices) does not expose standard ALSA mixer controls over USB. This means audio players like moOde, Volumio, or MPD cannot control the hardware volume directly.

## Solution

This project provides two approaches to enable hardware volume control:

| Approach | Audio Quality | Complexity | Use Case |
|----------|---------------|------------|----------|
| **Option A: C Daemon** | Bit-perfect | Requires compilation | Recommended |
| **Option B: Python Daemon** | Double attenuation | Simpler setup | Fallback |

### Option A: C Daemon (Recommended)

Creates a fake ALSA mixer control that MPD can use with `mixer_type=hardware`. Volume changes are sent to the ADI-2 via MIDI SysEx. Audio passes through unchanged.

```
moOde UI / UPnP App
        |
        v
  MPD (Hardware mode)  ------>  Audio Stream (untouched, bit-perfect)
        |                              |
        | writes to ADI2 control       v
        v                         ADI-2 Pro
   rme-adi2-ctl  ---- MIDI SysEx --->  (hardware volume)
```

### Option B: Python Daemon

Monitors MPD volume events and sends MIDI commands. Requires `mixer_type=software`, which means audio is attenuated twice (MPD software + ADI-2 hardware).

```
moOde UI / UPnP App
        |
        v
  MPD (Software mode)  ------>  Audio Stream (software attenuated)
        |                              |
        | volume events                v
        v                         ADI-2 Pro
   rme-volumed  ---- MIDI SysEx --->  (hardware volume)
```

## Compatibility

Works on any Linux system with ALSA:
- moOde Audio Player
- Volumio
- piCorePlayer
- Raspberry Pi OS
- Desktop Linux (Ubuntu, Fedora, Arch, etc.)

Supported devices:
- ADI-2 DAC / DAC FS (device ID: `0x71`)
- ADI-2 Pro / Pro AE (device ID: `0x72`)
- ADI-2/4 Pro SE (device ID: `0x73`)

## RME ADI-2 MIDI Protocol

RME ADI-2 devices use MIDI SysEx messages for remote control. The protocol is documented at [rme-audio.de/downloads](https://rme-audio.de/downloads.html).

### SysEx Message Format

```
F0 00 20 0D [device_id] [command] [param] [data...] F7
```

| Byte | Description |
|------|-------------|
| `F0` | SysEx start |
| `00 20 0D` | RME manufacturer ID |
| `device_id` | `0x71`=DAC, `0x72`=Pro, `0x73`=Pro SE |
| `command` | `02` = set value, `03` = query |
| `param` | Parameter to control |
| `data` | Value bytes |
| `F7` | SysEx end |

### Volume Parameters

| Parameter | Code | Description |
|-----------|------|-------------|
| Line Out 1/2 | `0x1B` | Main line output volume |
| Phones 3/4 | `0x4B` | Headphone output volume |
| Mute | `0x61` | Mute control |

### Volume Encoding

Volume is encoded as two 7-bit MIDI bytes (X, Y):

```
raw_value = (dB * 10) + 4096
X = (raw_value >> 7) & 0x1F
Y = raw_value & 0x7F
```

Valid range: -114 dB to +6 dB

### Example Commands

```bash
# Set Line Out to -30 dB on ADI-2 Pro
# raw = (-30 * 10) + 4096 = 3796 -> X=0x1D, Y=0x54
amidi -p hw:0,0,0 -S "F0 00 20 0D 72 02 1B 1D 54 F7"

# Mute
amidi -p hw:0,0,0 -S "F0 00 20 0D 72 02 61 00 01 F7"

# Unmute
amidi -p hw:0,0,0 -S "F0 00 20 0D 72 02 61 00 00 F7"
```

---

## Installation

### Prerequisites

- RME ADI-2 Pro, Pro AE, DAC, or DAC FS connected via USB
- SSH access to your Linux device

First, verify MIDI access:

```bash
amidi -l

# Expected output:
# Dir Device    Name
# IO  hw:0,0,0  ADI-2 Pro (xxxxxxxx) Port 1
```

---

## Option A: C Daemon (Bit-Perfect)

### Quick Install (moOde)

```bash
# On your computer
git clone https://github.com/JendaT/moOde-adi-2-pro-volume-control.git
scp -r moOde-adi-2-pro-volume-control your-moode-device:~/

# SSH to device and install
ssh your-moode-device
cd ~/moOde-adi-2-pro-volume-control
sudo ./scripts/install-c-daemon.sh
```

For ADI-2 DAC or different output:

```bash
sudo ./scripts/install-c-daemon.sh --device-id 0x71 --output phones
```

### Manual Build and Install

```bash
# Install build dependencies
sudo apt-get install build-essential libasound2-dev pkg-config

# Build
cd alsa-plugin
make

# Install
sudo make install
sudo cp ../systemd/rme-adi2-ctl.service /etc/systemd/system/

# Configure moOde for hardware mixer
sudo sqlite3 /var/local/www/db/moode-sqlite3.db \
    "UPDATE cfg_mpd SET value='hardware' WHERE param='mixer_type';"
sudo sqlite3 /var/local/www/db/moode-sqlite3.db \
    "UPDATE cfg_mpd SET value='ADI2' WHERE param='mixer_control';"

# Enable and start
sudo systemctl daemon-reload
sudo systemctl enable --now rme-adi2-ctl
sudo systemctl restart mpd
```

### Verify

```bash
# Check service status
sudo systemctl status rme-adi2-ctl

# Verify control exists
amixer sget ADI2

# Test volume
amixer sset ADI2 300  # Sets -30 dB
```

### Configuration Options

Edit `/etc/systemd/system/rme-adi2-ctl.service`:

```ini
ExecStart=/usr/local/bin/rme-adi2-ctl --card ADI-2 --device 0x72 --output line
```

Options:
- `--card NAME` - Sound card name to search for (default: ADI-2)
- `--device ID` - RME device ID: 0x71=DAC, 0x72=Pro, 0x73=Pro SE
- `--output TYPE` - Output: line or phones
- `--verbose` - Enable debug logging

---

## Option B: Python Daemon (Fallback)

Use this if you can't compile the C daemon or prefer simpler setup.

### Quick Install (moOde)

```bash
# On your computer
git clone https://github.com/JendaT/moOde-adi-2-pro-volume-control.git
scp -r moOde-adi-2-pro-volume-control your-moode-device:~/

# SSH to device and install
ssh your-moode-device
cd ~/moOde-adi-2-pro-volume-control

sudo cp daemon/rme-volumed.py /usr/local/bin/
sudo chmod +x /usr/local/bin/rme-volumed.py
sudo cp daemon/rme-volumed.conf /etc/
sudo cp systemd/rme-volumed.service /etc/systemd/system/

# Set software volume mode (required)
sudo sqlite3 /var/local/www/db/moode-sqlite3.db \
    "UPDATE cfg_mpd SET value='software' WHERE param='mixer_type';"

sudo systemctl daemon-reload
sudo systemctl enable --now rme-volumed
sudo systemctl restart mpd
```

### Detailed Install

#### 1. Test Shell Script

```bash
chmod +x scripts/rme-volume.sh
./scripts/rme-volume.sh -30    # Should change ADI-2 to -30 dB
./scripts/rme-volume.sh -20    # Should change ADI-2 to -20 dB
```

#### 2. Install and Test Daemon

```bash
sudo cp daemon/rme-volumed.py /usr/local/bin/
sudo chmod +x /usr/local/bin/rme-volumed.py
sudo cp daemon/rme-volumed.conf /etc/

# Edit config if needed
sudo nano /etc/rme-volumed.conf

# Test manually (Ctrl+C to stop)
python3 /usr/local/bin/rme-volumed.py --config /etc/rme-volumed.conf --verbose
```

#### 3. Enable Service

```bash
sudo sqlite3 /var/local/www/db/moode-sqlite3.db \
    "UPDATE cfg_mpd SET value='software' WHERE param='mixer_type';"

sudo cp systemd/rme-volumed.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now rme-volumed
sudo systemctl restart mpd
```

### Configuration

`/etc/rme-volumed.conf`:

```ini
[device]
midi_port = hw:0,0,0    # MIDI port from 'amidi -l'
device_id = 0x72        # 0x71=DAC, 0x72=Pro, 0x73=Pro SE
output = line           # line or phones

[volume]
min_db = -60.0          # MPD 0% maps to this
max_db = 0.0            # MPD 100% maps to this

[mpd]
host = localhost
port = 6600
```

---

## Troubleshooting

### MIDI port not found

```bash
# Check USB connection
lsusb | grep -i rme

# Check kernel messages
dmesg | grep -i rme

# Verify MIDI devices
amidi -l
```

### Service not starting

```bash
# Check logs
sudo journalctl -u rme-adi2-ctl -f   # C daemon
sudo journalctl -u rme-volumed -f    # Python daemon

# Test manually
/usr/local/bin/rme-adi2-ctl --verbose
python3 /usr/local/bin/rme-volumed.py --verbose
```

### Volume not changing on ADI-2

```bash
# Test direct MIDI command
amidi -p hw:0,0,0 -S "F0 00 20 0D 72 02 1B 1D 54 F7"

# Verify device ID matches your model
```

### Volume control greyed out in moOde

Check the mixer configuration:

```bash
sqlite3 /var/local/www/db/moode-sqlite3.db \
    "SELECT param, value FROM cfg_mpd WHERE param LIKE 'mixer%';"
```

For C daemon: should show `mixer_type=hardware`, `mixer_control=ADI2`
For Python daemon: should show `mixer_type=software`

---

## Files

```
.
├── alsa-plugin/
│   ├── rme-adi2-ctl.c      # C daemon source
│   ├── Makefile            # Build with make
│   └── CMakeLists.txt      # Build with CMake (CLion)
├── daemon/
│   ├── rme-volumed.py      # Python daemon
│   └── rme-volumed.conf    # Python daemon config
├── scripts/
│   ├── install-c-daemon.sh # C daemon installer
│   ├── install.sh          # Python daemon installer
│   └── rme-volume.sh       # Manual volume control
├── systemd/
│   ├── rme-adi2-ctl.service   # C daemon service
│   └── rme-volumed.service    # Python daemon service
└── README.md
```

## References

- [RME ADI-2 MIDI Protocol Documentation](https://rme-audio.de/downloads.html)
- [moOde Audio Player](https://moodeaudio.org/)
- [RMEdiy - Network Control for ADI-2](https://github.com/n00bmax/RMEdiy)
- [RME Forum - MIDI Protocol Discussion](https://forum.rme-audio.de/viewtopic.php?id=38970)

## License

MIT License - See [LICENSE](LICENSE) file
