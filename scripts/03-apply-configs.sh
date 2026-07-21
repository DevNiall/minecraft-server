#!/usr/bin/env bash
# Phase 3 — Apply performance optimisations and configure GeyserMC + Floodgate
#
# Run AFTER the server has started at least once (configs must exist).
# The server is stopped, patched, then restarted.
#
#   sudo bash scripts/03-apply-configs.sh
# ---------------------------------------------------------------------------
set -euo pipefail

source "$(dirname "$0")/config.env"

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
die()   { echo -e "\033[1;31m[FAIL]\033[0m  $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "This script must be run as root (sudo bash $0)"

# Verify first-run config files exist before proceeding
REQUIRED_CONFIGS=(
    "$DATA_DIR/config/paper-world-defaults.yml"
    "$DATA_DIR/spigot.yml"
    "$DATA_DIR/purpur.yml"
    "$DATA_DIR/plugins/Geyser-Spigot/config.yml"
)

MISSING=0
for f in "${REQUIRED_CONFIGS[@]}"; do
    if [[ ! -f "$f" ]]; then
        warn "Missing (server has not run yet?): $f"
        MISSING=$((MISSING + 1))
    fi
done

if [[ $MISSING -gt 0 ]]; then
    die "$MISSING config file(s) not found. Start the server with:\n" \
        "  systemctl start minecraft.service\n" \
        "Wait for 'Done!' in logs, then re-run this script."
fi

# ── Stop the server ─────────────────────────────────────────────────────────
info "Stopping server for configuration..."
systemctl stop minecraft.service
ok "Server stopped"

# ── Backup existing configs ─────────────────────────────────────────────────
BACKUP_TS=$(date +%Y%m%d-%H%M%S)
CONFIG_BACKUP="$BACKUP_DIR/config-backup-$BACKUP_TS"
mkdir -p "$CONFIG_BACKUP"
cp "$DATA_DIR/config/paper-world-defaults.yml" "$CONFIG_BACKUP/"
cp "$DATA_DIR/spigot.yml" "$CONFIG_BACKUP/"
cp "$DATA_DIR/purpur.yml" "$CONFIG_BACKUP/"
cp "$DATA_DIR/plugins/Geyser-Spigot/config.yml" "$CONFIG_BACKUP/"
ok "Config backup saved to $CONFIG_BACKUP"

# ── Helper: apply yq patch with error reporting ─────────────────────────────
patch_yaml() {
    local expr="$1"
    local file="$2"
    if yq -i "$expr" "$file" 2>/dev/null; then
        ok "  patched: $expr"
    else
        warn "  yq failed for: $expr on $file (key may not exist in this version)"
    fi
}

# ── paper-world-defaults.yml ────────────────────────────────────────────────
PAPER_WORLD="$DATA_DIR/config/paper-world-defaults.yml"
info "Patching $PAPER_WORLD ..."

# Chunk I/O — critical for SSD longevity on RPi4 (default 24 causes write spikes)
patch_yaml '.chunks."max-auto-save-chunks-per-tick" = 6'            "$PAPER_WORLD"
patch_yaml '.chunks."delay-chunk-unloads-by" = "10s"'               "$PAPER_WORLD"

# Entity performance
patch_yaml '.entities."per-player-mob-spawns" = true'               "$PAPER_WORLD"
patch_yaml '.entities."max-entity-collisions" = 2'                  "$PAPER_WORLD"

# Mob spawn limits — reduce from 70/10 defaults for RPi4 load
patch_yaml '.entities.spawning."spawn-limits".monster = 25'         "$PAPER_WORLD"
patch_yaml '.entities.spawning."spawn-limits".creature = 8'         "$PAPER_WORLD"
patch_yaml '.entities.spawning."spawn-limits".ambient = 5'          "$PAPER_WORLD"

# Spawn check frequency — every 4 ticks instead of every tick
patch_yaml '.entities.spawning."ticks-per-spawn".monster = 4'       "$PAPER_WORLD"

# Anti-xray off (significant CPU cost; re-enable if needed)
patch_yaml '.anticheat."anti-xray".enabled = false'                 "$PAPER_WORLD"

ok "paper-world-defaults.yml patched"

# ── spigot.yml ──────────────────────────────────────────────────────────────
SPIGOT_YML="$DATA_DIR/spigot.yml"
info "Patching $SPIGOT_YML ..."

# Entity activation ranges — animals/monsters only run full AI near players
patch_yaml '.world-settings.default."entity-activation-range".animals = 16'   "$SPIGOT_YML"
patch_yaml '.world-settings.default."entity-activation-range".monsters = 24'  "$SPIGOT_YML"
patch_yaml '.world-settings.default."entity-activation-range".misc = 12'      "$SPIGOT_YML"
patch_yaml '.world-settings.default."entity-activation-range".villagers = 24' "$SPIGOT_YML"

# Spawn range — mobs spawn closer, fewer wasted attempts in empty chunks
patch_yaml '.world-settings.default."mob-spawn-range" = 4'          "$SPIGOT_YML"

# Spawner mobs with no AI — massive CPU win on farms (no pathfinding)
patch_yaml '.world-settings.default."nerf-spawner-mobs" = true'     "$SPIGOT_YML"

# Item cleanup — despawn dropped items at 2.5 min instead of 5 min
patch_yaml '.world-settings.default."item-despawn-rate" = 3000'     "$SPIGOT_YML"

# Merge nearby drops and XP orbs
patch_yaml '.world-settings.default."merge-radius".item = 4.0'      "$SPIGOT_YML"
patch_yaml '.world-settings.default."merge-radius".exp = 6.0'       "$SPIGOT_YML"

# Reduce disk writes — only save user cache on shutdown
patch_yaml '.settings."save-user-cache-on-stop-only" = true'        "$SPIGOT_YML"

ok "spigot.yml patched"

# ── purpur.yml ──────────────────────────────────────────────────────────────
PURPUR_YML="$DATA_DIR/purpur.yml"
info "Patching $PURPUR_YML ..."

# IMPORTANT for ARM: disables TPS overcorrection after lag spikes.
# Without this, the server tries to "catch up" by cramming extra ticks,
# which causes cascading CPU bursts on the RPi4's limited cores.
patch_yaml '.settings."tps-catchup" = false'                        "$PURPUR_YML"

# Alternate keepalive — more tolerant of dropped packets on home networks.
# Sends keepalive every 1s; kicks after 30s of silence (not one missed packet).
patch_yaml '.settings."use-alternate-keepalive" = true'             "$PURPUR_YML"

# Lobotomise villagers stuck behind walls or unable to pathfind.
# Single biggest performance win in village-heavy worlds.
patch_yaml '.world-settings.default.mobs.villager.lobotomize.enabled = true'       "$PURPUR_YML"
patch_yaml '.world-settings.default.mobs.villager.lobotomize."check-interval" = 100' "$PURPUR_YML"

# Stop ticking entities around AFK players
patch_yaml '.world-settings.default."gameplay-mechanics".player."idle-timeout"."tick-nearby-entities" = false' "$PURPUR_YML"

ok "purpur.yml patched"

# ── GeyserMC config.yml ─────────────────────────────────────────────────────
GEYSER_CFG="$DATA_DIR/plugins/Geyser-Spigot/config.yml"
info "Patching $GEYSER_CFG ..."

# auth-type: floodgate — Floodgate handles Bedrock player authentication.
# Bedrock players can join without a Java Edition account.
# GeyserMC auto-detects Floodgate's key.pem from the adjacent plugin directory.
patch_yaml '.remote."auth-type" = "floodgate"' "$GEYSER_CFG"

# remote.address: auto — Geyser detects it is co-located and connects internally.
# Confirm it is set to "auto" (should be default when running as a plugin).
patch_yaml '.remote.address = "auto"' "$GEYSER_CFG"

ok "Geyser-Spigot/config.yml patched"

# ── Restart server ──────────────────────────────────────────────────────────
info "Starting server with new configuration..."
systemctl start minecraft.service

echo ""
echo "──────────────────────────────────────────────────────────────"
ok "Configuration applied and server restarted."
echo ""
echo "  Watch startup:"
echo "    journalctl -fu minecraft.service"
echo ""
echo "  Verify GeyserMC loaded on UDP 19132:"
echo "    journalctl -u minecraft.service | grep -i geyser"
echo ""
echo "  Once players can connect, pre-generate chunks to eliminate"
echo "  future exploration lag (takes 30–90 min on RPi4):"
echo "    sudo bash scripts/04-pregen.sh 3000"
echo "──────────────────────────────────────────────────────────────"
