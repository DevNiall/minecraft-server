#!/usr/bin/env bash
# Daily backup script — worlds + critical plugin configs
#
# Install as a cron job (run as root):
#   sudo cp scripts/backup.sh /etc/cron.daily/minecraft-backup
#   sudo chmod +x /etc/cron.daily/minecraft-backup
#
# Or run manually: sudo bash scripts/backup.sh
#
# Retains 7 days of backups. Keeps the server online (Minecraft saves
# continuously). Uses rsync --delete to keep backups lean.
# ---------------------------------------------------------------------------
set -euo pipefail

# Resolve paths relative to this script when sourcing config.env
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.env"

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }

TIMESTAMP=$(date +%Y%m%d)
DEST="$BACKUP_DIR/$TIMESTAMP"

mkdir -p "$DEST"

# ── Flush world to disk before backup ────────────────────────────────────────
# 'save-all flush' waits for pending chunk writes to complete before continuing
if podman inspect --format '{{.State.Status}}' minecraft 2>/dev/null | grep -q running; then
    info "Flushing world to disk..."
    podman exec minecraft rcon-cli save-all flush 2>/dev/null || warn "save-all flush failed (RCON may not be configured)"
fi

# ── Sync world directories ────────────────────────────────────────────────────
for WORLD in world world_nether world_the_end; do
    SRC="$DATA_DIR/$WORLD"
    if [[ -d "$SRC" ]]; then
        info "Backing up $WORLD → $DEST/$WORLD"
        rsync -a --delete "$SRC/" "$DEST/$WORLD/"
        ok "$WORLD backed up"
    else
        warn "$SRC not found, skipping"
    fi
done

# ── Sync plugin configs (Floodgate key.pem is here — back it up) ─────────────
info "Backing up plugin configs..."
rsync -a --delete \
    --exclude='*.jar' \
    --exclude='cache/' \
    "$DATA_DIR/plugins/" "$DEST/plugins/"
ok "Plugin configs backed up (includes Floodgate key.pem)"

# ── Backup top-level config files ────────────────────────────────────────────
for CONF in server.properties spigot.yml purpur.yml bukkit.yml; do
    [[ -f "$DATA_DIR/$CONF" ]] && cp "$DATA_DIR/$CONF" "$DEST/"
done
[[ -d "$DATA_DIR/config" ]] && rsync -a "$DATA_DIR/config/" "$DEST/config/"
ok "Server config files backed up"

# ── Rotate — remove backups older than 7 days ────────────────────────────────
info "Rotating backups (keeping last 7 days)..."
find "$BACKUP_DIR" -maxdepth 1 -type d -name '20??????' -mtime +7 -exec rm -rf {} + 2>/dev/null || true

REMAINING=$(find "$BACKUP_DIR" -maxdepth 1 -type d -name '20??????' | wc -l)
ok "Backup complete: $DEST ($REMAINING day(s) retained)"
