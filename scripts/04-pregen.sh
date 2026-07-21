#!/usr/bin/env bash
# Phase 4 — Chunk pre-generation with Chunky
#
# Run after the server is online and players are connected at least once
# (so the world seed is finalised). Pre-generation eliminates the largest
# source of in-game lag on the RPi4.
#
# Usage:
#   sudo bash scripts/04-pregen.sh           # default 3000-block radius
#   sudo bash scripts/04-pregen.sh 5000      # custom radius
#
# The server stays online during pre-generation. Expect ~30–90 minutes
# depending on radius. Monitor progress with: /chunky progress in-game
# or via: sudo bash scripts/04-pregen.sh --status
# ---------------------------------------------------------------------------
set -euo pipefail

source "$(dirname "$0")/config.env"

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
die()   { echo -e "\033[1;31m[FAIL]\033[0m  $*" >&2; exit 1; }

rcon() {
    podman exec "$CONTAINER_NAME" rcon-cli "$@"
}

# ── Status check shortcut ───────────────────────────────────────────────────
if [[ "${1:-}" == "--status" ]]; then
    info "Chunk pre-generation status:"
    rcon chunky progress
    exit 0
fi

if [[ "${1:-}" == "--cancel" ]]; then
    info "Cancelling chunk pre-generation..."
    rcon chunky cancel
    ok "Cancelled"
    exit 0
fi

RADIUS=${1:-3000}

# Validate the container is running
if ! podman inspect --format '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null | grep -q running; then
    die "Container '$CONTAINER_NAME' is not running. Start with: systemctl start minecraft.service"
fi

# Confirm Chunky is loaded
if ! rcon chunky 2>&1 | grep -qi "chunky"; then
    die "Chunky plugin does not appear to be loaded. Check plugins are installed."
fi

info "Starting chunk pre-generation with radius $RADIUS blocks..."
info "This generates all chunks within ${RADIUS}m of world spawn in all three dimensions."
echo ""

# Pre-generate the overworld, nether, and end
rcon chunky world world
rcon chunky radius "$RADIUS"
rcon chunky start
ok "Overworld pre-generation started"

# Nether pre-generation at scaled radius (nether is 1:8 scale)
NETHER_RADIUS=$(( RADIUS / 8 ))
rcon chunky world world_nether
rcon chunky radius "$NETHER_RADIUS"
rcon chunky start
ok "Nether pre-generation started (radius $NETHER_RADIUS)"

echo ""
echo "──────────────────────────────────────────────────────────────"
ok "Pre-generation running in the background."
echo ""
echo "  Check progress (any of these):"
echo "    sudo bash scripts/04-pregen.sh --status"
echo "    podman exec $CONTAINER_NAME rcon-cli chunky progress"
echo "    In-game: /chunky progress"
echo ""
echo "  Cancel if needed:"
echo "    sudo bash scripts/04-pregen.sh --cancel"
echo ""
echo "  Optionally set a world border at the pre-generated radius"
echo "  to prevent new chunk generation lag in the future:"
echo "    podman exec $CONTAINER_NAME rcon-cli worldborder set $(( RADIUS * 2 ))"
echo "──────────────────────────────────────────────────────────────"
