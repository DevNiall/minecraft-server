#!/usr/bin/env bash
# Phase 1 — Prepare Fedora 44 for Minecraft server
# Run once on the Raspberry Pi 4 as root:
#   sudo bash scripts/01-system-setup.sh
# ---------------------------------------------------------------------------
set -euo pipefail

source "$(dirname "$0")/config.env"

# ── Colour helpers ──────────────────────────────────────────────────────────
info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
die()   { echo -e "\033[1;31m[FAIL]\033[0m  $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "This script must be run as root (sudo bash $0)"

# ── 1. System update ────────────────────────────────────────────────────────
info "Updating system packages..."
dnf5 upgrade --refresh -y
ok "System updated"

# ── 2. Install required packages ────────────────────────────────────────────
info "Installing podman and yq..."
dnf5 install -y podman yq
ok "Packages installed"

# ── 3. Confirm cgroup v2 (required by Quadlet) ─────────────────────────────
CGROUP_VER=$(podman info --format '{{.Host.CgroupsVersion}}' 2>/dev/null || echo "unknown")
if [[ "$CGROUP_VER" != "2" ]]; then
    die "cgroup v2 is required but reported version is: $CGROUP_VER. " \
        "Fedora 44 should have cgroup v2 by default — check your boot parameters."
fi
ok "cgroup v2 confirmed"

# ── 4. Confirm zram swap ────────────────────────────────────────────────────
if ! zramctl | grep -q zram; then
    warn "No zram device found. Enabling zram-generator..."
    dnf5 install -y zram-generator
    cat > /etc/systemd/zram-generator.conf << 'EOF'
[zram0]
zram-size = 1024
compression-algorithm = zstd
EOF
    systemctl daemon-reload
    systemctl enable --now systemd-zram-setup@zram0.service
    ok "zram enabled (1 GB compressed swap)"
else
    ok "zram is active: $(zramctl | grep zram | awk '{print $1, $5}')"
fi

# ── 5. Mount USB SSD ─────────────────────────────────────────────────────────
info "Available block devices:"
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT | grep -v loop
echo ""

# Detect candidate SSD (USB storage, not the SD card — typically mmcblk0)
DETECTED=$(lsblk -rno NAME,TYPE,TRAN | awk '$2=="disk" && $3=="usb" {print "/dev/"$1}' | head -1)

if [[ -n "$DETECTED" ]]; then
    info "Detected USB drive: $DETECTED"
    read -rp "Use $DETECTED for Minecraft data? [Y/n] " CONFIRM
    CONFIRM=${CONFIRM:-Y}
    if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
        SSD_DEV="$DETECTED"
    else
        read -rp "Enter the device path (e.g. /dev/sda): " SSD_DEV
    fi
else
    read -rp "Enter the USB SSD device path (e.g. /dev/sda): " SSD_DEV
fi

[[ -b "$SSD_DEV" ]] || die "Device $SSD_DEV not found"

# Partition if needed
PARTITION="${SSD_DEV}1"
if ! lsblk "$PARTITION" &>/dev/null; then
    warn "No partition found on $SSD_DEV. Creating partition table and ext4 partition..."
    parted -s "$SSD_DEV" mklabel gpt
    parted -s "$SSD_DEV" mkpart primary ext4 0% 100%
    mkfs.ext4 -F "$PARTITION"
    ok "Formatted $PARTITION as ext4"
fi

if ! blkid "$PARTITION" | grep -q ext4; then
    warn "$PARTITION does not appear to be ext4. Formatting..."
    mkfs.ext4 -F "$PARTITION"
fi

UUID=$(blkid -s UUID -o value "$PARTITION")
[[ -n "$UUID" ]] || die "Could not determine UUID for $PARTITION"

# Mount point
mkdir -p /srv/minecraft
if ! mountpoint -q /srv/minecraft; then
    mount "$PARTITION" /srv/minecraft
fi

# Add to fstab if not already present
if ! grep -q "$UUID" /etc/fstab; then
    echo "UUID=$UUID  /srv/minecraft  ext4  defaults,noatime  0  2" >> /etc/fstab
    ok "Added $PARTITION (UUID=$UUID) to /etc/fstab with noatime"
else
    ok "/srv/minecraft already in fstab"
fi

# ── 6. Create directory structure ───────────────────────────────────────────
mkdir -p "$DATA_DIR"
mkdir -p "$BACKUP_DIR"
ok "Created $DATA_DIR and $BACKUP_DIR"

# ── 7. Firewall ─────────────────────────────────────────────────────────────
info "Configuring firewall..."
firewall-cmd --permanent --add-port=25565/tcp   # Java Edition
firewall-cmd --permanent --add-port=19132/udp   # Bedrock Edition (GeyserMC)
firewall-cmd --reload
ok "Firewall rules applied:"
firewall-cmd --list-ports

# ── 8. Enable podman-auto-update timer ─────────────────────────────────────
systemctl enable --now podman-auto-update.timer
ok "podman-auto-update timer enabled (checks for new image daily)"

echo ""
echo "──────────────────────────────────────────────────────────────"
ok "System setup complete. Next step:"
echo "   sudo bash scripts/02-deploy.sh"
echo "──────────────────────────────────────────────────────────────"
