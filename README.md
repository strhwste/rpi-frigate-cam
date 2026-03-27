# 🐦 rpi-frigate-cam

Turn a Raspberry Pi (3/4/5) with **any camera** into a dedicated, low-resource RTSP stream optimised for [Frigate](https://frigate.video/) birdwatching.

## Features

- **One-command setup** — `sudo bash setup.sh` does everything
- **Universal camera support** — Pi Camera V1/V2/HQ/GS, USB webcams, and any V4L2 device
- **Auto-detects camera resolutions** — queries the camera and defaults to the highest available
- **go2rtc** RTSP / WebRTC streaming with hardware H.264 encoding (Pi cameras) or software encoding (USB)
- **Auto-detects** Pi model & architecture (armv7l / arm64)
- **Interactive** resolution & framerate selector — populated from live camera probe; supports custom values
- **Wi-Fi adaptive** — automatically lowers framerate when signal drops
- **Home Assistant MQTT discovery** — CPU temp, RAM, stream status sensors + restart/update buttons
- **Auto-update** — daily cron checks this repo for script updates
- **Systemd managed** — auto-start on boot, restart on failure
- **Idempotent** — safe to re-run; backs up existing config files

## Quick Start

```bash
# Clone the repo
git clone https://github.com/strhwste/rpi-frigate-cam.git
cd rpi-frigate-cam

# Run setup (requires root)
sudo bash setup.sh
```

The script will auto-detect your camera and its supported resolutions, defaulting to the highest available. You can override the selection interactively.

## Requirements

| Component | Details |
|-----------|---------|
| **Board** | Raspberry Pi 3, 4, 5, or Zero 2 W |
| **OS** | Raspberry Pi OS Bookworm (32-bit or 64-bit) or later |
| **Camera** | Pi Camera V1, V2, HQ, GS — **or** any USB / V4L2 webcam |
| **Network** | Wi-Fi or Ethernet connected to same network as Frigate |

## Camera Support

| Camera Type | Detection | Encoding | Notes |
|-------------|-----------|----------|-------|
| Pi Camera V1 (OV5647) | `rpicam-hello` | Hardware H.264 | Max 1080p30 |
| Pi Camera V2 (IMX219) | `rpicam-hello` | Hardware H.264 | Max 1080p30 |
| Pi Camera HQ (IMX477) | `rpicam-hello` | Hardware H.264 | Up to 4056×3040 |
| Pi Camera GS (IMX296) | `rpicam-hello` | Hardware H.264 | 1456×1088 |
| USB webcam (H.264) | `v4l2-ctl` | Copy (no re-encode) | Lowest CPU |
| USB webcam (MJPEG) | `v4l2-ctl` | SW H.264 via ffmpeg | Moderate CPU |
| USB webcam (raw) | `v4l2-ctl` | SW H.264 via ffmpeg | Higher CPU |

## What It Does

1. Installs required packages (`git`, `curl`, `jq`, `mosquitto-clients`, etc.)
2. Enables the camera interface in boot config
3. Downloads the latest [go2rtc](https://github.com/AlexxIT/go2rtc) binary
4. Creates `/etc/go2rtc/go2rtc.yaml` with a `birdcam` stream
5. Creates and enables a `go2rtc.service` systemd unit
6. Sets up a Wi-Fi watchdog that adapts framerate to signal quality
7. Optionally configures Home Assistant MQTT auto-discovery
8. Installs a daily auto-update timer

## After Setup

### Test the stream

```bash
# On the Pi
sudo systemctl status go2rtc

# From another machine
vlc rtsp://<PI_IP>:8554/birdcam

# Or open the WebRTC UI in a browser
http://<PI_IP>:1984/
```

### Add to Frigate (direct RTSP)

```yaml
cameras:
  birdcam:
    ffmpeg:
      inputs:
        - path: rtsp://<PI_IP>:8554/birdcam
          roles:
            - detect
    detect:
      width: 640   # match your chosen resolution
      height: 480
      fps: 5
    objects:
      track:
        - bird
```

### Add to Frigate (via go2rtc restream)

```yaml
go2rtc:
  streams:
    birdcam:
      - rtsp://<PI_IP>:8554/birdcam

cameras:
  birdcam:
    ffmpeg:
      inputs:
        - path: rtsp://127.0.0.1:8554/birdcam
          input_args: preset-rtsp-restream
          roles:
            - detect
    detect:
      width: 640
      height: 480
      fps: 5
    objects:
      track:
        - bird
```

## Service Management

```bash
sudo systemctl status go2rtc           # Check stream status
sudo journalctl -u go2rtc -f           # Live logs
sudo systemctl restart go2rtc          # Restart stream
sudo systemctl stop go2rtc             # Stop stream

# MQTT discovery service
sudo systemctl status birdcam-mqtt
sudo journalctl -u birdcam-mqtt -f

# Wi-Fi watchdog
sudo systemctl status birdcam-wifi-watchdog.timer

# Manual update check
sudo /usr/local/bin/birdcam-autoupdate.sh
```

## Configuration Files

| File | Purpose |
|------|---------|
| `/etc/go2rtc/go2rtc.yaml` | go2rtc stream configuration |
| `/etc/birdcam.conf` | Birdcam settings (resolution, MQTT, etc.) |
| `/etc/birdcam-backups/` | Automatic backups of modified files |

## License

[MIT](LICENSE)
