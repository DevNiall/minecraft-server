#!/usr/bin/env bash
# Phase 1 — Prepare Fedora 44 for Minecraft server
# Run once on the Raspberry Pi 4 as root:
#   sudo bash scripts/01-system-setup.sh
# Override default install path (/opt/minecraft):
#   MINECRAFT_DIR=/data/minecraft sudo bash scripts/01-system-setup.sh
# ---------------------------------------------------------------------------
set -euo pipefail

source "$(dirname "$0")/config.env"

# ── Colour helpers ──────────────────────────────────────────────────────────
info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
die()   { echo -e "\033[1;31m[FAIL]\033[0m  $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "This script must be run as root (sudo bash $0)"

info "Install path: ${DATA_DIR}"
info "Backup path:  ${BACKUP_DIR}"
echo ""

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
if [[ "$CGROUP_VER" != "v2" ]]; then
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

# ── 5. Create install directory ─────────────────────────────────────────────
mkdir -p "$DATA_DIR"
mkdir -p "$BACKUP_DIR"
ok "Created $DATA_DIR"
ok "Created $BACKUP_DIR"

# ── 6. Firewall ─────────────────────────────────────────────────────────────
info "Configuring firewall..."
firewall-cmd --permanent --add-port=25565/tcp   # Java Edition
firewall-cmd --permanent --add-port=19132/udp   # Bedrock Edition (GeyserMC)
firewall-cmd --reload
ok "Firewall rules applied:"
firewall-cmd --list-ports

# ── 7. Enable podman-auto-update timer ─────────────────────────────────────
systemctl enable --now podman-auto-update.timer
ok "podman-auto-update timer enabled (checks for new image daily)"

echo ""
echo "──────────────────────────────────────────────────────────────"
ok "System setup complete. Next step:"
echo "   sudo bash scripts/02-deploy.sh"
echo "──────────────────────────────────────────────────────────────"
