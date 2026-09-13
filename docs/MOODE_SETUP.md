# RME ADI-2 Volume Control for moOde Audio Player

This guide documents the complete setup for hardware volume control of RME ADI-2 Pro/DAC on moOde audio player with **bit-perfect audio**.

## How It Works

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

1. Our daemon creates a fake ALSA mixer control called "ADI2" on the RME sound card
2. moOde/MPD uses this control for hardware volume (no software attenuation)
3. When the control changes, our daemon sends MIDI SysEx to the ADI-2 hardware
4. Audio passes through completely unchanged (bit-perfect)

## Prerequisites

- moOde audio player (tested on moOde 9.x)
- RME ADI-2 Pro, Pro AE, DAC, or DAC FS connected via USB
- SSH access to your moOde device

## Installation

### Step 1: Copy Files to moOde

On your computer:

```bash
git clone https://github.com/JendaT/rme-adi-2-pro-volume.git
scp -r rme-adi-2-pro-volume your-moode-device:~/rme-adi2-moode
```

### Step 2: Verify MIDI Access

SSH into your moOde device:

```bash
ssh your-moode-device
amidi -l
```

Expected output:
```
Dir Device    Name
IO  hw:X,0,0  ADI-2 Pro (xxxxxxxx) Port 1
```

Note the card number (X) - you'll need it if it's not 0.

### Step 3: Patch moOde Detection

moOde's mixer detection looks for `pvolume` capability, but our user control has `volume`. Apply this one-line patch:

```bash
sudo sed -i 's/\$0 ~ "pvolume"/$0 ~ "p?volume"/' /var/www/util/sysutil.sh
```

Verify the patch:
```bash
grep "volume" /var/www/util/sysutil.sh | head -3
```

Should show `p?volume` instead of `pvolume`.

### Step 4: Build and Install the Daemon

```bash
cd ~/rme-adi2-moode

# Install using the script (recommended)
sudo ./scripts/install-c-daemon.sh --max-db -15

# Or for ADI-2 DAC (not Pro):
sudo ./scripts/install-c-daemon.sh --device-id 0x71 --max-db -15
```

**Installation options:**

| Option | Description | Default |
|--------|-------------|---------|
| `--device-id ID` | `0x71`=DAC, `0x72`=Pro, `0x73`=Pro SE | `0x72` |
| `--output TYPE` | `line` or `phones` | `line` |
| `--min-db DB` | Volume at 0% | `-60` |
| `--max-db DB` | Volume at 100% | `-15` |
| `--no-moode` | Skip moOde database config | |
| `--uninstall` | Remove installation | |

### Step 5: Reboot

```bash
sudo reboot
```

The reboot is required for moOde to:
1. Detect the new ADI2 mixer control
2. Configure MPD with hardware mixer mode

### Step 6: Verify

After reboot, check everything is working:

```bash
# Daemon running?
systemctl status rme-adi2-ctl

# ADI2 control exists?
amixer -c 0 scontrols | grep ADI2

# moOde detected it?
sqlite3 /var/local/www/db/moode-sqlite3.db "SELECT value FROM cfg_system WHERE param='amixname';"
# Should show: ADI2

# MPD config correct?
grep -E "mixer_type|mixer_control" /etc/mpd.conf
# Should show: mixer_type "hardware" and mixer_control "ADI2"
```

Test volume control:
```bash
mpc volume 50
# Watch daemon log:
journalctl -u rme-adi2-ctl -f
```

## Configuration

### Understanding Volume Mapping

The daemon uses **linear mapping** from moOde's 0-100% to the configured dB range:

| moOde % | Default dB | Calculation |
|---------|------------|-------------|
| 0% | -70 dB | min_db |
| 25% | -56.25 dB | -70 + 0.25 × 55 |
| 50% | -42.5 dB | -70 + 0.50 × 55 |
| 75% | -28.75 dB | -70 + 0.75 × 55 |
| 100% | -15 dB | max_db |

This gives intuitive control where 50% is exactly halfway between your configured minimum and maximum.

### Adjusting Volume Range

The defaults are `--min-db -70` and `--max-db -15`. To change:

1. Edit the service file:
```bash
sudo nano /etc/systemd/system/rme-adi2-ctl.service
```

2. Modify the `ExecStart` line:
```ini
ExecStart=/usr/local/bin/rme-adi2-ctl --card ADI-2 --device 0x72 --output line --max-db -10
```

3. Reload and restart:
```bash
sudo systemctl daemon-reload
sudo systemctl restart rme-adi2-ctl
```

### Volume Range Examples

| Setting | 0% | 50% | 100% | Use Case |
|---------|-----|-----|------|----------|
| Default | -70 dB | -42.5 dB | -15 dB | Safe default |
| `--max-db -10` | -70 dB | -40 dB | -10 dB | More headroom |
| `--min-db -60 --max-db -20` | -60 dB | -40 dB | -20 dB | Narrow range |
| `--min-db -50 --max-db -10` | -50 dB | -30 dB | -10 dB | Louder setup |

## Troubleshooting

### Volume control greyed out in moOde UI

Check if moOde detected the mixer:
```bash
sqlite3 /var/local/www/db/moode-sqlite3.db "SELECT param, value FROM cfg_system WHERE param IN ('amixname', 'alsavolume');"
```

If `amixname` is `none`, the detection failed. Verify:
1. The daemon is running: `systemctl status rme-adi2-ctl`
2. The control exists: `amixer -c 0 scontrols | grep ADI2`
3. The sysutil.sh patch was applied correctly
4. Try rebooting again

### ADI2 control not found

```bash
# Check which card the ADI-2 is on
cat /proc/asound/cards

# Verify daemon is using correct card
journalctl -u rme-adi2-ctl | grep "Using card"
```

If cards changed order after reboot, the daemon auto-detects by name ("ADI-2").

### Volume not changing on ADI-2 hardware

Test MIDI directly:
```bash
# Set to -30dB manually
amidi -p hw:0,0,0 -S "F0 00 20 0D 72 02 1B 1D 54 F7"
```

If this works but the daemon doesn't, check:
```bash
journalctl -u rme-adi2-ctl -f
# Then change volume in moOde UI
```

### Permission denied when writing to control

This was fixed by unlocking the control after creation. If you see this error, rebuild from latest source:
```bash
cd ~/rme-adi2-moode/alsa-plugin
git pull
make clean && make
sudo make install
sudo systemctl restart rme-adi2-ctl
```

## Uninstall

```bash
cd ~/rme-adi2-moode
sudo ./scripts/install-c-daemon.sh --uninstall

# Revert sysutil.sh patch (optional)
sudo sed -i 's/\$0 ~ "p?volume"/$0 ~ "pvolume"/' /var/www/util/sysutil.sh

# Reboot to restore default moOde behavior
sudo reboot
```

## Technical Details

### Files Installed

| File | Purpose |
|------|---------|
| `/usr/local/bin/rme-adi2-ctl` | Main daemon binary |
| `/etc/systemd/system/rme-adi2-ctl.service` | Systemd service |
| `/var/www/util/sysutil.sh` | Patched for detection |

### moOde Database Changes

The installer sets these values:
```sql
UPDATE cfg_mpd SET value='hardware' WHERE param='mixer_type';
UPDATE cfg_system SET value='ADI2' WHERE param='amixname';
```

### ALSA Control Details

The daemon creates a user control with:
- Name: `ADI2`
- Type: Integer
- Range: 0-600 (representing -60.0 to 0.0 dB in 0.1 dB steps)
- TLV: dB scale for proper display in ALSA tools

### MIDI SysEx Format

```
F0 00 20 0D [device_id] 02 [param] [X] [Y] F7
```

- Device IDs: `0x71`=DAC, `0x72`=Pro, `0x73`=Pro SE
- Param: `0x1B`=Line Out, `0x4B`=Phones
- Volume encoding: `raw = (dB * 10) + 4096`, `X = (raw >> 7) & 0x1F`, `Y = raw & 0x7F`

## Notes

- The sysutil.sh patch will be overwritten by moOde updates - reapply after updating
- Card numbers may change on reboot depending on USB enumeration order
- The daemon auto-detects the card by name ("ADI-2") so this is usually not a problem
