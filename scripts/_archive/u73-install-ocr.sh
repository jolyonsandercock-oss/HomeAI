#!/usr/bin/env bash
# u73-install-ocr.sh — install brscan5 SANE driver + OCR watcher service.
# Idempotent. Run as root.
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Run as root: sudo bash $0"; exit 1
fi

DEB=/tmp/brscan5-1.6.2-0.amd64.deb
SVC_SRC=/home_ai/scripts/u73-ocr-watcher.service
SVC_DST=/etc/systemd/system/scan-ocr-watcher.service

echo "Step 1/5 — install brscan5 SANE driver"
if dpkg -s brscan5 >/dev/null 2>&1; then
    echo "  • brscan5 already installed ($(dpkg -s brscan5 | awk '/^Version:/{print $2}'))"
else
    [[ -f "$DEB" ]] || { echo "✗ $DEB missing — re-download"; exit 1; }
    dpkg -i "$DEB"
    echo "  ✓ brscan5 installed"
fi

echo
echo "Step 2/5 — register the network scanner at 192.168.1.75"
if brsaneconfig5 -q 2>/dev/null | grep -q '^[0-9]* ADS-2800W'; then
    echo "  • ADS-2800W already registered"
else
    brsaneconfig5 -a name=ADS-2800W model=ADS-2800W ip=192.168.1.75
    echo "  ✓ ADS-2800W registered"
fi
brsaneconfig5 -q 2>/dev/null | grep -E 'ADS-2800W' || true

echo
echo "Step 3/5 — install ocrmypdf + tesseract + inotify-tools"
if command -v ocrmypdf >/dev/null && command -v inotifywait >/dev/null; then
    echo "  • already installed: $(ocrmypdf --version 2>/dev/null | head -1)"
else
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        ocrmypdf tesseract-ocr tesseract-ocr-eng inotify-tools
    echo "  ✓ installed ocrmypdf $(ocrmypdf --version | head -1)"
fi

echo
echo "Step 4/5 — install + enable the watcher service"
install -m 0755 /home_ai/scripts/u73-ocr-watcher.sh /home_ai/scripts/u73-ocr-watcher.sh
install -m 0644 "$SVC_SRC" "$SVC_DST"
mkdir -p /tmp/u73-ocr-locks && chown scanner:scanner /tmp/u73-ocr-locks
systemctl daemon-reload
systemctl enable --now scan-ocr-watcher.service
sleep 2
if systemctl is-active --quiet scan-ocr-watcher; then
    echo "  ✓ scan-ocr-watcher running"
else
    echo "  ✗ service failed to start — run: journalctl -u scan-ocr-watcher -n 30"
    exit 1
fi

echo
echo "Step 5/5 — verify"
echo "  brscan5: $(brsaneconfig5 -q 2>/dev/null | grep ADS-2800W || echo 'none')"
echo "  watcher: $(systemctl is-active scan-ocr-watcher)"
echo "  inbox:   $(ls -la /mnt/shared_storage/scans/inbox | head -3)"
echo
echo "════════════════════════════════════════════════════════════════"
echo "Drop a PDF into the share to test:"
echo "  echo > /tmp/blank.pdf  &&  cp some.pdf /mnt/shared_storage/scans/inbox/"
echo "Watcher logs:"
echo "  journalctl -u scan-ocr-watcher -f"
echo "════════════════════════════════════════════════════════════════"
