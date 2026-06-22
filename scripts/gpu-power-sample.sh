#!/bin/bash
# GPU Power Monitor — samples GPU power every 5 minutes via crontab
# Stores to /home_ai/logs/gpu-power.log, also writes summary to syslog
# Must run as root to access /sys/class/drm/card0/device/hwmon/

set -euo pipefail

LOG="/home_ai/logs/gpu-power.log"
TIMESTAMP=$(date -Iseconds)

# Collect GPU metrics
GPU_POWER=$(cat /sys/class/drm/card0/device/hwmon/hwmon*/power1_average 2>/dev/null | head -1)
GPU_CAP=$(cat /sys/class/drm/card0/device/hwmon/hwmon*/power1_cap 2>/dev/null | head -1)
GPU_TEMP=$(cat /sys/class/drm/card0/device/hwmon/hwmon*/temp1_input 2>/dev/null | head -1)
GPU_VRAM=$(cat /sys/class/drm/card0/device/mem_info_vram_used 2>/dev/null | head -1)

# Convert to human-readable
[ -n "$GPU_POWER" ] && POWER_W=$((GPU_POWER / 1000000)) || POWER_W=0
[ -n "$GPU_CAP" ] && CAP_W=$((GPU_CAP / 1000000)) || CAP_W=0
[ -n "$GPU_TEMP" ] && TEMP_C=$((GPU_TEMP / 1000)) || TEMP_C=0
[ -n "$GPU_VRAM" ] && VRAM_MB=$((GPU_VRAM / 1048576)) || VRAM_MB=0

# Log to file (machine-readable)
echo "${TIMESTAMP} power=${POWER_W}W cap=${CAP_W}W temp=${TEMP_C}C vram=${VRAM_MB}MB" >> "$LOG"

# Write summary to syslog if power is high (>100W)
if [ "$POWER_W" -gt 100 ]; then
    logger -t gpu-power "GPU drawing ${POWER_W}W (${TEMP_C}°C, ${VRAM_MB}MB VRAM)"
fi

# Rotate log if >10MB
if [ -f "$LOG" ] && [ "$(stat -c%s "$LOG" 2>/dev/null || echo 0)" -gt 10485760 ]; then
    mv "$LOG" "${LOG}.old"
fi

# Also write power used since last boot summary every 6 hours
HOUR=$(date +%H)
if [ "$HOUR" = "00" ] || [ "$HOUR" = "06" ] || [ "$HOUR" = "12" ] || [ "$HOUR" = "18" ]; then
    logger -t gpu-power "6-hour summary: current=${POWER_W}W, cap=${CAP_W}W, temp=${TEMP_C}°C, vram=${VRAM_MB}MB"
fi
