# Volumio Plugin Development Research

Research notes for implementing RME ADI-2 volume control on Volumio.

## Volumio Architecture Overview

Volumio is a Node.js-based audio player that uses:
- **MPD** for music playback
- **ALSA** for audio output
- **Socket.IO** for real-time communication
- **Plugin system** for extensibility

### Key Directories

| Path | Purpose |
|------|---------|
| `/volumio/app/` | Core application (read-only) |
| `/data/plugins/` | Installed plugins |
| `/data/configuration/` | Plugin configs |
| `/etc/mpd.conf` | MPD configuration (regenerated) |
| `/etc/asound.conf` | ALSA configuration (regenerated) |

## Plugin System

### Categories

| Category | Use Case |
|----------|----------|
| `audio_interface` | Airplay, UPnP, Bluetooth, DSP |
| `music_service` | Music sources, streaming |
| `system_hardware` | GPIO, peripherals, amplifiers |
| `system_controller` | Networking, storage |
| `user_interface` | REST APIs, integrations |

**Our plugin would be `system_hardware`** - it controls external hardware (ADI-2 volume via MIDI).

### Plugin Structure

```
rme-adi2-volume/
├── index.js           # Main plugin logic (Node.js)
├── install.sh         # Installation script
├── uninstall.sh       # Cleanup script
├── package.json       # Plugin metadata
├── config.json        # Default configuration
├── UIConfig.json      # Settings UI definition
├── i18n/
│   └── strings_en.json
└── node_modules/      # Dependencies
```

### package.json Example

```json
{
  "name": "rme_adi2_volume",
  "version": "1.0.0",
  "description": "Hardware volume control for RME ADI-2 Pro/DAC",
  "main": "index.js",
  "author": "Your Name",
  "license": "MIT",
  "volumio_info": {
    "prettyName": "RME ADI-2 Volume",
    "icon": "fa-volume-up",
    "plugin_type": "system_hardware",
    "architectures": ["armhf", "amd64"],
    "os": ["buster", "bullseye"]
  },
  "dependencies": {
    "midi": "^2.0.0"
  }
}
```

### index.js Lifecycle Methods

```javascript
module.exports = rmeAdi2Volume;

function rmeAdi2Volume(context) {
    this.context = context;
    this.commandRouter = this.context.coreCommand;
    this.logger = this.context.logger;
    this.configManager = this.context.configManager;
}

rmeAdi2Volume.prototype.onVolumioStart = function() {
    // Called when Volumio starts
    // Load configuration
    var configFile = this.commandRouter.pluginManager.getConfigurationFile(
        this.context, 'config.json'
    );
    this.config = new (require('v-conf'))();
    this.config.loadFile(configFile);
    return libQ.resolve();
};

rmeAdi2Volume.prototype.onStart = function() {
    // Called when plugin is enabled
    // Initialize MIDI connection, start monitoring
    return libQ.resolve();
};

rmeAdi2Volume.prototype.onStop = function() {
    // Called when plugin is disabled
    // Clean up MIDI connection
    return libQ.resolve();
};

rmeAdi2Volume.prototype.getConfigurationFiles = function() {
    return ['config.json'];
};
```

## Volume Control in Volumio

### WebSocket API

```javascript
// Set volume (0-100)
socket.emit('volume', 50);

// Increment/decrement
socket.emit('volume', '+');
socket.emit('volume', '-');

// With mute
socket.emit('volume', { volume: 50, mute: false });
```

### REST API

```bash
# Set volume to 50
curl "http://volumio.local/api/v1/commands/?cmd=volume&volume=50"

# Increment
curl "http://volumio.local/api/v1/commands/?cmd=volume&volume=plus"
```

### Command Line

```bash
volumio volume 50      # Set to 50
volumio volume plus    # Increment
volumio volume minus   # Decrement
volumio volume mute    # Mute
```

## Hardware Mixer Configuration

### The Challenge

Volumio regenerates `/etc/mpd.conf` on every audio settings change. Custom mixer controls must be:
1. Detected by Volumio's ALSA controller
2. Properly configured in MPD

### ALSA Controller

The ALSA controller plugin (`/volumio/app/plugins/output/alsa_controller/`) handles:
- Mixer detection via `amixer`
- Writing MPD audio output configuration
- Volume control routing

### MPD Configuration for Hardware Mixer

```ini
audio_output {
    type            "alsa"
    name            "ALSA"
    device          "hw:0,0"
    mixer_type      "hardware"
    mixer_control   "ADI2"
    mixer_device    "hw:0"
    mixer_index     "0"
}
```

## Implementation Strategies for RME ADI-2

### Strategy A: Background Daemon (Like moOde)

Run our C daemon as a systemd service, same as moOde:

```
┌─────────────────────────────────────────────┐
│              Volumio                         │
│  Volume slider → WebSocket → MPD             │
│                    ↓                         │
│              ALSA control "ADI2"             │
└─────────────────────────────────────────────┘
                     ↓
┌─────────────────────────────────────────────┐
│         rme-adi2-ctl daemon                 │
│  Monitors ADI2 control → MIDI SysEx → ADI-2 │
└─────────────────────────────────────────────┘
```

**Pros:**
- Reuses existing C code
- Proven to work

**Cons:**
- Plugin just manages the daemon (start/stop/configure)
- Need to ensure daemon starts before MPD

### Strategy B: Node.js Native Plugin

Implement everything in Node.js using `midi` npm package:

```javascript
const midi = require('midi');

// Create MIDI output
const output = new midi.Output();
output.openPort(0);  // Open first MIDI port

// Send volume SysEx
function setVolume(dB) {
    const raw = Math.round(dB * 10) + 4096;
    const x = (raw >> 7) & 0x1F;
    const y = raw & 0x7F;

    output.sendMessage([
        0xF0, 0x00, 0x20, 0x0D,  // SysEx + RME ID
        0x72,                     // Device ID (Pro)
        0x02,                     // Command
        0x1B,                     // Line out
        x, y,                     // Volume
        0xF7                      // End
    ]);
}
```

**Pros:**
- Pure JavaScript, no compilation
- Direct integration with Volumio events

**Cons:**
- Need to create ALSA control from Node.js (harder)
- Or intercept Volumio volume events directly

### Strategy C: Intercept Volumio Volume Events

Instead of creating an ALSA control, listen to Volumio's volume events:

```javascript
rmeAdi2Volume.prototype.onStart = function() {
    var self = this;

    // Listen to volume changes
    this.commandRouter.addCallback('volumioupdatevolume', function(data) {
        var volume = data.vol;
        var dB = self.volumeToDb(volume);
        self.sendMidiVolume(dB);
    });

    return libQ.resolve();
};
```

**Pros:**
- No ALSA control needed
- Simple event-based architecture

**Cons:**
- Similar to Python daemon approach (software mixer)
- May not be true "hardware" mode in MPD

### Strategy D: Patch ALSA Controller Plugin (Not Recommended)

Modify Volumio's core ALSA controller to recognize ADI2 control.

**Cons:**
- Requires modifying `/volumio/` (forbidden)
- Breaks on updates

## Recommended Approach

**Strategy A + B Hybrid:**

1. Use our existing C daemon (`rme-adi2-ctl`) for ALSA control creation and MIDI
2. Create a Volumio plugin that:
   - Installs and manages the C daemon
   - Provides UI configuration (device ID, output, dB range)
   - Configures MPD for hardware mixer mode

### Plugin install.sh

```bash
#!/bin/bash

echo "Installing RME ADI-2 Volume Control"

# Install build dependencies
apt-get update
apt-get install -y build-essential libasound2-dev

# Build the daemon
cd /data/plugins/system_hardware/rme_adi2_volume
make -C alsa-plugin

# Install binary
install -m 755 alsa-plugin/rme-adi2-ctl /usr/local/bin/

# Install systemd service
cp systemd/rme-adi2-ctl.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable rme-adi2-ctl

echo "plugininstallend"
```

### Plugin index.js (Key Parts)

```javascript
rmeAdi2Volume.prototype.onStart = function() {
    var self = this;

    // Start the daemon
    return self.startDaemon()
        .then(function() {
            // Configure MPD for hardware mixer
            return self.configureMpdMixer();
        });
};

rmeAdi2Volume.prototype.startDaemon = function() {
    var defer = libQ.defer();

    exec('systemctl start rme-adi2-ctl', function(err) {
        if (err) {
            self.logger.error('Failed to start daemon: ' + err);
            defer.reject(err);
        } else {
            defer.resolve();
        }
    });

    return defer.promise;
};

rmeAdi2Volume.prototype.configureMpdMixer = function() {
    // This is the tricky part - need to tell Volumio to use
    // hardware mixer with our ADI2 control

    // Option 1: Set via Volumio's config API
    this.commandRouter.executeOnPlugin('audio_interface', 'alsa_controller',
        'setConfigParam', { key: 'mixer', value: 'ADI2' });

    // Option 2: Direct config modification
    // (may not persist)
};
```

## Open Questions

1. **How to make Volumio detect ADI2 as valid mixer?**
   - Volumio's ALSA controller enumerates mixers via `amixer`
   - Our control should appear if daemon is running
   - May need to restart ALSA controller after daemon starts

2. **How to configure MPD mixer_control persistently?**
   - Volumio regenerates mpd.conf on settings change
   - May need to hook into ALSA controller plugin
   - Or provide custom audio output configuration

3. **Plugin installation order vs daemon startup?**
   - Daemon needs to create ALSA control before Volumio enumerates
   - May need to restart Volumio after plugin install

## Resources

- [Plugin System Overview](https://developers.volumio.com/plugins/plugins-overview)
- [Plugin Structure](https://developers.volumio.com/plugins/plugin-structure)
- [Writing a Plugin](https://developers.volumio.com/plugins/writing-a-plugin)
- [WebSocket API](https://github.com/volumio/Volumio2/wiki/WebSockets-API-Reference)
- [volumio-plugins-sources](https://github.com/volumio/volumio-plugins-sources)
- [GPIO Buttons Plugin](https://github.com/volumio/volumio-plugins-sources/tree/master/gpio-buttons) (good reference)

## Next Steps

1. Flash Volumio to RPi
2. SSH in and explore:
   - `/volumio/app/plugins/output/alsa_controller/index.js`
   - How mixer controls are enumerated
   - How MPD config is generated
3. Test manually:
   - Install our C daemon
   - Check if ADI2 appears in mixer selection
   - Configure MPD manually and test
4. Create plugin scaffold:
   - `volumio plugin init`
   - Implement install.sh
   - Implement basic index.js
5. Iterate on integration
