#!/bin/bash
set -euxo pipefail

# Exit early if already complete
if mountpoint -q /mnt/nvme_raid; then
    echo "✅ NVMe RAID setup already completed (mounted at /mnt/nvme_raid). Skipping."
    exit 0
fi

# Install required tools
if command -v yum &> /dev/null; then
    yum install -y mdadm xfsprogs util-linux
else
    apt-get update
    apt-get install -y mdadm xfsprogs util-linux
fi

# === Discover all usable unmounted NVMe instance store volumes ===
nvme_all=()
while read -r name; do
    # Skip devices with mounted partitions
    if lsblk -no MOUNTPOINT "/dev/$name" | grep -qv '^$'; then
        continue
    fi
    nvme_all+=("/dev/$name")
done < <(lsblk -dno NAME | grep '^nvme')

num_nvme=${#nvme_all[@]}
echo "🔍 Found $num_nvme usable unmounted NVMe disk(s): ${nvme_all[*]}"

# === Behavior by count ===
if [ "$num_nvme" -eq 0 ]; then
    echo "ℹ️ No usable NVMe instance store devices. Exiting cleanly."
    exit 0

elif [ "$num_nvme" -eq 1 ]; then
    echo "🔧 One NVMe device found. Using it directly."
    RAID_DEVICE="${nvme_all[0]}"

elif [ "$num_nvme" -ge 2 ]; then
    echo "⚙️  Two or more NVMe devices found. Using first two in RAID 0."
    nvme_devices=( "${nvme_all[@]:0:2}" )
    mdadm --create --verbose /dev/md0 --level=0 --raid-devices=2 "${nvme_devices[@]}" --force --run
    sleep 3
    RAID_DEVICE="/dev/md0"
else
    echo "❌ Unexpected condition."
    exit 1
fi

# === Format the selected device or RAID ===
mkfs.xfs -f "$RAID_DEVICE"

# === Mount and set up bind mounts ===
mkdir -p /mnt/nvme_raid
mount "$RAID_DEVICE" /mnt/nvme_raid

mkdir -p /mnt/nvme_raid/home /mnt/nvme_raid/tmp
chmod 1777 /mnt/nvme_raid/tmp

rsync -aXS /home/ /mnt/nvme_raid/home/ || true
rsync -aXS /tmp/ /mnt/nvme_raid/tmp/ || true

mount --bind /mnt/nvme_raid/home /home
mount --bind /mnt/nvme_raid/tmp /tmp

# === Make persistent in fstab ===
echo "$RAID_DEVICE /mnt/nvme_raid xfs defaults,nofail 0 0" >> /etc/fstab
echo "/mnt/nvme_raid/home /home none bind 0 0" >> /etc/fstab
echo "/mnt/nvme_raid/tmp  /tmp  none bind 0 0" >> /etc/fstab

echo "✅ /home and /tmp mounted from: $RAID_DEVICE"
