# minecraft-server

Purpur Minecraft server for Raspberry Pi 4 (Fedora 44, ARM64), with Bedrock Edition support via GeyserMC. Runs as a rootful Podman container managed by systemd via Quadlet, set up to auto-start on boot and self-update daily.

## Stack

| Component | Role |
|---|---|
| [itzg/minecraft-server](https://github.com/itzg/docker-minecraft-server) | Container image — handles Purpur download, plugin installation, JVM flags |
| [Purpur](https://purpurmc.org) | Server JAR — Paper fork with extra performance and configuration options |
| [GeyserMC](https://geysermc.org) | Bedrock ↔ Java protocol bridge (UDP 19132) |
| [Floodgate](https://geysermc.org/wiki/floodgate/) | Bedrock player auth — no Java Edition account required |
| [Spark](https://spark.lucko.me) | In-game CPU/GC profiler |
| [Chunky](https://hangar.papermc.io/pop4959/Chunky) | Chunk pre-generator — run once at setup |
| Podman + Quadlet | Rootful container → native systemd service |

## Requirements

- Raspberry Pi 4 (4 GB or 8 GB)
- Fedora 44 (aarch64)
- USB 3.0 SSD (SD cards will not survive the write load)
- Active cooling — the server will sustain ~80°C without a heatsink fan

## Deployment

Copy this repository to the Pi, then run the four phases in order as root.

### Phase 1 — System preparation

```bash
sudo bash scripts/01-system-setup.sh
```

- Updates Fedora via `dnf5`
- Installs `podman` and `yq`
- Creates install directory at `/opt/minecraft` (override with `MINECRAFT_DIR` env var)
- Opens TCP 25565 and UDP 19132 in firewalld
- Enables `podman-auto-update.timer`

### Phase 2 — Deploy and first start

```bash
sudo bash scripts/02-deploy.sh
```

- Installs `systemd/minecraft.container` as a Quadlet unit
- Pre-pulls `docker.io/itzg/minecraft-server:java21`
- Enables and starts `minecraft.service`

Watch startup (first run downloads Purpur and all plugins — allow 2–4 minutes):

```bash
journalctl -fu minecraft.service
```

Wait for `Done (Xs)! For help, type "help"` before continuing.

### Phase 3 — Apply performance optimisations

```bash
sudo bash scripts/03-apply-configs.sh
```

Stops the server, patches the following files using `yq`, then restarts:

| File | Key changes |
|---|---|
| `config/paper-world-defaults.yml` | Reduce spawn limits, lower auto-save chunk rate, disable anti-xray |
| `spigot.yml` | Reduce entity activation ranges, nerf spawner mobs, faster item despawn |
| `purpur.yml` | Disable TPS catchup, alternate keepalive, lobotomise stuck villagers |
| `plugins/Geyser-Spigot/config.yml` | Set `auth-type: floodgate` |

### Phase 4 — Chunk pre-generation

```bash
sudo bash scripts/04-pregen.sh 3000     # 3000-block radius (adjust to your world size)
```

Runs Chunky against the overworld and nether while the server stays online. Check progress:

```bash
sudo bash scripts/04-pregen.sh --status
```

Pre-generation takes 30–90 minutes on the RPi4. Set a world border once done to prevent future chunk generation lag:

```bash
sudo podman exec minecraft rcon-cli worldborder set 6000
```

## Configuration

### Memory

Edit `systemd/minecraft.container` before deploying:

```ini
# 4 GB RPi4
Environment=MEMORY=3G

# 8 GB RPi4
Environment=MEMORY=6G
```

### Plugins

Edit `plugins.txt`. Each line is a JAR URL downloaded by the container at startup. Commented-out entries are ignored.

### Server properties

Server properties are managed as environment variables in `systemd/minecraft.container` (the `itzg` image applies them at startup):

```ini
Environment=VIEW_DISTANCE=6
Environment=SIMULATION_DISTANCE=4
Environment=MAX_PLAYERS=20
```

## Management

| Task | Command |
|---|---|
| Status | `systemctl status minecraft.service` |
| Live logs | `journalctl -fu minecraft.service` |
| Server console | `sudo podman exec -it minecraft rcon-cli` |
| Stop | `systemctl stop minecraft.service` |
| Restart | `systemctl restart minecraft.service` |
| Force image update | `sudo podman auto-update` |
| Pre-gen status | `sudo bash scripts/04-pregen.sh --status` |
| Backup now | `sudo bash scripts/backup.sh` |

### Diagnosing lag with Spark

```
/spark profiler start
# wait 60 seconds during lag
/spark profiler stop
```

Spark opens a flamegraph URL showing which methods are consuming CPU time. Real-time TPS and GC stats:

```
/spark tps
/spark health --memory
```

## Backups

`scripts/backup.sh` rsyncs world directories and plugin configs (including the Floodgate `key.pem`) to `<MINECRAFT_DIR>/backups/` (default `/opt/minecraft/backups`), retaining 7 days.

Install as a daily cron job:

```bash
sudo cp scripts/backup.sh /etc/cron.daily/minecraft-backup
sudo chmod +x /etc/cron.daily/minecraft-backup
```

> **Important:** back up the Floodgate `key.pem` separately and keep a copy off-device. It is required to migrate the server — Bedrock players are identified by it.

## Auto-updates

The Quadlet unit sets `AutoUpdate=registry`. The `podman-auto-update.timer` (enabled in Phase 1) pulls the latest `itzg/minecraft-server:java21` digest daily and restarts the service if the image changed.

To pin to a specific Minecraft version and prevent unattended game updates, set `VERSION=1.21.4` in `minecraft.container` instead of `VERSION=LATEST`.

## Ports

| Port | Protocol | Purpose |
|---|---|---|
| 25565 | TCP | Java Edition clients |
| 19132 | UDP | Bedrock Edition clients (GeyserMC) |

## Directory layout on the Pi

```
/opt/minecraft/                ← default; override with MINECRAFT_DIR env var
├── data/                      ← container /data mount
│   ├── plugins.txt
│   ├── plugins/
│   │   ├── Geyser-Spigot/
│   │   │   └── config.yml
│   │   └── floodgate/
│   │       └── key.pem        ← back this up off-device
│   ├── world/
│   ├── world_nether/
│   ├── world_the_end/
│   ├── config/
│   │   └── paper-world-defaults.yml
│   ├── spigot.yml
│   └── purpur.yml
└── backups/                   ← daily rsync backups (7-day rotation)

/etc/containers/systemd/
└── minecraft.container        ← Quadlet unit
```
