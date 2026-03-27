#!/bin/bash
# ==============================================================================
# setup.sh — Raspberry Pi Birdcam RTSP Stream Setup for Frigate
# ==============================================================================
#
# Turns a Raspberry Pi 3/4/5 with a standard Pi Camera (V1/V2) into a
# dedicated, low-resource RTSP stream optimised for Frigate birdwatching.
#
# Features:
#   - Installs required packages (idempotent)
#   - Enables camera interface via raspi-config
#   - Downloads the latest go2rtc binary (auto-detects arm arch)
#   - Creates go2rtc.yaml with a "birdcam" stream using rpicam-vid
#   - Creates a systemd service for go2rtc (auto-restart, user pi)
#   - Interactive resolution & framerate selector with Pi-model estimates
#   - Adaptive framerate lowering when Wi-Fi signal drops
#   - Home Assistant MQTT discovery (restart / update buttons, watchdog)
#   - Auto-update cron job pulling latest setup.sh from GitHub
#   - Safety checks, backups, coloured output, final instructions
#
# Repository : https://github.com/strhwste/rpi-frigate-cam
# License    : MIT
# ==============================================================================
set -euo pipefail

# ─── Colour helpers ──────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Colour

info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()      { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()     { echo -e "${RED}[ERROR]${NC} $*"; }
header()  { echo -e "\n${BOLD}${CYAN}=== $* ===${NC}\n"; }

# ─── Constants ───────────────────────────────────────────────────────────────
REPO_URL="https://github.com/strhwste/rpi-frigate-cam"
GO2RTC_DIR="/etc/go2rtc"
GO2RTC_BIN="/usr/local/bin/go2rtc"
GO2RTC_YAML="${GO2RTC_DIR}/go2rtc.yaml"
SERVICE_FILE="/etc/systemd/system/go2rtc.service"
# WATCHDOG_SCRIPT is reserved for future per-process watchdog use
# shellcheck disable=SC2034
WATCHDOG_SCRIPT="/usr/local/bin/birdcam-watchdog.sh"
MQTT_DISCOVERY_SCRIPT="/usr/local/bin/birdcam-mqtt-discovery.sh"
WIFI_WATCHDOG_SCRIPT="/usr/local/bin/birdcam-wifi-watchdog.sh"
AUTOUPDATE_SCRIPT="/usr/local/bin/birdcam-autoupdate.sh"
BIRDCAM_CONF="/etc/birdcam.conf"
BACKUP_DIR="/etc/birdcam-backups"
STREAM_NAME="birdcam"
RTSP_PORT="8554"
WEBRTC_PORT="8555"

# ─── Root / sudo check ──────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    err "This script must be run as root (use: sudo bash setup.sh)"
    exit 1
fi
ok "Running as root."

# ─── Detect the non-root user (typically 'pi') ──────────────────────────────
RUN_USER="${SUDO_USER:-pi}"
if ! id -u "${RUN_USER}" &>/dev/null; then
    RUN_USER="pi"
fi
if ! id -u "${RUN_USER}" &>/dev/null; then
    warn "User '${RUN_USER}' does not exist. Service will run as root."
    RUN_USER="root"
fi
info "Service will run as user: ${RUN_USER}"

# ─── Detect Raspberry Pi model ──────────────────────────────────────────────
detect_pi_model() {
    local model_str=""
    if [[ -f /proc/device-tree/model ]]; then
        model_str=$(tr -d '\0' < /proc/device-tree/model)
    elif [[ -f /sys/firmware/devicetree/base/model ]]; then
        model_str=$(tr -d '\0' < /sys/firmware/devicetree/base/model)
    fi

    # Determine Pi generation (3, 4, 5, or unknown)
    if echo "${model_str}" | grep -qi "Pi 5"; then
        echo "5"
    elif echo "${model_str}" | grep -qi "Pi 4"; then
        echo "4"
    elif echo "${model_str}" | grep -qi "Pi 3"; then
        echo "3"
    elif echo "${model_str}" | grep -qi "Pi Zero 2"; then
        echo "3"  # Zero 2 W has similar capability to Pi 3
    else
        echo "unknown"
    fi
}

PI_MODEL=$(detect_pi_model)
info "Detected Raspberry Pi model generation: ${PI_MODEL}"

# ─── Detect architecture ────────────────────────────────────────────────────
ARCH=$(uname -m)
info "Detected architecture: ${ARCH}"

case "${ARCH}" in
    armv7l|armv6l)  GO2RTC_ARCH="arm"    ;;
    aarch64|arm64)  GO2RTC_ARCH="arm64"  ;;
    *)
        err "Unsupported architecture: ${ARCH}"
        exit 1
        ;;
esac

# ─── Backup helper ──────────────────────────────────────────────────────────
backup_file() {
    local file="$1"
    if [[ -f "${file}" ]]; then
        mkdir -p "${BACKUP_DIR}"
        local ts
        ts=$(date +%Y%m%d_%H%M%S)
        cp "${file}" "${BACKUP_DIR}/$(basename "${file}").bak.${ts}"
        info "Backed up ${file} → ${BACKUP_DIR}/$(basename "${file}").bak.${ts}"
    fi
}

# ==============================================================================
# 1. SYSTEM UPDATE & PACKAGE INSTALLATION
# ==============================================================================
header "Step 1: System Update & Package Installation"

REQUIRED_PKGS=(git curl wget jq mosquitto-clients libraspberrypi-bin)

# Check which packages are already installed
PKGS_TO_INSTALL=()
for pkg in "${REQUIRED_PKGS[@]}"; do
    if ! dpkg -l "${pkg}" 2>/dev/null | grep -q '^ii'; then
        PKGS_TO_INSTALL+=("${pkg}")
    fi
done

if [[ ${#PKGS_TO_INSTALL[@]} -gt 0 ]]; then
    info "Updating package lists..."
    apt-get update -qq

    info "Installing missing packages: ${PKGS_TO_INSTALL[*]}"
    apt-get install -y -qq "${PKGS_TO_INSTALL[@]}" || {
        # libraspberrypi-bin may not be available on 64-bit; retry without it
        warn "Some packages failed. Retrying without libraspberrypi-bin..."
        PKGS_TO_INSTALL=("${PKGS_TO_INSTALL[@]/libraspberrypi-bin/}")
        PKGS_TO_INSTALL=("${PKGS_TO_INSTALL[@]}")  # re-compact
        apt-get install -y -qq "${PKGS_TO_INSTALL[@]}"
    }
    ok "Packages installed."
else
    ok "All required packages already installed."
fi

# ==============================================================================
# 2. ENABLE CAMERA INTERFACE
# ==============================================================================
header "Step 2: Enable Camera Interface"

# On Bookworm+ the legacy camera stack is removed. The camera is handled by
# libcamera / rpicam and typically enabled via dtoverlay in /boot/config.txt
# (or /boot/firmware/config.txt on 64-bit Bookworm).
BOOT_CONFIG=""
if [[ -f /boot/firmware/config.txt ]]; then
    BOOT_CONFIG="/boot/firmware/config.txt"
elif [[ -f /boot/config.txt ]]; then
    BOOT_CONFIG="/boot/config.txt"
fi

if [[ -n "${BOOT_CONFIG}" ]]; then
    # Ensure camera_auto_detect=1 is present (Bookworm default)
    if ! grep -q "^camera_auto_detect=1" "${BOOT_CONFIG}"; then
        backup_file "${BOOT_CONFIG}"
        echo "camera_auto_detect=1" >> "${BOOT_CONFIG}"
        ok "Added camera_auto_detect=1 to ${BOOT_CONFIG}"
    else
        ok "camera_auto_detect=1 already set in ${BOOT_CONFIG}."
    fi

    # Ensure gpu_mem is at least 128 MB for hardware encoding
    if grep -q "^gpu_mem=" "${BOOT_CONFIG}"; then
        CURRENT_GPU=$(grep "^gpu_mem=" "${BOOT_CONFIG}" | tail -1 | cut -d= -f2)
        if [[ "${CURRENT_GPU}" -lt 128 ]]; then
            backup_file "${BOOT_CONFIG}"
            sed -i "s/^gpu_mem=.*/gpu_mem=128/" "${BOOT_CONFIG}"
            ok "Updated gpu_mem to 128 MB in ${BOOT_CONFIG}"
        else
            ok "gpu_mem already ${CURRENT_GPU} MB (≥128)."
        fi
    else
        backup_file "${BOOT_CONFIG}"
        echo "gpu_mem=128" >> "${BOOT_CONFIG}"
        ok "Set gpu_mem=128 in ${BOOT_CONFIG}"
    fi
else
    warn "Could not locate boot config.txt — camera may not be enabled."
fi

# Try raspi-config non-interactive enable (best-effort; may not exist)
if command -v raspi-config &>/dev/null; then
    raspi-config nonint do_camera 0 2>/dev/null || true
    ok "raspi-config camera enable attempted."
fi

# ─── Camera detection ───────────────────────────────────────────────────────
CAM_TOOL=""
if command -v rpicam-vid &>/dev/null; then
    CAM_TOOL="rpicam-vid"
elif command -v libcamera-vid &>/dev/null; then
    CAM_TOOL="libcamera-vid"
else
    warn "Neither rpicam-vid nor libcamera-vid found."
    warn "Camera tools should be available after reboot on Bookworm."
    CAM_TOOL="rpicam-vid"  # assume modern OS after reboot
fi
ok "Camera tool selected: ${CAM_TOOL}"

# Quick camera probe (non-fatal — the camera may work after reboot)
if command -v rpicam-hello &>/dev/null; then
    if rpicam-hello --list-cameras 2>&1 | grep -qi "no cameras"; then
        warn "No camera detected. Ensure the ribbon cable is connected and reboot."
    else
        ok "Camera detected via rpicam-hello."
    fi
elif command -v libcamera-hello &>/dev/null; then
    if libcamera-hello --list-cameras 2>&1 | grep -qi "no cameras"; then
        warn "No camera detected. Ensure the ribbon cable is connected and reboot."
    else
        ok "Camera detected via libcamera-hello."
    fi
else
    info "Camera detection tools not available yet — will work after reboot."
fi

# ==============================================================================
# 3. RESOLUTION & FRAMERATE SELECTOR
# ==============================================================================
header "Step 3: Resolution & Framerate Configuration"

# Performance estimates per Pi model
# Format: "WIDTHxHEIGHT  | description"
echo -e "${BOLD}Available resolutions:${NC}"
echo ""
echo "  #   Resolution    Pi 3 estimate        Pi 4 estimate        Pi 5 estimate"
echo "  ─── ───────────── ──────────────────── ──────────────────── ────────────────────"
echo "  1)  640x480       ✅ Excellent          ✅ Excellent          ✅ Excellent"
echo "  2)  1280x720      ✅ Good (≤15fps rec)  ✅ Excellent          ✅ Excellent"
echo "  3)  1920x1080     ⚠️  Marginal (≤10fps) ✅ Good               ✅ Excellent"
echo ""

# Default based on Pi model
case "${PI_MODEL}" in
    3)        DEFAULT_RES=1 ;;
    4)        DEFAULT_RES=2 ;;
    5)        DEFAULT_RES=3 ;;
    *)        DEFAULT_RES=1 ;;
esac

read -r -p "Select resolution [1-3] (default: ${DEFAULT_RES}): " RES_CHOICE
RES_CHOICE="${RES_CHOICE:-${DEFAULT_RES}}"

case "${RES_CHOICE}" in
    1) WIDTH=640;  HEIGHT=480  ;;
    2) WIDTH=1280; HEIGHT=720  ;;
    3) WIDTH=1920; HEIGHT=1080 ;;
    *) warn "Invalid choice, defaulting to 640x480."
       WIDTH=640; HEIGHT=480 ;;
esac

ok "Resolution: ${WIDTH}x${HEIGHT}"

# Framerate selection
echo ""
echo -e "${BOLD}Available framerates:${NC}"
echo ""
echo "  #   FPS   Pi 3 note                    Pi 4 note"
echo "  ─── ───── ──────────────────────────── ────────────────────────"
echo "  1)  10    ✅ Recommended for Pi 3       ✅ Fine"
echo "  2)  15    ✅ Good for 640p on Pi 3      ✅ Fine"
echo "  3)  20    ⚠️  720p may stutter on Pi 3   ✅ Fine"
echo "  4)  30    ⚠️  Only 640p on Pi 3          ✅ Fine"
echo ""

# Default framerate based on model and resolution
if [[ "${PI_MODEL}" == "3" ]]; then
    if [[ ${WIDTH} -ge 1920 ]]; then
        DEFAULT_FPS=1   # 10 fps
    elif [[ ${WIDTH} -ge 1280 ]]; then
        DEFAULT_FPS=2   # 15 fps
    else
        DEFAULT_FPS=2   # 15 fps
    fi
elif [[ "${PI_MODEL}" == "4" ]]; then
    DEFAULT_FPS=3  # 20 fps
else
    DEFAULT_FPS=4  # 30 fps
fi

read -r -p "Select framerate [1-4] (default: ${DEFAULT_FPS}): " FPS_CHOICE
FPS_CHOICE="${FPS_CHOICE:-${DEFAULT_FPS}}"

case "${FPS_CHOICE}" in
    1) FPS=10 ;;
    2) FPS=15 ;;
    3) FPS=20 ;;
    4) FPS=30 ;;
    *) warn "Invalid choice, defaulting to 15 fps."
       FPS=15 ;;
esac

ok "Framerate: ${FPS} fps"

# ─── MQTT / Home Assistant configuration (optional) ─────────────────────────
echo ""
read -r -p "Enable Home Assistant MQTT discovery? [y/N]: " ENABLE_MQTT
ENABLE_MQTT="${ENABLE_MQTT:-n}"

MQTT_HOST=""
MQTT_PORT="1883"
MQTT_USER=""
MQTT_PASS=""
MQTT_TOPIC_PREFIX="homeassistant"

if [[ "${ENABLE_MQTT,,}" == "y" ]]; then
    read -r -p "  MQTT broker host [localhost]: " MQTT_HOST
    MQTT_HOST="${MQTT_HOST:-localhost}"
    read -r -p "  MQTT broker port [1883]: " MQTT_PORT
    MQTT_PORT="${MQTT_PORT:-1883}"
    read -r -p "  MQTT username (blank for none): " MQTT_USER
    if [[ -n "${MQTT_USER}" ]]; then
        read -r -s -p "  MQTT password: " MQTT_PASS
        echo ""
    fi
    read -r -p "  MQTT discovery prefix [homeassistant]: " MQTT_TOPIC_PREFIX
    MQTT_TOPIC_PREFIX="${MQTT_TOPIC_PREFIX:-homeassistant}"
    ok "MQTT configured: ${MQTT_HOST}:${MQTT_PORT}"
fi

# ─── Save configuration for helper scripts ──────────────────────────────────
cat > "${BIRDCAM_CONF}" <<BIRDCAM_EOF
# Birdcam configuration — generated by setup.sh
# $(date)
STREAM_NAME="${STREAM_NAME}"
WIDTH=${WIDTH}
HEIGHT=${HEIGHT}
FPS=${FPS}
CAM_TOOL="${CAM_TOOL}"
RTSP_PORT="${RTSP_PORT}"
PI_MODEL="${PI_MODEL}"
RUN_USER="${RUN_USER}"
MQTT_ENABLED="${ENABLE_MQTT,,}"
MQTT_HOST="${MQTT_HOST}"
MQTT_PORT="${MQTT_PORT}"
MQTT_USER="${MQTT_USER}"
MQTT_PASS="${MQTT_PASS}"
MQTT_TOPIC_PREFIX="${MQTT_TOPIC_PREFIX}"
BIRDCAM_EOF

chmod 600 "${BIRDCAM_CONF}"
ok "Configuration saved to ${BIRDCAM_CONF}"

# ==============================================================================
# 4. DOWNLOAD go2rtc
# ==============================================================================
header "Step 4: Download go2rtc"

install_go2rtc() {
    info "Fetching latest go2rtc release for ${GO2RTC_ARCH}..."

    local latest_url
    latest_url=$(curl -fsSL "https://api.github.com/repos/AlexxIT/go2rtc/releases/latest" \
        | jq -r --arg arch "${GO2RTC_ARCH}" \
          '.assets[] | select(.name == ("go2rtc_linux_" + $arch)) | .browser_download_url')

    if [[ -z "${latest_url}" ]]; then
        err "Could not find go2rtc binary for architecture: ${GO2RTC_ARCH}"
        exit 1
    fi

    info "Downloading: ${latest_url}"
    curl -fsSL -o "${GO2RTC_BIN}" "${latest_url}"
    chmod +x "${GO2RTC_BIN}"
    ok "go2rtc installed at ${GO2RTC_BIN}"
}

if [[ -x "${GO2RTC_BIN}" ]]; then
    INSTALLED_VER=$("${GO2RTC_BIN}" --version 2>/dev/null || echo "unknown")
    info "go2rtc already installed (${INSTALLED_VER}). Checking for update..."

    LATEST_VER=$(curl -fsSL "https://api.github.com/repos/AlexxIT/go2rtc/releases/latest" \
        | jq -r '.tag_name' 2>/dev/null || echo "unknown")

    if [[ "${INSTALLED_VER}" == *"${LATEST_VER}"* ]]; then
        ok "go2rtc is already up to date (${LATEST_VER})."
    else
        info "Updating go2rtc from ${INSTALLED_VER} to ${LATEST_VER}..."
        backup_file "${GO2RTC_BIN}"
        install_go2rtc
    fi
else
    install_go2rtc
fi

# ==============================================================================
# 5. CREATE go2rtc CONFIGURATION
# ==============================================================================
header "Step 5: Create go2rtc Configuration"

mkdir -p "${GO2RTC_DIR}"
backup_file "${GO2RTC_YAML}"

# Build the camera command
# rpicam-vid flags:
#   --codec h264    — hardware H.264 encoder
#   --inline        — produce Annex-B H.264 (SPS/PPS before every IDR)
#   --nopreview     — headless (no display window)
#   --timeout 0     — run indefinitely (0 = infinite)
#   --width / --height / --framerate
#   --listen        — wait for a TCP connection (go2rtc connects to it)
#   -o tcp://...    — output to TCP listener on localhost for go2rtc
#
# For libcamera-vid the flags are identical.
# Using exec source in go2rtc: the tool writes raw h264 to stdout.

CAM_CMD="${CAM_TOOL} --codec h264 --inline --nopreview --timeout 0"
CAM_CMD+=" --width ${WIDTH} --height ${HEIGHT} --framerate ${FPS}"
CAM_CMD+=" --libav-format h264"
CAM_CMD+=" -o -"

cat > "${GO2RTC_YAML}" <<GO2RTC_EOF
# go2rtc configuration for birdcam
# Generated by setup.sh — $(date)
# Repository: ${REPO_URL}

streams:
  ${STREAM_NAME}:
    - exec:${CAM_CMD}

rtsp:
  listen: ":${RTSP_PORT}"

webrtc:
  listen: ":${WEBRTC_PORT}"

api:
  listen: ":1984"

log:
  level: warn
GO2RTC_EOF

chown "${RUN_USER}:${RUN_USER}" "${GO2RTC_YAML}" 2>/dev/null || true
ok "go2rtc config written to ${GO2RTC_YAML}"
info "Stream command: ${CAM_CMD}"

# ==============================================================================
# 6. CREATE SYSTEMD SERVICE
# ==============================================================================
header "Step 6: Create systemd Service"

backup_file "${SERVICE_FILE}"

cat > "${SERVICE_FILE}" <<SERVICE_EOF
[Unit]
Description=go2rtc — Birdcam RTSP stream
Documentation=${REPO_URL}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${RUN_USER}
ExecStart=${GO2RTC_BIN} -config ${GO2RTC_YAML}
Restart=always
RestartSec=5
# Low-priority to keep the Pi responsive
Nice=10
# Limit memory to prevent runaway usage on Pi 3
MemoryMax=150M

# Allow binding to privileged RTSP port if needed
AmbientCapabilities=CAP_NET_BIND_SERVICE

# Security hardening
NoNewPrivileges=true
ProtectSystem=strict
ReadWritePaths=${GO2RTC_DIR}
ProtectHome=true

[Install]
WantedBy=multi-user.target
SERVICE_EOF

ok "systemd service written to ${SERVICE_FILE}"

systemctl daemon-reload
systemctl enable go2rtc.service
ok "go2rtc.service enabled at boot."

# Start (or restart) the service
if systemctl is-active --quiet go2rtc.service; then
    info "Restarting go2rtc service..."
    systemctl restart go2rtc.service
else
    info "Starting go2rtc service..."
    systemctl start go2rtc.service || warn "Service failed to start — may need a reboot first."
fi

# ==============================================================================
# 7. WI-FI ADAPTIVE FRAMERATE WATCHDOG
# ==============================================================================
header "Step 7: Wi-Fi Adaptive Framerate Watchdog"

cat > "${WIFI_WATCHDOG_SCRIPT}" <<'WIFI_EOF'
#!/bin/bash
# birdcam-wifi-watchdog.sh — Lower framerate when Wi-Fi signal drops
# Runs periodically via systemd timer. Reads /etc/birdcam.conf for settings.
set -euo pipefail

CONF="/etc/birdcam.conf"
[[ -f "${CONF}" ]] && source "${CONF}"

# Defaults if not set
FPS="${FPS:-15}"
WIDTH="${WIDTH:-640}"
HEIGHT="${HEIGHT:-480}"
CAM_TOOL="${CAM_TOOL:-rpicam-vid}"
STREAM_NAME="${STREAM_NAME:-birdcam}"

GO2RTC_YAML="/etc/go2rtc/go2rtc.yaml"

# Get Wi-Fi signal quality (0-100)
get_wifi_quality() {
    local quality=100
    if command -v iwconfig &>/dev/null; then
        local link
        link=$(iwconfig 2>/dev/null | grep -i "link quality" | head -1 \
            | sed 's/.*Link Quality=\([0-9]*\)\/\([0-9]*\).*/\1 \2/')
        if [[ -n "${link}" ]]; then
            local num den
            num=$(echo "${link}" | cut -d' ' -f1)
            den=$(echo "${link}" | cut -d' ' -f2)
            if [[ "${den}" -gt 0 ]]; then
                quality=$(( num * 100 / den ))
            fi
        fi
    fi
    echo "${quality}"
}

WIFI_QUALITY=$(get_wifi_quality)
STATE_FILE="/tmp/birdcam_wifi_state"
PREV_STATE="normal"
[[ -f "${STATE_FILE}" ]] && PREV_STATE=$(cat "${STATE_FILE}")

if [[ "${WIFI_QUALITY}" -lt 30 ]]; then
    NEW_STATE="low"
elif [[ "${WIFI_QUALITY}" -lt 60 ]]; then
    NEW_STATE="medium"
else
    NEW_STATE="normal"
fi

# Only restart if state changed
if [[ "${NEW_STATE}" != "${PREV_STATE}" ]]; then
    case "${NEW_STATE}" in
        low)    ADJUSTED_FPS=$(( FPS / 3 )); [[ ${ADJUSTED_FPS} -lt 5 ]] && ADJUSTED_FPS=5 ;;
        medium) ADJUSTED_FPS=$(( FPS * 2 / 3 )); [[ ${ADJUSTED_FPS} -lt 5 ]] && ADJUSTED_FPS=5 ;;
        normal) ADJUSTED_FPS="${FPS}" ;;
    esac

    # Rewrite go2rtc.yaml with adjusted FPS
    CAM_CMD="${CAM_TOOL} --codec h264 --inline --nopreview --timeout 0"
    CAM_CMD+=" --width ${WIDTH} --height ${HEIGHT} --framerate ${ADJUSTED_FPS}"
    CAM_CMD+=" --libav-format h264"
    CAM_CMD+=" -o -"

    cat > "${GO2RTC_YAML}" <<YAML_EOF
streams:
  ${STREAM_NAME}:
    - exec:${CAM_CMD}

rtsp:
  listen: ":8554"

webrtc:
  listen: ":8555"

api:
  listen: ":1984"

log:
  level: warn
YAML_EOF

    systemctl restart go2rtc.service 2>/dev/null || true
    logger -t birdcam-wifi "Wi-Fi quality ${WIFI_QUALITY}% → state ${NEW_STATE}, fps ${ADJUSTED_FPS}"
    echo "${NEW_STATE}" > "${STATE_FILE}"
fi
WIFI_EOF

chmod 700 "${WIFI_WATCHDOG_SCRIPT}"
ok "Wi-Fi watchdog script created at ${WIFI_WATCHDOG_SCRIPT}"

# Create systemd timer for the Wi-Fi watchdog (every 30 seconds)
cat > /etc/systemd/system/birdcam-wifi-watchdog.service <<WDSERVICE_EOF
[Unit]
Description=Birdcam Wi-Fi adaptive framerate watchdog
After=go2rtc.service

[Service]
Type=oneshot
ExecStart=${WIFI_WATCHDOG_SCRIPT}
WDSERVICE_EOF

cat > /etc/systemd/system/birdcam-wifi-watchdog.timer <<WDTIMER_EOF
[Unit]
Description=Run birdcam Wi-Fi watchdog every 30s

[Timer]
OnBootSec=60
OnUnitActiveSec=30

[Install]
WantedBy=timers.target
WDTIMER_EOF

systemctl daemon-reload
systemctl enable --now birdcam-wifi-watchdog.timer 2>/dev/null || true
ok "Wi-Fi watchdog timer enabled (every 30s)."

# ==============================================================================
# 8. HOME ASSISTANT MQTT DISCOVERY
# ==============================================================================
header "Step 8: Home Assistant MQTT Discovery & Watchdog"

cat > "${MQTT_DISCOVERY_SCRIPT}" <<'MQTT_DISC_EOF'
#!/bin/bash
# birdcam-mqtt-discovery.sh — Publishes HA MQTT auto-discovery messages
# and periodically sends system stats (CPU, RAM, temperature).
set -euo pipefail

CONF="/etc/birdcam.conf"
[[ -f "${CONF}" ]] && source "${CONF}"

MQTT_ENABLED="${MQTT_ENABLED:-n}"
[[ "${MQTT_ENABLED}" != "y" ]] && exit 0

MQTT_HOST="${MQTT_HOST:-localhost}"
MQTT_PORT="${MQTT_PORT:-1883}"
MQTT_USER="${MQTT_USER:-}"
MQTT_PASS="${MQTT_PASS:-}"
MQTT_TOPIC_PREFIX="${MQTT_TOPIC_PREFIX:-homeassistant}"

HOSTNAME_SHORT=$(hostname -s)
DEVICE_ID="birdcam_${HOSTNAME_SHORT}"
STATE_TOPIC="birdcam/${HOSTNAME_SHORT}/state"
CMD_TOPIC="birdcam/${HOSTNAME_SHORT}/cmd"
AVAIL_TOPIC="birdcam/${HOSTNAME_SHORT}/availability"

# Build mosquitto_pub auth args
MQTT_AUTH=()
if [[ -n "${MQTT_HOST}" ]]; then
    MQTT_AUTH+=(-h "${MQTT_HOST}" -p "${MQTT_PORT}")
fi
if [[ -n "${MQTT_USER}" ]]; then
    MQTT_AUTH+=(-u "${MQTT_USER}")
fi
if [[ -n "${MQTT_PASS}" ]]; then
    MQTT_AUTH+=(-P "${MQTT_PASS}")
fi

mqtt_pub() {
    mosquitto_pub "${MQTT_AUTH[@]}" -t "$1" -m "$2" -r 2>/dev/null || true
}

# ─── Device JSON shared across all entities ──────────────────────────────────
DEVICE_JSON=$(cat <<DJEOF
{
  "identifiers": ["${DEVICE_ID}"],
  "name": "Birdcam ${HOSTNAME_SHORT}",
  "manufacturer": "Raspberry Pi",
  "model": "Birdcam RTSP",
  "sw_version": "1.0"
}
DJEOF
)

# ─── Publish discovery configs ───────────────────────────────────────────────
publish_discovery() {
    # CPU temperature sensor
    mqtt_pub "${MQTT_TOPIC_PREFIX}/sensor/${DEVICE_ID}/cpu_temp/config" \
        "{\"name\":\"CPU Temperature\",\"unique_id\":\"${DEVICE_ID}_cpu_temp\",\"state_topic\":\"${STATE_TOPIC}\",\"value_template\":\"{{ value_json.cpu_temp }}\",\"unit_of_measurement\":\"°C\",\"device_class\":\"temperature\",\"device\":${DEVICE_JSON}}"

    # CPU usage sensor
    mqtt_pub "${MQTT_TOPIC_PREFIX}/sensor/${DEVICE_ID}/cpu_usage/config" \
        "{\"name\":\"CPU Usage\",\"unique_id\":\"${DEVICE_ID}_cpu_usage\",\"state_topic\":\"${STATE_TOPIC}\",\"value_template\":\"{{ value_json.cpu_usage }}\",\"unit_of_measurement\":\"%\",\"icon\":\"mdi:cpu-64-bit\",\"device\":${DEVICE_JSON}}"

    # RAM usage sensor
    mqtt_pub "${MQTT_TOPIC_PREFIX}/sensor/${DEVICE_ID}/ram_usage/config" \
        "{\"name\":\"RAM Usage\",\"unique_id\":\"${DEVICE_ID}_ram_usage\",\"state_topic\":\"${STATE_TOPIC}\",\"value_template\":\"{{ value_json.ram_usage }}\",\"unit_of_measurement\":\"%\",\"icon\":\"mdi:memory\",\"device\":${DEVICE_JSON}}"

    # Stream status binary sensor
    mqtt_pub "${MQTT_TOPIC_PREFIX}/binary_sensor/${DEVICE_ID}/stream_status/config" \
        "{\"name\":\"Stream Status\",\"unique_id\":\"${DEVICE_ID}_stream\",\"state_topic\":\"${STATE_TOPIC}\",\"value_template\":\"{{ value_json.stream_status }}\",\"payload_on\":\"ON\",\"payload_off\":\"OFF\",\"device_class\":\"running\",\"device\":${DEVICE_JSON}}"

    # Restart button
    mqtt_pub "${MQTT_TOPIC_PREFIX}/button/${DEVICE_ID}/restart/config" \
        "{\"name\":\"Restart Stream\",\"unique_id\":\"${DEVICE_ID}_restart\",\"command_topic\":\"${CMD_TOPIC}\",\"payload_press\":\"restart\",\"icon\":\"mdi:restart\",\"device\":${DEVICE_JSON}}"

    # Update button
    mqtt_pub "${MQTT_TOPIC_PREFIX}/button/${DEVICE_ID}/update/config" \
        "{\"name\":\"Update Birdcam\",\"unique_id\":\"${DEVICE_ID}_update\",\"command_topic\":\"${CMD_TOPIC}\",\"payload_press\":\"update\",\"icon\":\"mdi:update\",\"device\":${DEVICE_JSON}}"

    # Availability
    mqtt_pub "${AVAIL_TOPIC}" "online"
}

# ─── Gather system stats ─────────────────────────────────────────────────────
publish_state() {
    local cpu_temp="0"
    if [[ -f /sys/class/thermal/thermal_zone0/temp ]]; then
        cpu_temp=$(awk '{printf "%.1f", $1/1000}' /sys/class/thermal/thermal_zone0/temp)
    fi

    local cpu_usage
    cpu_usage=$(awk '/^cpu /{u=$2+$4; t=$2+$3+$4+$5+$6+$7+$8; printf "%.1f", u*100/t}' /proc/stat)

    local ram_usage
    ram_usage=$(free | awk '/Mem:/{printf "%.1f", $3/$2*100}')

    local stream_status="OFF"
    if systemctl is-active --quiet go2rtc.service; then
        stream_status="ON"
    fi

    local payload
    payload=$(cat <<PEOF
{"cpu_temp":${cpu_temp},"cpu_usage":${cpu_usage},"ram_usage":${ram_usage},"stream_status":"${stream_status}"}
PEOF
    )
    mqtt_pub "${STATE_TOPIC}" "${payload}"
}

# ─── Listen for commands (restart / update) ───────────────────────────────────
handle_commands() {
    # Subscribe in background; process commands as they arrive
    mosquitto_sub "${MQTT_AUTH[@]}" -t "${CMD_TOPIC}" 2>/dev/null | while read -r cmd; do
        case "${cmd}" in
            restart)
                logger -t birdcam-mqtt "Restart requested via MQTT"
                systemctl restart go2rtc.service 2>/dev/null || true
                ;;
            update)
                logger -t birdcam-mqtt "Update requested via MQTT"
                /usr/local/bin/birdcam-autoupdate.sh 2>/dev/null || true
                ;;
        esac
    done
}

# ─── Main ─────────────────────────────────────────────────────────────────────
publish_discovery

# Start command listener in background
handle_commands &
CMD_PID=$!
trap "kill ${CMD_PID} 2>/dev/null; mqtt_pub '${AVAIL_TOPIC}' 'offline'" EXIT

# Periodically publish state (every 30 seconds)
while true; do
    publish_state
    sleep 30
done
MQTT_DISC_EOF

chmod 700 "${MQTT_DISCOVERY_SCRIPT}"
ok "MQTT discovery script created at ${MQTT_DISCOVERY_SCRIPT}"

# Systemd service for MQTT discovery
cat > /etc/systemd/system/birdcam-mqtt.service <<MQTTSERVICE_EOF
[Unit]
Description=Birdcam MQTT discovery and watchdog
After=network-online.target go2rtc.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=${MQTT_DISCOVERY_SCRIPT}
Restart=always
RestartSec=10
Nice=15

[Install]
WantedBy=multi-user.target
MQTTSERVICE_EOF

systemctl daemon-reload
if [[ "${ENABLE_MQTT,,}" == "y" ]]; then
    systemctl enable --now birdcam-mqtt.service 2>/dev/null || true
    ok "MQTT discovery service enabled and started."
else
    systemctl disable --now birdcam-mqtt.service 2>/dev/null || true
    info "MQTT discovery service disabled (not configured)."
fi

# ==============================================================================
# 9. AUTO-UPDATE FROM REPOSITORY
# ==============================================================================
header "Step 9: Auto-Update from Repository"

cat > "${AUTOUPDATE_SCRIPT}" <<'AUTOUPDATE_EOF'
#!/bin/bash
# birdcam-autoupdate.sh — Pull latest setup.sh from GitHub and re-run if changed
set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/strhwste/rpi-frigate-cam/main"
LOCAL_SCRIPT="/usr/local/bin/birdcam-setup.sh"
SETUP_URL="${REPO_RAW}/setup.sh"

logger -t birdcam-update "Checking for updates..."

# Download latest setup.sh to a temp file
TMP=$(mktemp) || exit 1
chmod 600 "${TMP}"
if curl -fsSL -o "${TMP}" "${SETUP_URL}" 2>/dev/null; then
    if [[ -f "${LOCAL_SCRIPT}" ]]; then
        if ! diff -q "${TMP}" "${LOCAL_SCRIPT}" &>/dev/null; then
            cp "${TMP}" "${LOCAL_SCRIPT}"
            chmod +x "${LOCAL_SCRIPT}"
            logger -t birdcam-update "Updated setup.sh — new version downloaded."
        else
            logger -t birdcam-update "setup.sh is already up to date."
        fi
    else
        cp "${TMP}" "${LOCAL_SCRIPT}"
        chmod +x "${LOCAL_SCRIPT}"
        logger -t birdcam-update "setup.sh installed for the first time."
    fi
    rm -f "${TMP}"
else
    logger -t birdcam-update "Failed to download update (network issue?)."
    rm -f "${TMP}"
fi
AUTOUPDATE_EOF

chmod 700 "${AUTOUPDATE_SCRIPT}"

# Copy current setup.sh as the reference
cp "$0" /usr/local/bin/birdcam-setup.sh 2>/dev/null || true
chmod +x /usr/local/bin/birdcam-setup.sh 2>/dev/null || true

# Create systemd timer for auto-update (daily)
cat > /etc/systemd/system/birdcam-autoupdate.service <<AUSERVICE_EOF
[Unit]
Description=Birdcam auto-update check
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${AUTOUPDATE_SCRIPT}
AUSERVICE_EOF

cat > /etc/systemd/system/birdcam-autoupdate.timer <<AUTIMER_EOF
[Unit]
Description=Daily birdcam auto-update check

[Timer]
OnCalendar=daily
RandomizedDelaySec=3600
Persistent=true

[Install]
WantedBy=timers.target
AUTIMER_EOF

systemctl daemon-reload
systemctl enable --now birdcam-autoupdate.timer 2>/dev/null || true
ok "Auto-update timer enabled (daily check)."

# ==============================================================================
# 10. FINAL INSTRUCTIONS
# ==============================================================================
header "Setup Complete!"

PI_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
PI_IP="${PI_IP:-<PI_IP_ADDRESS>}"

echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║                  🐦 Birdcam Setup Complete! 🐦                  ║${NC}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${BOLD}Stream Details:${NC}"
echo -e "  Resolution : ${WIDTH}x${HEIGHT} @ ${FPS} fps"
echo -e "  Camera tool: ${CAM_TOOL}"
echo -e "  Pi model   : ${PI_MODEL}"
echo ""
echo -e "${BOLD}📺 RTSP URL:${NC}"
echo -e "  ${CYAN}rtsp://${PI_IP}:${RTSP_PORT}/${STREAM_NAME}${NC}"
echo ""
echo -e "${BOLD}🌐 WebRTC (browser):${NC}"
echo -e "  ${CYAN}http://${PI_IP}:1984/${NC}"
echo ""
echo -e "${BOLD}▶ Test with VLC:${NC}"
echo -e "  vlc rtsp://${PI_IP}:${RTSP_PORT}/${STREAM_NAME}"
echo ""
echo -e "${BOLD}📋 Frigate Configuration — Option A (direct RTSP):${NC}"
echo -e "  ${YELLOW}cameras:"
echo -e "    birdcam:"
echo -e "      ffmpeg:"
echo -e "        inputs:"
echo -e "          - path: rtsp://${PI_IP}:${RTSP_PORT}/${STREAM_NAME}"
echo -e "            roles:"
echo -e "              - detect"
echo -e "      detect:"
echo -e "        width: ${WIDTH}"
echo -e "        height: ${HEIGHT}"
echo -e "        fps: 5"
echo -e "      objects:"
echo -e "        track:"
echo -e "          - bird${NC}"
echo ""
echo -e "${BOLD}📋 Frigate Configuration — Option B (via go2rtc restream):${NC}"
echo -e "  ${YELLOW}go2rtc:"
echo -e "    streams:"
echo -e "      birdcam:"
echo -e "        - rtsp://${PI_IP}:${RTSP_PORT}/${STREAM_NAME}"
echo -e ""
echo -e "  cameras:"
echo -e "    birdcam:"
echo -e "      ffmpeg:"
echo -e "        inputs:"
echo -e "          - path: rtsp://127.0.0.1:8554/${STREAM_NAME}"
echo -e "            input_args: preset-rtsp-restream"
echo -e "            roles:"
echo -e "              - detect"
echo -e "      detect:"
echo -e "        width: ${WIDTH}"
echo -e "        height: ${HEIGHT}"
echo -e "        fps: 5"
echo -e "      objects:"
echo -e "        track:"
echo -e "          - bird${NC}"
echo ""
echo -e "${BOLD}🔧 Service Management:${NC}"
echo -e "  Check status : ${CYAN}sudo systemctl status go2rtc${NC}"
echo -e "  View logs    : ${CYAN}sudo journalctl -u go2rtc -f${NC}"
echo -e "  Restart      : ${CYAN}sudo systemctl restart go2rtc${NC}"
echo -e "  Stop         : ${CYAN}sudo systemctl stop go2rtc${NC}"
echo ""

if [[ "${ENABLE_MQTT,,}" == "y" ]]; then
    echo -e "${BOLD}🏠 Home Assistant:${NC}"
    echo -e "  MQTT broker  : ${MQTT_HOST}:${MQTT_PORT}"
    echo -e "  Entities will auto-discover (CPU temp, RAM, stream status)."
    echo -e "  Buttons: Restart Stream, Update Birdcam"
    echo -e "  MQTT logs    : ${CYAN}sudo journalctl -u birdcam-mqtt -f${NC}"
    echo ""
fi

echo -e "${BOLD}🔄 Auto-update:${NC}"
echo -e "  Checks daily for updates from: ${REPO_URL}"
echo -e "  Manual check : ${CYAN}sudo ${AUTOUPDATE_SCRIPT}${NC}"
echo ""
echo -e "${BOLD}📁 Configuration files:${NC}"
echo -e "  go2rtc config  : ${GO2RTC_YAML}"
echo -e "  Birdcam config : ${BIRDCAM_CONF}"
echo -e "  Backups        : ${BACKUP_DIR}/"
echo ""
echo -e "${RED}${BOLD}⚠ IMPORTANT: Please reboot your Raspberry Pi to ensure the"
echo -e "  camera interface is properly enabled:${NC}"
echo -e "  ${CYAN}sudo reboot${NC}"
echo ""
echo -e "${GREEN}After reboot, test the stream with VLC or open the WebRTC UI.${NC}"
