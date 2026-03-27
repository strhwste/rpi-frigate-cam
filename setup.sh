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
#   - Creates go2rtc.yaml with main + sub streams (multi-stream for Frigate)
#   - WebRTC with STUN ICE candidates for improved connectivity
#   - Creates a systemd service for go2rtc (auto-restart, user pi)
#   - Interactive resolution & framerate selector with Pi-model estimates
#   - Sub-stream for detection (low-res via go2rtc ffmpeg transcoding)
#   - Adaptive framerate lowering when Wi-Fi signal drops
#   - Home Assistant MQTT discovery (restart / update buttons, watchdog)
#   - Auto-update cron job pulling latest setup.sh from GitHub
#   - Frigate integration examples (standalone, restream, bundled go2rtc)
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
DEFAULT_SUB_WIDTH=640
DEFAULT_SUB_HEIGHT=480
DEFAULT_SUB_FPS=5

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

REQUIRED_PKGS=(git curl wget jq ffmpeg mosquitto-clients v4l-utils)
# libraspberrypi-bin provides vcgencmd etc. but is not available on 64-bit
# Bookworm (conflicts with held packages); treat it as optional.
OPTIONAL_PKGS=(libraspberrypi-bin)

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
    apt-get install -y -qq "${PKGS_TO_INSTALL[@]}"
    ok "Packages installed."
else
    ok "All required packages already installed."
fi

# Install optional packages individually so a failure does not break the rest
for pkg in "${OPTIONAL_PKGS[@]}"; do
    if ! dpkg -l "${pkg}" 2>/dev/null | grep -q '^ii'; then
        info "Installing optional package: ${pkg}"
        apt-get install -y -qq "${pkg}" 2>/dev/null \
            || warn "Optional package ${pkg} could not be installed (skipping)."
    fi
done

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

# ─── Camera detection helpers ───────────────────────────────────────────────

# Sort "WxH" resolution strings by total pixel count, highest first
sort_resolutions_by_pixels() {
    while IFS= read -r res; do
        [[ -z "${res}" ]] && continue
        local w h
        w=$(echo "${res}" | cut -d'x' -f1)
        h=$(echo "${res}" | cut -d'x' -f2)
        printf '%010d %s\n' "$((w * h))" "${res}"
    done | sort -rn | awk '{print $2}'
}

# Probe Pi camera (rpicam-hello); outputs detected resolutions
probe_pi_camera() {
    local probe_cmd=""
    if command -v rpicam-hello &>/dev/null; then
        probe_cmd="rpicam-hello"
    elif command -v libcamera-hello &>/dev/null; then
        warn "libcamera-hello is deprecated; consider installing rpicam-apps"
        probe_cmd="libcamera-hello"
    else
        return 1
    fi
    local cam_list
    cam_list=$("${probe_cmd}" --list-cameras 2>&1 || true)
    if echo "${cam_list}" | grep -qiE "no cameras|Unable to start"; then
        return 1
    fi
    if ! echo "${cam_list}" | grep -qiE "[0-9]{3,}x[0-9]{3,}|imx|ov5647"; then
        return 1
    fi
    # Match WxH but exclude crop dimensions (preceded by '/')
    echo "${cam_list}" | grep -oP '(?<!/)[0-9]{3,}x[0-9]{3,}' | sort_resolutions_by_pixels | uniq
}

# List USB video capture devices
probe_usb_cameras() {
    for dev in /dev/video*; do
        [[ -e "${dev}" ]] || continue
        if command -v v4l2-ctl &>/dev/null; then
            if v4l2-ctl -d "${dev}" --info 2>/dev/null | grep -q "Video Capture"; then
                echo "${dev}"
            fi
        else
            echo "${dev}"
        fi
    done
}

# Get resolutions supported by a USB camera device
get_usb_resolutions() {
    local device="$1"
    if command -v v4l2-ctl &>/dev/null; then
        v4l2-ctl -d "${device}" --list-formats-ext 2>/dev/null \
            | grep -oP '[0-9]{3,}x[0-9]{3,}' | sort_resolutions_by_pixels | uniq || true
    fi
}

# ─── Detect camera and populate global vars ──────────────────────────────────
# CAM_TYPE    : "pi" | "usb"
# CAM_TOOL    : rpicam-vid  (Pi only; libcamera-vid is deprecated)
# CAM_DEVICE  : /dev/videoN                 (USB only)
# DETECTED_RESOLUTIONS : array of WxH strings, highest first
CAM_TYPE="pi"
CAM_TOOL=""
CAM_DEVICE=""
DETECTED_RESOLUTIONS=()

# Always resolve the Pi camera tool binary
if command -v rpicam-vid &>/dev/null; then
    CAM_TOOL="rpicam-vid"
elif command -v libcamera-vid &>/dev/null; then
    warn "libcamera-vid is deprecated; consider installing rpicam-apps"
    CAM_TOOL="libcamera-vid"
else
    CAM_TOOL="rpicam-vid"  # assume available after reboot
fi

# Attempt Pi camera probe
pi_res=$(probe_pi_camera 2>/dev/null || true)

# Attempt USB camera probe
usb_dev_list=$(probe_usb_cameras 2>/dev/null || true)

if [[ -n "${pi_res}" ]]; then
    CAM_TYPE="pi"
    while IFS= read -r r; do
        [[ -n "${r}" ]] && DETECTED_RESOLUTIONS+=("${r}")
    done <<< "${pi_res}"
    ok "Pi camera detected. ${#DETECTED_RESOLUTIONS[@]} resolution mode(s) found."
    if [[ -n "${usb_dev_list}" ]]; then
        info "USB camera(s) also present. Using Pi camera (run setup again to switch)."
    fi
elif [[ -n "${usb_dev_list}" ]]; then
    CAM_TYPE="usb"
    CAM_DEVICE=$(echo "${usb_dev_list}" | head -1)

    # Let user pick if multiple USB cameras are present
    usb_count=$(echo "${usb_dev_list}" | wc -l)
    if [[ "${usb_count}" -gt 1 ]]; then
        echo -e "${BOLD}Multiple USB cameras detected:${NC}"
        i=1
        while IFS= read -r dev; do
            cam_label=""
            if command -v v4l2-ctl &>/dev/null; then
                cam_label=$(v4l2-ctl -d "${dev}" --info 2>/dev/null \
                    | grep "Card type" | sed 's/.*: //' || true)
            fi
            printf '  %d) %s  %s\n' "${i}" "${dev}" "${cam_label}"
            ((i++))
        done <<< "${usb_dev_list}"
        read -r -p "Select camera [1-${usb_count}] (default: 1): " USB_CHOICE
        USB_CHOICE="${USB_CHOICE:-1}"
        CAM_DEVICE=$(echo "${usb_dev_list}" | sed -n "${USB_CHOICE}p")
        [[ -z "${CAM_DEVICE}" ]] && CAM_DEVICE=$(echo "${usb_dev_list}" | head -1)
    fi

    ok "USB camera selected: ${CAM_DEVICE}"

    # Detect USB camera resolutions
    usb_res=$(get_usb_resolutions "${CAM_DEVICE}" || true)
    while IFS= read -r r; do
        [[ -n "${r}" ]] && DETECTED_RESOLUTIONS+=("${r}")
    done <<< "${usb_res}"

    # Install ffmpeg for USB camera encoding if not present
    if ! command -v ffmpeg &>/dev/null; then
        info "Installing ffmpeg for USB camera support..."
        apt-get install -y -qq ffmpeg \
            || warn "ffmpeg install failed — USB camera streaming may not work."
    fi
else
    # Nothing detected yet — default to Pi camera (camera may work after reboot)
    CAM_TYPE="pi"
    warn "No camera detected yet. Defaulting to Pi camera mode."
    warn "Ensure the ribbon cable is connected; camera will be available after reboot."
fi

info "Camera type  : ${CAM_TYPE}"
[[ "${CAM_TYPE}" == "pi"  ]] && info "Camera tool  : ${CAM_TOOL}"
[[ "${CAM_TYPE}" == "usb" ]] && info "Camera device: ${CAM_DEVICE}"

# ==============================================================================
# 3. RESOLUTION & FRAMERATE SELECTOR
# ==============================================================================
header "Step 3: Resolution & Framerate Configuration"

# ─── Resolution selection ────────────────────────────────────────────────────
WIDTH=""
HEIGHT=""

if [[ ${#DETECTED_RESOLUTIONS[@]} -gt 0 ]]; then
    echo -e "${BOLD}Detected camera resolutions (highest first):${NC}"
    echo ""
    i=1
    for res in "${DETECTED_RESOLUTIONS[@]}"; do
        printf '  %d) %s\n' "${i}" "${res}"
        ((i++))
    done
    echo "  c) Enter custom resolution"
    echo ""
    HIGHEST_RES="${DETECTED_RESOLUTIONS[0]}"
    read -r -p "Select resolution [1-${#DETECTED_RESOLUTIONS[@]}/c] (default: 1 = ${HIGHEST_RES}): " RES_CHOICE
    RES_CHOICE="${RES_CHOICE:-1}"

    if [[ "${RES_CHOICE}" == "c" || "${RES_CHOICE}" == "C" ]]; then
        read -r -p "  Enter resolution (e.g. 1280x720): " CUSTOM_RES
        WIDTH=$(echo "${CUSTOM_RES}" | cut -d'x' -f1)
        HEIGHT=$(echo "${CUSTOM_RES}" | cut -d'x' -f2)
        if ! [[ "${WIDTH}" =~ ^[0-9]+$ && "${HEIGHT}" =~ ^[0-9]+$ && "${WIDTH}" -gt 0 && "${HEIGHT}" -gt 0 ]]; then
            warn "Invalid resolution; using detected highest: ${HIGHEST_RES}"
            WIDTH=$(echo "${HIGHEST_RES}" | cut -d'x' -f1)
            HEIGHT=$(echo "${HIGHEST_RES}" | cut -d'x' -f2)
        fi
    else
        chosen_res="${DETECTED_RESOLUTIONS[$((RES_CHOICE - 1))]:-${HIGHEST_RES}}"
        WIDTH=$(echo "${chosen_res}" | cut -d'x' -f1)
        HEIGHT=$(echo "${chosen_res}" | cut -d'x' -f2)
    fi
else
    # No auto-detection available — offer a preset list plus custom entry
    echo -e "${BOLD}Select a resolution (no camera resolutions auto-detected):${NC}"
    echo ""
    echo "  1)  640x480"
    echo "  2)  1280x720"
    echo "  3)  1920x1080"
    echo "  4)  2560x1440"
    echo "  5)  3840x2160"
    echo "  c)  Custom"
    echo ""
    case "${PI_MODEL}" in
        3)  DEFAULT_RES=1 ;;
        4)  DEFAULT_RES=2 ;;
        5)  DEFAULT_RES=3 ;;
        *)  DEFAULT_RES=2 ;;
    esac
    read -r -p "Select resolution [1-5/c] (default: ${DEFAULT_RES}): " RES_CHOICE
    RES_CHOICE="${RES_CHOICE:-${DEFAULT_RES}}"
    case "${RES_CHOICE}" in
        1) WIDTH=640;  HEIGHT=480  ;;
        2) WIDTH=1280; HEIGHT=720  ;;
        3) WIDTH=1920; HEIGHT=1080 ;;
        4) WIDTH=2560; HEIGHT=1440 ;;
        5) WIDTH=3840; HEIGHT=2160 ;;
        c|C)
            read -r -p "  Enter resolution (e.g. 1280x720): " CUSTOM_RES
            WIDTH=$(echo "${CUSTOM_RES}" | cut -d'x' -f1)
            HEIGHT=$(echo "${CUSTOM_RES}" | cut -d'x' -f2)
            if ! [[ "${WIDTH}" =~ ^[0-9]+$ && "${HEIGHT}" =~ ^[0-9]+$ && "${WIDTH}" -gt 0 && "${HEIGHT}" -gt 0 ]]; then
                warn "Invalid resolution; defaulting to 1280x720"
                WIDTH=1280; HEIGHT=720
            fi
            ;;
        *) warn "Invalid choice; defaulting to 1280x720."
           WIDTH=1280; HEIGHT=720 ;;
    esac
fi

ok "Resolution: ${WIDTH}x${HEIGHT}"

# ─── Framerate selection ─────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}Select framerate:${NC}"
echo ""
echo "  1)  5 fps   (lowest CPU — suitable for detection-only)"
echo "  2)  10 fps"
echo "  3)  15 fps"
echo "  4)  20 fps"
echo "  5)  25 fps"
echo "  6)  30 fps"
echo "  c)  Custom"
echo ""

# Default framerate based on Pi model AND selected resolution.
# Higher resolution → lower fps default for better per-frame quality (less
# motion blur, longer possible exposure) which is ideal for bird photography.
if [[ "${PI_MODEL}" == "3" ]]; then
    if   [[ ${WIDTH} -ge 1920 ]]; then DEFAULT_FPS=1   # 5 fps
    elif [[ ${WIDTH} -ge 1280 ]]; then DEFAULT_FPS=2   # 10 fps
    else                               DEFAULT_FPS=3   # 15 fps
    fi
elif [[ "${PI_MODEL}" == "4" ]]; then
    if   [[ ${WIDTH} -ge 2560 ]]; then DEFAULT_FPS=1   # 5 fps
    elif [[ ${WIDTH} -ge 1920 ]]; then DEFAULT_FPS=2   # 10 fps
    else                               DEFAULT_FPS=4   # 20 fps
    fi
else  # Pi 5 / unknown — still scale down at very high resolutions
    if   [[ ${WIDTH} -ge 3840 ]]; then DEFAULT_FPS=1   # 5 fps
    elif [[ ${WIDTH} -ge 2560 ]]; then DEFAULT_FPS=2   # 10 fps
    elif [[ ${WIDTH} -ge 1920 ]]; then DEFAULT_FPS=3   # 15 fps
    else                               DEFAULT_FPS=6   # 30 fps
    fi
fi

read -r -p "Select framerate [1-6/c] (default: ${DEFAULT_FPS}): " FPS_CHOICE
FPS_CHOICE="${FPS_CHOICE:-${DEFAULT_FPS}}"

case "${FPS_CHOICE}" in
    1) FPS=5  ;;
    2) FPS=10 ;;
    3) FPS=15 ;;
    4) FPS=20 ;;
    5) FPS=25 ;;
    6) FPS=30 ;;
    c|C)
        read -r -p "  Enter framerate (e.g. 60): " FPS
        if ! [[ "${FPS}" =~ ^[0-9]+$ && "${FPS}" -ge 1 ]]; then
            warn "Invalid framerate; defaulting to 15"
            FPS=15
        fi
        ;;
    *) warn "Invalid choice; defaulting to 15 fps."
       FPS=15 ;;
esac

ok "Framerate: ${FPS} fps"

# ─── Pi camera quality settings ──────────────────────────────────────────────
# Individual settings allow fine-grained control and can be updated via MQTT
# after setup without re-running the installer.
AWB_MODE="auto"
DENOISE_MODE="off"
EXPOSURE_MODE="normal"
EV_VALUE="0"
SHUTTER_SPEED="0"
if [[ "${CAM_TYPE}" == "pi" ]]; then
    echo ""
    echo -e "${BOLD}Bird photography quality optimisation (Pi camera only):${NC}"
    echo "  Enables --denoise cdn-hq and --awb auto for sharper, colour-accurate frames."
    echo "  Recommended when fps ≤ 15 and resolution ≥ 1080p."
    echo "  All settings can be changed at any time via MQTT."
    read -r -p "  Enable bird quality mode? [Y/n]: " BIRD_QUALITY
    BIRD_QUALITY="${BIRD_QUALITY:-y}"
    if [[ "${BIRD_QUALITY,,}" == "y" ]]; then
        AWB_MODE="auto"
        DENOISE_MODE="cdn-hq"
        ok "Bird quality mode enabled (awb=auto, denoise=cdn-hq). Adjustable via MQTT."
    else
        info "Bird quality mode disabled (denoise=off). Adjustable via MQTT."
    fi
fi

# ─── Sub-stream for detection (lower resolution) ────────────────────────────
# Modern Frigate setups benefit from separate main + sub streams:
#   main (birdcam)     — high-res for recording & live view
#   sub  (birdcam_sub) — low-res for detection (less CPU on Frigate)
# The sub-stream is derived from the main via go2rtc's ffmpeg transcoding,
# so no second camera process is needed.
echo ""
echo -e "${BOLD}Sub-stream for Frigate detection (recommended):${NC}"
echo "  Creates a low-resolution detection stream (${STREAM_NAME}_sub) alongside"
echo "  the main stream. Frigate uses the sub-stream for object detection and the"
echo "  main stream for recording/live view, reducing CPU usage significantly."
echo "  The sub-stream is derived from the main stream inside go2rtc (no extra"
echo "  camera process required)."
read -r -p "  Enable sub-stream for detection? [Y/n]: " ENABLE_SUB_STREAM
ENABLE_SUB_STREAM="${ENABLE_SUB_STREAM:-y}"

SUB_WIDTH=""
SUB_HEIGHT=""
SUB_FPS=""

if [[ "${ENABLE_SUB_STREAM,,}" == "y" ]]; then
    # Auto-calculate sub-stream resolution: DEFAULT_SUB_WIDTH wide, aspect-ratio-preserved
    SUB_WIDTH=${DEFAULT_SUB_WIDTH}
    SUB_HEIGHT=$(( WIDTH > 0 ? (DEFAULT_SUB_WIDTH * HEIGHT / WIDTH + 1) / 2 * 2 : DEFAULT_SUB_HEIGHT ))
    # Ensure minimum height of 2 and reasonable bounds
    [[ "${SUB_HEIGHT}" -lt 2 ]] && SUB_HEIGHT=${DEFAULT_SUB_HEIGHT}
    [[ "${SUB_HEIGHT}" -gt ${DEFAULT_SUB_WIDTH} ]] && SUB_HEIGHT=${DEFAULT_SUB_HEIGHT}
    SUB_FPS=${DEFAULT_SUB_FPS}

    echo ""
    echo -e "  Auto-calculated sub-stream: ${CYAN}${SUB_WIDTH}x${SUB_HEIGHT} @ ${SUB_FPS} fps${NC}"
    read -r -p "  Accept sub-stream defaults? [Y/n]: " SUB_ACCEPT
    SUB_ACCEPT="${SUB_ACCEPT:-y}"

    if [[ "${SUB_ACCEPT,,}" != "y" ]]; then
        read -r -p "  Sub-stream resolution (e.g. 640x480): " SUB_CUSTOM_RES
        if [[ -n "${SUB_CUSTOM_RES}" ]]; then
            SUB_WIDTH=$(echo "${SUB_CUSTOM_RES}" | cut -d'x' -f1)
            SUB_HEIGHT=$(echo "${SUB_CUSTOM_RES}" | cut -d'x' -f2)
            if ! [[ "${SUB_WIDTH}" =~ ^[0-9]+$ && "${SUB_HEIGHT}" =~ ^[0-9]+$ \
                   && "${SUB_WIDTH}" -gt 0 && "${SUB_HEIGHT}" -gt 0 ]]; then
                warn "Invalid sub-stream resolution; using ${DEFAULT_SUB_WIDTH}x${DEFAULT_SUB_HEIGHT}"
                SUB_WIDTH=${DEFAULT_SUB_WIDTH}; SUB_HEIGHT=${DEFAULT_SUB_HEIGHT}
            fi
        fi
        read -r -p "  Sub-stream FPS [5]: " SUB_FPS_INPUT
        if [[ -n "${SUB_FPS_INPUT}" ]] && [[ "${SUB_FPS_INPUT}" =~ ^[0-9]+$ ]] \
           && [[ "${SUB_FPS_INPUT}" -ge 1 ]]; then
            SUB_FPS="${SUB_FPS_INPUT}"
        else
            SUB_FPS=${DEFAULT_SUB_FPS}
        fi
    fi

    ok "Sub-stream: ${SUB_WIDTH}x${SUB_HEIGHT} @ ${SUB_FPS} fps (${STREAM_NAME}_sub)"
else
    info "Sub-stream disabled. Frigate will use the main stream for all roles."
fi

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
# Detect USB camera format capabilities (used for go2rtc command and watchdog)
USB_HAS_H264="false"
USB_HAS_MJPEG="false"
if [[ "${CAM_TYPE}" == "usb" ]] && command -v v4l2-ctl &>/dev/null; then
    v4l2_formats=$(v4l2-ctl -d "${CAM_DEVICE}" --list-formats 2>/dev/null || true)
    if echo "${v4l2_formats}" | grep -qiE "H264|H\.264|h264"; then
        USB_HAS_H264="true"
    fi
    if echo "${v4l2_formats}" | grep -qiE "MJPEG|MJPG"; then
        USB_HAS_MJPEG="true"
    fi
fi

cat > "${BIRDCAM_CONF}" <<BIRDCAM_EOF
# Birdcam configuration — generated by setup.sh
# $(date)
STREAM_NAME="${STREAM_NAME}"
WIDTH=${WIDTH}
HEIGHT=${HEIGHT}
FPS=${FPS}
CAM_TYPE="${CAM_TYPE}"
CAM_TOOL="${CAM_TOOL}"
CAM_DEVICE="${CAM_DEVICE}"
USB_HAS_H264="${USB_HAS_H264}"
USB_HAS_MJPEG="${USB_HAS_MJPEG}"
RTSP_PORT="${RTSP_PORT}"
PI_MODEL="${PI_MODEL}"
RUN_USER="${RUN_USER}"
MQTT_ENABLED="${ENABLE_MQTT,,}"
MQTT_HOST="${MQTT_HOST}"
MQTT_PORT="${MQTT_PORT}"
MQTT_USER="${MQTT_USER}"
MQTT_PASS="${MQTT_PASS}"
MQTT_TOPIC_PREFIX="${MQTT_TOPIC_PREFIX}"
AWB_MODE="${AWB_MODE}"
DENOISE_MODE="${DENOISE_MODE}"
EXPOSURE_MODE="${EXPOSURE_MODE}"
EV_VALUE="${EV_VALUE}"
SHUTTER_SPEED="${SHUTTER_SPEED}"
SUB_ENABLED="${ENABLE_SUB_STREAM,,}"
SUB_WIDTH="${SUB_WIDTH}"
SUB_HEIGHT="${SUB_HEIGHT}"
SUB_FPS="${SUB_FPS}"
WEBRTC_PORT="${WEBRTC_PORT}"
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

    # Strip leading 'v' for comparison (--version output has no 'v' prefix)
    LATEST_VER_STRIPPED="${LATEST_VER#v}"

    if [[ "${INSTALLED_VER}" == *"${LATEST_VER_STRIPPED}"* ]]; then
        ok "go2rtc is already up to date (${LATEST_VER})."
    else
        info "Updating go2rtc from ${INSTALLED_VER} to ${LATEST_VER}..."
        # Stop the service so the binary is not in use (ETXTBSY)
        systemctl stop go2rtc.service 2>/dev/null || true
        backup_file "${GO2RTC_BIN}"
        rm -f "${GO2RTC_BIN}"
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

# Build the camera command based on camera type
# ── Pi Camera (rpicam-vid) ───────────────────────────────────────────────────
#   --codec h264    — hardware H.264 encoder
#   --inline        — Annex-B H.264 (SPS/PPS before every IDR)
#   --flush         — flush output after every frame (prevents pipe EOF)
#   --nopreview     — headless
#   --timeout 0     — run indefinitely
#   --width/--height/--framerate
#   -o - — pipe raw H.264 to stdout for go2rtc
#
# ── USB Camera (ffmpeg + v4l2) ───────────────────────────────────────────────
#   Prefer native H.264 (copy), then MJPEG→H.264, then raw→H.264 (SW encode)

if [[ "${CAM_TYPE}" == "usb" ]]; then
    if [[ "${USB_HAS_H264}" == "true" ]]; then
        CAM_CMD="exec:ffmpeg -hide_banner -loglevel warning"
        CAM_CMD+=" -f v4l2 -input_format h264"
        CAM_CMD+=" -video_size ${WIDTH}x${HEIGHT} -framerate ${FPS}"
        CAM_CMD+=" -i ${CAM_DEVICE} -c copy -f h264 -"
    elif [[ "${USB_HAS_MJPEG}" == "true" ]]; then
        CAM_CMD="exec:ffmpeg -hide_banner -loglevel warning"
        CAM_CMD+=" -f v4l2 -input_format mjpeg"
        CAM_CMD+=" -video_size ${WIDTH}x${HEIGHT} -framerate ${FPS}"
        CAM_CMD+=" -i ${CAM_DEVICE}"
        CAM_CMD+=" -c:v libx264 -preset ultrafast -tune zerolatency -f h264 -"
    else
        CAM_CMD="exec:ffmpeg -hide_banner -loglevel warning"
        CAM_CMD+=" -f v4l2"
        CAM_CMD+=" -video_size ${WIDTH}x${HEIGHT} -framerate ${FPS}"
        CAM_CMD+=" -i ${CAM_DEVICE}"
        CAM_CMD+=" -c:v libx264 -preset ultrafast -tune zerolatency -f h264 -"
    fi
else
    # Pi Camera — CAM_CMD includes the exec: prefix for consistency
    CAM_CMD="exec:${CAM_TOOL} --codec h264 --inline --flush --nopreview --timeout 0"
    CAM_CMD+=" --width ${WIDTH} --height ${HEIGHT} --framerate ${FPS}"
    CAM_CMD+=" --awb ${AWB_MODE}"
    [[ "${DENOISE_MODE}" != "off" ]] && CAM_CMD+=" --denoise ${DENOISE_MODE}"
    [[ "${EXPOSURE_MODE}" != "normal" ]] && CAM_CMD+=" --exposure ${EXPOSURE_MODE}"
    [[ "${EV_VALUE}" != "0" ]] && CAM_CMD+=" --ev ${EV_VALUE}"
    [[ "${SHUTTER_SPEED}" != "0" ]] && CAM_CMD+=" --shutter ${SHUTTER_SPEED}"
    CAM_CMD+=" -o -"
fi

# Build sub-stream source (go2rtc ffmpeg transcoding from main stream)
SUB_STREAM_BLOCK=""
if [[ "${ENABLE_SUB_STREAM,,}" == "y" ]] && [[ -n "${SUB_WIDTH}" ]] && [[ -n "${SUB_HEIGHT}" ]]; then
    SUB_STREAM_BLOCK="  ${STREAM_NAME}_sub:
    - \"ffmpeg:${STREAM_NAME}#video=h264#width=${SUB_WIDTH}#height=${SUB_HEIGHT}#raw=-r ${SUB_FPS}\""
fi

cat > "${GO2RTC_YAML}" <<GO2RTC_EOF
# go2rtc configuration for birdcam
# Generated by setup.sh — $(date)
# Repository: ${REPO_URL}

streams:
  ${STREAM_NAME}:
    - ${CAM_CMD}
${SUB_STREAM_BLOCK}

rtsp:
  listen: ":${RTSP_PORT}"

webrtc:
  listen: ":${WEBRTC_PORT}"
  candidates:
    - stun:${WEBRTC_PORT}

api:
  listen: ":1984"

log:
  level: warn
GO2RTC_EOF

chown "${RUN_USER}:${RUN_USER}" "${GO2RTC_YAML}" 2>/dev/null || true
ok "go2rtc config written to ${GO2RTC_YAML}"
info "Main stream: ${CAM_CMD}"
if [[ -n "${SUB_STREAM_BLOCK}" ]]; then
    info "Sub-stream: ${STREAM_NAME}_sub (${SUB_WIDTH}x${SUB_HEIGHT} @ ${SUB_FPS} fps via ffmpeg transcoding)"
fi

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
WIDTH="${WIDTH:-1280}"
HEIGHT="${HEIGHT:-720}"
CAM_TYPE="${CAM_TYPE:-pi}"
CAM_TOOL="${CAM_TOOL:-rpicam-vid}"
CAM_DEVICE="${CAM_DEVICE:-}"
USB_HAS_H264="${USB_HAS_H264:-false}"
USB_HAS_MJPEG="${USB_HAS_MJPEG:-false}"
STREAM_NAME="${STREAM_NAME:-birdcam}"
AWB_MODE="${AWB_MODE:-auto}"
DENOISE_MODE="${DENOISE_MODE:-off}"
EXPOSURE_MODE="${EXPOSURE_MODE:-normal}"
EV_VALUE="${EV_VALUE:-0}"
SHUTTER_SPEED="${SHUTTER_SPEED:-0}"
SUB_ENABLED="${SUB_ENABLED:-n}"
SUB_WIDTH="${SUB_WIDTH:-640}"
SUB_HEIGHT="${SUB_HEIGHT:-480}"
SUB_FPS="${SUB_FPS:-5}"
RTSP_PORT="${RTSP_PORT:-8554}"
WEBRTC_PORT="${WEBRTC_PORT:-8555}"

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

build_cam_cmd() {
    local fps="$1"
    if [[ "${CAM_TYPE}" == "usb" ]]; then
        if [[ "${USB_HAS_H264}" == "true" ]]; then
            echo "exec:ffmpeg -hide_banner -loglevel warning -f v4l2 -input_format h264 -video_size ${WIDTH}x${HEIGHT} -framerate ${fps} -i ${CAM_DEVICE} -c copy -f h264 -"
        elif [[ "${USB_HAS_MJPEG}" == "true" ]]; then
            echo "exec:ffmpeg -hide_banner -loglevel warning -f v4l2 -input_format mjpeg -video_size ${WIDTH}x${HEIGHT} -framerate ${fps} -i ${CAM_DEVICE} -c:v libx264 -preset ultrafast -tune zerolatency -f h264 -"
        else
            echo "exec:ffmpeg -hide_banner -loglevel warning -f v4l2 -video_size ${WIDTH}x${HEIGHT} -framerate ${fps} -i ${CAM_DEVICE} -c:v libx264 -preset ultrafast -tune zerolatency -f h264 -"
        fi
    else
        local pi_cmd="exec:${CAM_TOOL} --codec h264 --inline --flush --nopreview --timeout 0 --width ${WIDTH} --height ${HEIGHT} --framerate ${fps}"
        pi_cmd+=" --awb ${AWB_MODE:-auto}"
        [[ "${DENOISE_MODE:-off}" != "off" ]] && pi_cmd+=" --denoise ${DENOISE_MODE:-off}"
        [[ "${EXPOSURE_MODE:-normal}" != "normal" ]] && pi_cmd+=" --exposure ${EXPOSURE_MODE:-normal}"
        [[ "${EV_VALUE:-0}" != "0" ]] && pi_cmd+=" --ev ${EV_VALUE:-0}"
        [[ "${SHUTTER_SPEED:-0}" != "0" ]] && pi_cmd+=" --shutter ${SHUTTER_SPEED:-0}"
        pi_cmd+=" -o -"
        echo "${pi_cmd}"
    fi
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
    CAM_CMD=$(build_cam_cmd "${ADJUSTED_FPS}")

    # Build sub-stream block if enabled
    local sub_block=""
    if [[ "${SUB_ENABLED}" == "y" ]] && [[ -n "${SUB_WIDTH}" ]] && [[ -n "${SUB_HEIGHT}" ]]; then
        sub_block="  ${STREAM_NAME}_sub:
    - \"ffmpeg:${STREAM_NAME}#video=h264#width=${SUB_WIDTH}#height=${SUB_HEIGHT}#raw=-r ${SUB_FPS}\""
    fi

    cat > "${GO2RTC_YAML}" <<YAML_EOF
streams:
  ${STREAM_NAME}:
    - ${CAM_CMD}
${sub_block}

rtsp:
  listen: ":${RTSP_PORT}"

webrtc:
  listen: ":${WEBRTC_PORT}"
  candidates:
    - stun:${WEBRTC_PORT}

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
# birdcam-mqtt-discovery.sh — Publishes HA MQTT auto-discovery messages,
# periodically sends system stats, and handles camera settings via MQTT.
set -euo pipefail

CONF="/etc/birdcam.conf"
# shellcheck disable=SC1090
[[ -f "${CONF}" ]] && source "${CONF}"

MQTT_ENABLED="${MQTT_ENABLED:-n}"
[[ "${MQTT_ENABLED}" != "y" ]] && exit 0

MQTT_HOST="${MQTT_HOST:-localhost}"
MQTT_PORT="${MQTT_PORT:-1883}"
MQTT_USER="${MQTT_USER:-}"
MQTT_PASS="${MQTT_PASS:-}"
MQTT_TOPIC_PREFIX="${MQTT_TOPIC_PREFIX:-homeassistant}"

# Camera settings defaults (backward-compatible with old conf)
FPS="${FPS:-15}"
WIDTH="${WIDTH:-1280}"
HEIGHT="${HEIGHT:-720}"
CAM_TYPE="${CAM_TYPE:-pi}"
CAM_TOOL="${CAM_TOOL:-rpicam-vid}"
CAM_DEVICE="${CAM_DEVICE:-}"
USB_HAS_H264="${USB_HAS_H264:-false}"
USB_HAS_MJPEG="${USB_HAS_MJPEG:-false}"
STREAM_NAME="${STREAM_NAME:-birdcam}"
AWB_MODE="${AWB_MODE:-auto}"
DENOISE_MODE="${DENOISE_MODE:-off}"
EXPOSURE_MODE="${EXPOSURE_MODE:-normal}"
EV_VALUE="${EV_VALUE:-0}"
SHUTTER_SPEED="${SHUTTER_SPEED:-0}"
SUB_ENABLED="${SUB_ENABLED:-n}"
SUB_WIDTH="${SUB_WIDTH:-640}"
SUB_HEIGHT="${SUB_HEIGHT:-480}"
SUB_FPS="${SUB_FPS:-5}"
RTSP_PORT="${RTSP_PORT:-8554}"
WEBRTC_PORT="${WEBRTC_PORT:-8555}"

GO2RTC_YAML="/etc/go2rtc/go2rtc.yaml"

HOSTNAME_SHORT=$(hostname -s)
DEVICE_ID="birdcam_${HOSTNAME_SHORT}"
STATE_TOPIC="birdcam/${HOSTNAME_SHORT}/state"
CMD_TOPIC="birdcam/${HOSTNAME_SHORT}/cmd"
AVAIL_TOPIC="birdcam/${HOSTNAME_SHORT}/availability"
CAM_SETTINGS_TOPIC="birdcam/${HOSTNAME_SHORT}/camera"

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

    # Wi-Fi signal quality sensor
    mqtt_pub "${MQTT_TOPIC_PREFIX}/sensor/${DEVICE_ID}/wifi_quality/config" \
        "{\"name\":\"Wi-Fi Quality\",\"unique_id\":\"${DEVICE_ID}_wifi_quality\",\"state_topic\":\"${STATE_TOPIC}\",\"value_template\":\"{{ value_json.wifi_quality }}\",\"unit_of_measurement\":\"%\",\"icon\":\"mdi:wifi\",\"device\":${DEVICE_JSON}}"

    # Stream resolution sensor (read-only, sourced from state topic)
    mqtt_pub "${MQTT_TOPIC_PREFIX}/sensor/${DEVICE_ID}/resolution/config" \
        "{\"name\":\"Stream Resolution\",\"unique_id\":\"${DEVICE_ID}_resolution\",\"state_topic\":\"${STATE_TOPIC}\",\"value_template\":\"{{ value_json.resolution }}\",\"icon\":\"mdi:image-size-select-large\",\"device\":${DEVICE_JSON}}"

    # Stream FPS sensor (read-only, sourced from state topic)
    mqtt_pub "${MQTT_TOPIC_PREFIX}/sensor/${DEVICE_ID}/fps/config" \
        "{\"name\":\"Stream FPS\",\"unique_id\":\"${DEVICE_ID}_fps\",\"state_topic\":\"${STATE_TOPIC}\",\"value_template\":\"{{ value_json.fps }}\",\"unit_of_measurement\":\"fps\",\"icon\":\"mdi:filmstrip\",\"device\":${DEVICE_JSON}}"

    # ── Camera settings controls ─────────────────────────────────────────────

    # Resolution text control (works for both Pi and USB cameras)
    mqtt_pub "${MQTT_TOPIC_PREFIX}/text/${DEVICE_ID}/resolution_ctrl/config" \
        "{\"name\":\"Set Resolution\",\"unique_id\":\"${DEVICE_ID}_res_ctrl\",\"command_topic\":\"${CAM_SETTINGS_TOPIC}/resolution/set\",\"state_topic\":\"${CAM_SETTINGS_TOPIC}/resolution/state\",\"icon\":\"mdi:image-size-select-large\",\"device\":${DEVICE_JSON}}"

    # FPS number control (works for both Pi and USB cameras)
    mqtt_pub "${MQTT_TOPIC_PREFIX}/number/${DEVICE_ID}/fps_ctrl/config" \
        "{\"name\":\"Set FPS\",\"unique_id\":\"${DEVICE_ID}_fps_ctrl\",\"command_topic\":\"${CAM_SETTINGS_TOPIC}/fps/set\",\"state_topic\":\"${CAM_SETTINGS_TOPIC}/fps/state\",\"min\":1,\"max\":120,\"step\":1,\"unit_of_measurement\":\"fps\",\"icon\":\"mdi:filmstrip\",\"device\":${DEVICE_JSON}}"

    # Pi-camera-only settings
    if [[ "${CAM_TYPE}" == "pi" ]]; then
        # White balance select
        mqtt_pub "${MQTT_TOPIC_PREFIX}/select/${DEVICE_ID}/awb/config" \
            "{\"name\":\"White Balance\",\"unique_id\":\"${DEVICE_ID}_awb\",\"command_topic\":\"${CAM_SETTINGS_TOPIC}/awb/set\",\"state_topic\":\"${CAM_SETTINGS_TOPIC}/awb/state\",\"options\":[\"off\",\"auto\",\"incandescent\",\"tungsten\",\"fluorescent\",\"indoor\",\"daylight\",\"cloudy\"],\"icon\":\"mdi:white-balance-auto\",\"device\":${DEVICE_JSON}}"

        # Denoise select
        mqtt_pub "${MQTT_TOPIC_PREFIX}/select/${DEVICE_ID}/denoise/config" \
            "{\"name\":\"Denoise\",\"unique_id\":\"${DEVICE_ID}_denoise\",\"command_topic\":\"${CAM_SETTINGS_TOPIC}/denoise/set\",\"state_topic\":\"${CAM_SETTINGS_TOPIC}/denoise/state\",\"options\":[\"off\",\"cdn-off\",\"cdn-fast\",\"cdn-hq\"],\"icon\":\"mdi:image-filter\",\"device\":${DEVICE_JSON}}"

        # Exposure mode select
        mqtt_pub "${MQTT_TOPIC_PREFIX}/select/${DEVICE_ID}/exposure_mode/config" \
            "{\"name\":\"Exposure Mode\",\"unique_id\":\"${DEVICE_ID}_exposure_mode\",\"command_topic\":\"${CAM_SETTINGS_TOPIC}/exposure/set\",\"state_topic\":\"${CAM_SETTINGS_TOPIC}/exposure/state\",\"options\":[\"normal\",\"sport\",\"long\",\"custom\"],\"icon\":\"mdi:camera-iris\",\"device\":${DEVICE_JSON}}"

        # Exposure compensation (EV) number
        mqtt_pub "${MQTT_TOPIC_PREFIX}/number/${DEVICE_ID}/ev/config" \
            "{\"name\":\"Exposure Compensation (EV)\",\"unique_id\":\"${DEVICE_ID}_ev\",\"command_topic\":\"${CAM_SETTINGS_TOPIC}/ev/set\",\"state_topic\":\"${CAM_SETTINGS_TOPIC}/ev/state\",\"min\":-10,\"max\":10,\"step\":0.5,\"icon\":\"mdi:brightness-6\",\"device\":${DEVICE_JSON}}"

        # Shutter speed number (0 = auto)
        mqtt_pub "${MQTT_TOPIC_PREFIX}/number/${DEVICE_ID}/shutter/config" \
            "{\"name\":\"Shutter Speed (µs, 0=auto)\",\"unique_id\":\"${DEVICE_ID}_shutter\",\"command_topic\":\"${CAM_SETTINGS_TOPIC}/shutter/set\",\"state_topic\":\"${CAM_SETTINGS_TOPIC}/shutter/state\",\"min\":0,\"max\":1000000,\"step\":1,\"unit_of_measurement\":\"µs\",\"icon\":\"mdi:timer\",\"device\":${DEVICE_JSON}}"
    fi

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

    # Wi-Fi signal quality (0-100; 100 when not applicable / Ethernet)
    local wifi_quality=100
    if command -v iwconfig &>/dev/null; then
        local link
        link=$(iwconfig 2>/dev/null | grep -i "link quality" | head -1 \
            | sed 's/.*Link Quality=\([0-9]*\)\/\([0-9]*\).*/\1 \2/')
        if [[ -n "${link}" ]]; then
            local num den
            num=$(echo "${link}" | cut -d' ' -f1)
            den=$(echo "${link}" | cut -d' ' -f2)
            if [[ "${den}" -gt 0 ]]; then
                wifi_quality=$(( num * 100 / den ))
            fi
        fi
    fi

    # Current stream settings from config
    local cur_fps="${FPS:-0}"
    local cur_res="${WIDTH:-0}x${HEIGHT:-0}"

    local payload
    payload=$(cat <<PEOF
{"cpu_temp":${cpu_temp},"cpu_usage":${cpu_usage},"ram_usage":${ram_usage},"stream_status":"${stream_status}","wifi_quality":${wifi_quality},"resolution":"${cur_res}","fps":${cur_fps}}
PEOF
    )
    mqtt_pub "${STATE_TOPIC}" "${payload}"
}

# ─── Publish current camera settings to their state topics ───────────────────
publish_camera_state() {
    mqtt_pub "${CAM_SETTINGS_TOPIC}/fps/state" "${FPS:-15}"
    mqtt_pub "${CAM_SETTINGS_TOPIC}/resolution/state" "${WIDTH:-1280}x${HEIGHT:-720}"
    if [[ "${CAM_TYPE}" == "pi" ]]; then
        mqtt_pub "${CAM_SETTINGS_TOPIC}/awb/state" "${AWB_MODE:-auto}"
        mqtt_pub "${CAM_SETTINGS_TOPIC}/denoise/state" "${DENOISE_MODE:-off}"
        mqtt_pub "${CAM_SETTINGS_TOPIC}/exposure/state" "${EXPOSURE_MODE:-normal}"
        mqtt_pub "${CAM_SETTINGS_TOPIC}/ev/state" "${EV_VALUE:-0}"
        mqtt_pub "${CAM_SETTINGS_TOPIC}/shutter/state" "${SHUTTER_SPEED:-0}"
    fi
}

# ─── Persist a key=value change to birdcam.conf and reload in memory ─────────
update_conf() {
    local key="$1"
    local value="$2"
    if grep -q "^${key}=" "${CONF}"; then
        sed -i "s|^${key}=.*|${key}=\"${value}\"|" "${CONF}"
    else
        echo "${key}=\"${value}\"" >> "${CONF}"
    fi
    # shellcheck disable=SC1090
    source "${CONF}"
}

# ─── Rebuild go2rtc.yaml from current conf values ────────────────────────────
rebuild_go2rtc_config() {
    local cam_cmd
    if [[ "${CAM_TYPE}" == "usb" ]]; then
        if [[ "${USB_HAS_H264}" == "true" ]]; then
            cam_cmd="exec:ffmpeg -hide_banner -loglevel warning -f v4l2 -input_format h264 -video_size ${WIDTH}x${HEIGHT} -framerate ${FPS} -i ${CAM_DEVICE} -c copy -f h264 -"
        elif [[ "${USB_HAS_MJPEG}" == "true" ]]; then
            cam_cmd="exec:ffmpeg -hide_banner -loglevel warning -f v4l2 -input_format mjpeg -video_size ${WIDTH}x${HEIGHT} -framerate ${FPS} -i ${CAM_DEVICE} -c:v libx264 -preset ultrafast -tune zerolatency -f h264 -"
        else
            cam_cmd="exec:ffmpeg -hide_banner -loglevel warning -f v4l2 -video_size ${WIDTH}x${HEIGHT} -framerate ${FPS} -i ${CAM_DEVICE} -c:v libx264 -preset ultrafast -tune zerolatency -f h264 -"
        fi
    else
        cam_cmd="exec:${CAM_TOOL} --codec h264 --inline --flush --nopreview --timeout 0"
        cam_cmd+=" --width ${WIDTH} --height ${HEIGHT} --framerate ${FPS}"
        cam_cmd+=" --awb ${AWB_MODE:-auto}"
        [[ "${DENOISE_MODE:-off}" != "off" ]] && cam_cmd+=" --denoise ${DENOISE_MODE:-off}"
        [[ "${EXPOSURE_MODE:-normal}" != "normal" ]] && cam_cmd+=" --exposure ${EXPOSURE_MODE:-normal}"
        [[ "${EV_VALUE:-0}" != "0" ]] && cam_cmd+=" --ev ${EV_VALUE:-0}"
        [[ "${SHUTTER_SPEED:-0}" != "0" ]] && cam_cmd+=" --shutter ${SHUTTER_SPEED:-0}"
        cam_cmd+=" -o -"
    fi

    # Build sub-stream block if enabled
    local sub_block=""
    if [[ "${SUB_ENABLED}" == "y" ]] && [[ -n "${SUB_WIDTH}" ]] && [[ -n "${SUB_HEIGHT}" ]]; then
        sub_block="  ${STREAM_NAME}_sub:
    - \"ffmpeg:${STREAM_NAME}#video=h264#width=${SUB_WIDTH}#height=${SUB_HEIGHT}#raw=-r ${SUB_FPS}\""
    fi

    cat > "${GO2RTC_YAML}" <<REBUILD_EOF
streams:
  ${STREAM_NAME}:
    - ${cam_cmd}
${sub_block}

rtsp:
  listen: ":${RTSP_PORT}"

webrtc:
  listen: ":${WEBRTC_PORT}"
  candidates:
    - stun:${WEBRTC_PORT}

api:
  listen: ":1984"

log:
  level: warn
REBUILD_EOF
}

# ─── Validate and apply a single camera setting ───────────────────────────────
apply_camera_setting() {
    local setting="$1"
    local value="$2"
    local valid=true

    case "${setting}" in
        fps)
            if [[ "${value}" =~ ^[0-9]+$ ]] && [[ "${value}" -ge 1 ]] && [[ "${value}" -le 120 ]]; then
                update_conf "FPS" "${value}"
            else
                logger -t birdcam-mqtt "Invalid FPS value ignored: ${value}"
                valid=false
            fi
            ;;
        resolution)
            local w h
            w=$(echo "${value}" | cut -d'x' -f1)
            h=$(echo "${value}" | cut -d'x' -f2)
            if [[ "${w}" =~ ^[0-9]+$ ]] && [[ "${h}" =~ ^[0-9]+$ ]] \
               && [[ "${w}" -gt 0 ]] && [[ "${h}" -gt 0 ]]; then
                update_conf "WIDTH" "${w}"
                update_conf "HEIGHT" "${h}"
            else
                logger -t birdcam-mqtt "Invalid resolution value ignored: ${value}"
                valid=false
            fi
            ;;
        awb)
            case "${value}" in
                off|auto|incandescent|tungsten|fluorescent|indoor|daylight|cloudy)
                    update_conf "AWB_MODE" "${value}" ;;
                *)
                    logger -t birdcam-mqtt "Invalid AWB mode ignored: ${value}"
                    valid=false ;;
            esac
            ;;
        denoise)
            case "${value}" in
                off|cdn-off|cdn-fast|cdn-hq)
                    update_conf "DENOISE_MODE" "${value}" ;;
                *)
                    logger -t birdcam-mqtt "Invalid denoise mode ignored: ${value}"
                    valid=false ;;
            esac
            ;;
        exposure)
            case "${value}" in
                normal|sport|long|custom)
                    update_conf "EXPOSURE_MODE" "${value}" ;;
                *)
                    logger -t birdcam-mqtt "Invalid exposure mode ignored: ${value}"
                    valid=false ;;
            esac
            ;;
        ev)
            if [[ "${value}" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
                local ev_int
                ev_int=$(echo "${value}" | awk '{print int($1)}')
                if [[ "${ev_int}" -ge -10 ]] && [[ "${ev_int}" -le 10 ]]; then
                    update_conf "EV_VALUE" "${value}"
                else
                    logger -t birdcam-mqtt "EV value out of range ignored: ${value}"
                    valid=false
                fi
            else
                logger -t birdcam-mqtt "Invalid EV value ignored: ${value}"
                valid=false
            fi
            ;;
        shutter)
            if [[ "${value}" =~ ^[0-9]+$ ]]; then
                update_conf "SHUTTER_SPEED" "${value}"
            else
                logger -t birdcam-mqtt "Invalid shutter speed ignored: ${value}"
                valid=false
            fi
            ;;
        *)
            logger -t birdcam-mqtt "Unknown camera setting ignored: ${setting}"
            valid=false
            ;;
    esac

    if [[ "${valid}" == "true" ]]; then
        rebuild_go2rtc_config
        systemctl restart go2rtc.service 2>/dev/null || true
        logger -t birdcam-mqtt "Camera setting applied: ${setting}=${value}"
        publish_camera_state
    fi
}

# ─── Listen for commands (restart / update) and camera settings ───────────────
handle_commands() {
    # Use -v so each output line is "<topic> <payload>", allowing both the
    # existing CMD_TOPIC and the new per-setting camera topics to be handled
    # from a single subscription.
    mosquitto_sub "${MQTT_AUTH[@]}" -v \
        -t "${CMD_TOPIC}" \
        -t "${CAM_SETTINGS_TOPIC}/+/set" \
        2>/dev/null | while IFS=' ' read -r topic payload; do
        if [[ "${topic}" == "${CMD_TOPIC}" ]]; then
            case "${payload}" in
                restart)
                    logger -t birdcam-mqtt "Restart requested via MQTT"
                    systemctl restart go2rtc.service 2>/dev/null || true
                    ;;
                update)
                    logger -t birdcam-mqtt "Update requested via MQTT"
                    /usr/local/bin/birdcam-autoupdate.sh 2>/dev/null || true
                    ;;
            esac
        else
            # Extract setting name from topic: birdcam/<host>/camera/<setting>/set
            local setting
            setting=$(echo "${topic}" | sed "s|${CAM_SETTINGS_TOPIC}/||;s|/set\$||")
            apply_camera_setting "${setting}" "${payload}"
        fi
    done
}

# ─── Main ─────────────────────────────────────────────────────────────────────
publish_discovery
publish_camera_state

# Start command listener in background
handle_commands &
CMD_PID=$!
trap "kill ${CMD_PID} 2>/dev/null; mqtt_pub '${AVAIL_TOPIC}' 'offline'" EXIT

# Periodically publish state (every 30 seconds)
while true; do
    publish_state
    publish_camera_state
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

log_msg() { logger -t birdcam-update "$1"; echo "[birdcam-update] $1"; }

log_msg "Checking for updates..."

# Download latest setup.sh to a temp file
TMP=$(mktemp) || exit 1
chmod 600 "${TMP}"
if curl -fsSL -o "${TMP}" "${SETUP_URL}" 2>/dev/null; then
    if [[ -f "${LOCAL_SCRIPT}" ]]; then
        if ! diff -q "${TMP}" "${LOCAL_SCRIPT}" &>/dev/null; then
            cp "${TMP}" "${LOCAL_SCRIPT}"
            chmod +x "${LOCAL_SCRIPT}"
            log_msg "Updated setup.sh — new version downloaded."
        else
            log_msg "setup.sh is already up to date."
        fi
    else
        cp "${TMP}" "${LOCAL_SCRIPT}"
        chmod +x "${LOCAL_SCRIPT}"
        log_msg "setup.sh installed for the first time."
    fi
    rm -f "${TMP}"
else
    log_msg "Failed to download update (network issue?)."
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
echo -e "  Main stream  : ${WIDTH}x${HEIGHT} @ ${FPS} fps"
if [[ "${ENABLE_SUB_STREAM,,}" == "y" ]]; then
    echo -e "  Sub stream   : ${SUB_WIDTH}x${SUB_HEIGHT} @ ${SUB_FPS} fps (detection)"
fi
echo -e "  Camera tool  : ${CAM_TOOL}"
echo -e "  Pi model     : ${PI_MODEL}"
echo ""
echo -e "${BOLD}📺 RTSP URLs:${NC}"
echo -e "  Main : ${CYAN}rtsp://${PI_IP}:${RTSP_PORT}/${STREAM_NAME}${NC}"
if [[ "${ENABLE_SUB_STREAM,,}" == "y" ]]; then
    echo -e "  Sub  : ${CYAN}rtsp://${PI_IP}:${RTSP_PORT}/${STREAM_NAME}_sub${NC}"
fi
echo ""
echo -e "${BOLD}🌐 WebRTC (browser):${NC}"
echo -e "  ${CYAN}http://${PI_IP}:1984/${NC}"
echo ""
echo -e "${BOLD}▶ Test with VLC:${NC}"
echo -e "  vlc rtsp://${PI_IP}:${RTSP_PORT}/${STREAM_NAME}"
echo ""

if [[ "${ENABLE_SUB_STREAM,,}" == "y" ]]; then
    echo -e "${BOLD}📋 Frigate Configuration — Option A (multi-stream via go2rtc restream):${NC}"
    echo -e "  ${YELLOW}go2rtc:"
    echo -e "    streams:"
    echo -e "      birdcam:"
    echo -e "        - rtsp://${PI_IP}:${RTSP_PORT}/${STREAM_NAME}"
    echo -e "      birdcam_sub:"
    echo -e "        - rtsp://${PI_IP}:${RTSP_PORT}/${STREAM_NAME}_sub"
    echo -e ""
    echo -e "  cameras:"
    echo -e "    birdcam:"
    echo -e "      ffmpeg:"
    echo -e "        inputs:"
    echo -e "          - path: rtsp://127.0.0.1:8554/${STREAM_NAME}"
    echo -e "            input_args: preset-rtsp-restream"
    echo -e "            roles:"
    echo -e "              - record"
    echo -e "          - path: rtsp://127.0.0.1:8554/${STREAM_NAME}_sub"
    echo -e "            input_args: preset-rtsp-restream"
    echo -e "            roles:"
    echo -e "              - detect"
    echo -e "      detect:"
    echo -e "        width: ${SUB_WIDTH}"
    echo -e "        height: ${SUB_HEIGHT}"
    echo -e "        fps: ${SUB_FPS}"
    echo -e "      record:"
    echo -e "        enabled: true"
    echo -e "      objects:"
    echo -e "        track:"
    echo -e "          - bird${NC}"
    echo ""
    echo -e "${BOLD}📋 Frigate Configuration — Option B (direct RTSP, multi-stream):${NC}"
    echo -e "  ${YELLOW}cameras:"
    echo -e "    birdcam:"
    echo -e "      ffmpeg:"
    echo -e "        inputs:"
    echo -e "          - path: rtsp://${PI_IP}:${RTSP_PORT}/${STREAM_NAME}"
    echo -e "            roles:"
    echo -e "              - record"
    echo -e "          - path: rtsp://${PI_IP}:${RTSP_PORT}/${STREAM_NAME}_sub"
    echo -e "            roles:"
    echo -e "              - detect"
    echo -e "      detect:"
    echo -e "        width: ${SUB_WIDTH}"
    echo -e "        height: ${SUB_HEIGHT}"
    echo -e "        fps: ${SUB_FPS}"
    echo -e "      record:"
    echo -e "        enabled: true"
    echo -e "      objects:"
    echo -e "        track:"
    echo -e "          - bird${NC}"
    echo ""
    echo -e "${BOLD}📋 Frigate Configuration — Option C (Frigate's bundled go2rtc):${NC}"
    echo -e "  ${YELLOW}# Add these streams to Frigate's go2rtc config section."
    echo -e "  # No need to run standalone go2rtc on the Pi — Frigate handles it."
    echo -e "  go2rtc:"
    echo -e "    streams:"
    echo -e "      birdcam:"
    echo -e "        - rtsp://${PI_IP}:${RTSP_PORT}/${STREAM_NAME}"
    echo -e "      birdcam_sub:"
    echo -e "        - rtsp://${PI_IP}:${RTSP_PORT}/${STREAM_NAME}_sub"
    echo -e "    webrtc:"
    echo -e "      candidates:"
    echo -e "        - stun:8555"
    echo -e ""
    echo -e "  cameras:"
    echo -e "    birdcam:"
    echo -e "      ffmpeg:"
    echo -e "        inputs:"
    echo -e "          - path: rtsp://127.0.0.1:8554/${STREAM_NAME}"
    echo -e "            input_args: preset-rtsp-restream"
    echo -e "            roles:"
    echo -e "              - record"
    echo -e "          - path: rtsp://127.0.0.1:8554/${STREAM_NAME}_sub"
    echo -e "            input_args: preset-rtsp-restream"
    echo -e "            roles:"
    echo -e "              - detect"
    echo -e "      detect:"
    echo -e "        width: ${SUB_WIDTH}"
    echo -e "        height: ${SUB_HEIGHT}"
    echo -e "        fps: ${SUB_FPS}"
    echo -e "      record:"
    echo -e "        enabled: true"
    echo -e "      objects:"
    echo -e "        track:"
    echo -e "          - bird${NC}"
else
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
    echo -e "${BOLD}📋 Frigate Configuration — Option C (Frigate's bundled go2rtc):${NC}"
    echo -e "  ${YELLOW}# Add this stream to Frigate's go2rtc config section."
    echo -e "  # No need to run standalone go2rtc on the Pi — Frigate handles it."
    echo -e "  go2rtc:"
    echo -e "    streams:"
    echo -e "      birdcam:"
    echo -e "        - rtsp://${PI_IP}:${RTSP_PORT}/${STREAM_NAME}"
    echo -e "    webrtc:"
    echo -e "      candidates:"
    echo -e "        - stun:8555"
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
fi
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
