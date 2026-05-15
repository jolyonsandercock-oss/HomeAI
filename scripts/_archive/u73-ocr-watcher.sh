#!/usr/bin/env bash
# u73-ocr-watcher.sh — OCR every PDF dropped into the scans SMB inbox.
# Runs as the `scanner` Samba user under systemd. Re-running ocrmypdf on
# an already-OCR'd file is a no-op (--skip-text).
set -euo pipefail

INBOX=/mnt/shared_storage/scans/inbox
LOCK_DIR=/tmp/u73-ocr-locks
mkdir -p "$LOCK_DIR"

log() { printf '%s u73-ocr %s\n' "$(date -Iseconds)" "$*"; }

ocr_one() {
    local f="$1"
    [[ -f "$f" ]]      || return 0
    [[ "$f" == *.pdf ]] || return 0
    [[ "$f" == *.tmp.pdf ]] && return 0

    # Wait for SMB to finish writing (file size stable for 2s).
    local prev=-1 size
    for _ in 1 2 3 4 5; do
        size=$(stat -c %s "$f" 2>/dev/null || echo 0)
        [[ "$size" -gt 0 && "$size" == "$prev" ]] && break
        prev=$size; sleep 2
    done

    local base; base=$(basename "$f")
    local lock="$LOCK_DIR/${base}.lock"
    (
        flock -n 9 || { log "skip (locked): $base"; exit 0; }
        local tmp="${f%.pdf}.ocr.tmp.pdf"
        log "ocr start: $base ($size bytes)"
        if ocrmypdf --skip-text --optimize 1 --rotate-pages --deskew \
                    --output-type pdf --quiet "$f" "$tmp" 2>>/tmp/u73-ocr-errors.log; then
            mv -f "$tmp" "$f"
            log "ocr done:  $base"
        else
            rm -f "$tmp"
            log "ocr FAIL: $base — see /tmp/u73-ocr-errors.log"
        fi
    ) 9>"$lock"
}

log "watcher start, inbox=$INBOX"

# Catch-up: process anything already sitting in the inbox.
shopt -s nullglob
for f in "$INBOX"/*.pdf; do ocr_one "$f"; done

# Stream new arrivals.
exec inotifywait -m -e close_write,moved_to --format '%w%f' "$INBOX" |
while IFS= read -r path; do
    ocr_one "$path"
done
