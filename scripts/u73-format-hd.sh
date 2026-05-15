#!/usr/bin/env bash
# u73-format-hd.sh — wipe + ext4 the 6TB Seagate (ATA serial Z4D3LA1X)
# and mount it at /mnt/shared_storage. Destructive — the existing NTFS
# volume is destroyed. The disk currently contains only Windows housekeeping
# folders ($RECYCLE.BIN, System Volume Information).
#
# Refers to the disk by serial number rather than /dev/sdd so a future
# enumeration change can't aim this at the wrong device.

set -euo pipefail

DISK_BY_ID="/dev/disk/by-id/ata-ST6000VN0001-1SF17Z_Z4D3LA1X"
MOUNT_POINT="/mnt/shared_storage"
LABEL="HOMEAI_DATA"

# Resolve to the actual /dev/sdX path
DEV=$(readlink -f "$DISK_BY_ID")
echo "→ Target disk: $DEV (resolved from $DISK_BY_ID)"

# Sanity: must be ~6TB, must be the model we expect
SIZE_BYTES=$(blockdev --getsize64 "$DEV")
SIZE_TB=$(( SIZE_BYTES / 1000 / 1000 / 1000 / 1000 ))
[[ "$SIZE_TB" -ge 5 && "$SIZE_TB" -le 7 ]] || {
    echo "✗ Disk size $SIZE_TB TB outside expected 5-7 TB range — refusing"
    exit 1
}
MODEL=$(lsblk -dn -o MODEL "$DEV" | tr -d '[:space:]')
[[ "$MODEL" == "ST6000VN0001-1SF17Z" ]] || {
    echo "✗ Disk model '$MODEL' not the expected ST6000VN0001 — refusing"
    exit 1
}
echo "✓ Sanity checks passed (model=$MODEL, size=${SIZE_TB}TB)"

# Unmount any existing partitions
for part in "${DEV}1" "${DEV}2" "${DEV}3"; do
    if mount | grep -q "^$part "; then
        echo "→ Unmounting $part"
        umount "$part"
    fi
done

# Wipe filesystem signatures from each partition + the disk itself
for part in "${DEV}1" "${DEV}2" "${DEV}3"; do
    if [[ -b "$part" ]]; then
        echo "→ wipefs $part"
        wipefs -a "$part" || true
    fi
done
echo "→ wipefs $DEV (disk-level)"
wipefs -a "$DEV"

# Re-partition: single GPT partition spanning the whole disk
echo "→ sgdisk: single partition spanning whole disk"
sgdisk --zap-all "$DEV"
sgdisk --new=1:0:0 --typecode=1:8300 --change-name=1:"$LABEL" "$DEV"
partprobe "$DEV"
sleep 2

# Format ext4
PART="${DEV}1"
echo "→ mkfs.ext4 $PART (label=$LABEL)"
mkfs.ext4 -F -L "$LABEL" -m 0 "$PART"

# Mount
mkdir -p "$MOUNT_POINT"
mount "$PART" "$MOUNT_POINT"

# Persist in /etc/fstab by UUID
UUID=$(blkid -s UUID -o value "$PART")
sed -i "\|$MOUNT_POINT|d" /etc/fstab
echo "UUID=$UUID  $MOUNT_POINT  ext4  defaults,nofail  0  2" >> /etc/fstab
echo "✓ /etc/fstab updated"

# Create the scans inbox owned by uid 1000 (paperless container runs as 1000)
mkdir -p "$MOUNT_POINT/scans/inbox"
chown -R 1000:1000 "$MOUNT_POINT/scans"
chmod 0775 "$MOUNT_POINT/scans" "$MOUNT_POINT/scans/inbox"

echo
echo "✓ Done."
df -h "$MOUNT_POINT"
ls -la "$MOUNT_POINT"
