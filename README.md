# Necesse Dedicated Server LXC for Proxmox — one-command install

Spin up a Proxmox LXC running a [Necesse](https://necessegame.com/) dedicated
server with a single pasted command. An interactive wizard handles container
creation, Java, SteamCMD, the server install, and your world/slots/port/password.

## Usage

Paste into the **Proxmox node shell** (as root):

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/blake165/necesse-lxc-creator/main/proxmox-create-necesse-lxc.sh)"
```

The wizard asks for container settings, then Necesse settings, then:

- downloads the Debian 12 LXC template (if missing)
- creates + starts an unprivileged container (autostart on boot)
- installs Java + SteamCMD (via the proper **apt package**, not the finicky
  tarball — this avoids the permission headaches the raw tarball causes in LXC)
- downloads the Necesse server (Steam app `1169370`, anonymous) as a non-root
  `necesse` user
- creates a systemd service so the server survives reboots
- prints the connect IP/port when done

First boot generates the world — watch with
`pct exec <CTID> -- journalctl -u necesse -f`.

## Settings the wizard sets

| Prompt | Default | Notes |
|---|---|---|
| Container ID | `150` | unused (FiveM 110, MC 130, PZ 140 — no clash) |
| Hostname | `necesse` | |
| CPU cores | `2` | Necesse is light |
| Memory | `4096` MB | plenty for a small group |
| Disk | `20` GB | |
| Network | `dhcp` | or static `IP/CIDR` + gateway |
| Container root password | — | prompted, hidden |
| SSH root login | `yes` | for uploading mod .jars |
| World name | `world` | created on first boot |
| Max players | `10` | |
| Game UDP port | `14159` | |
| MOTD / server name | `A Necesse server` | |
| Join password | none | optional, prompted |

### Scripted install

```bash
NONINTERACTIVE=1 \
CTID=151 NEC_WORLD=knox NEC_SLOTS=8 NEC_PORT=14159 \
CT_ROOT_PASSWORD='root-pass' NEC_PASSWORD='join-pass' \
bash -c "$(curl -fsSL https://raw.githubusercontent.com/blake165/necesse-lxc-creator/main/proxmox-create-necesse-lxc.sh)"
```

## Connecting

In-game: **Multiplayer → Join** → enter the container's IP and port `14159`.

## Ports

Forward `14159/udp` on your router to the container IP (Necesse is **UDP**).
Set a DHCP reservation (or static IP) so the address stays put.

## Mods

**Important:** Necesse Workshop mods can only be auto-downloaded with a Steam
account that *owns* Necesse and is *not* Steam Guard protected. This installer
deliberately does **not** bake Steam credentials into a script. Instead, use the
manual .jar method (no credentials, works for every mod):

1. Get the mod's `.jar` — subscribe to it in your own Necesse client, then copy
   the `.jar` out of your client's mods folder, or grab it from the mod's
   Discord/forum page.
2. Upload the `.jar` to `/home/necesse/.config/Necesse/mods/` (use SSH/WinSCP).
3. Restart: `pct exec <CTID> -- systemctl restart necesse`

The server loads any `.jar` in that folder on start.

## Config & saves

- Server config: `/home/necesse/necesse-server/` (and the systemd service args)
- World saves: `/home/necesse/.config/Necesse/saves/`

Edit the systemd `ExecStart` flags or the in-folder config, then
`pct exec <CTID> -- systemctl restart necesse`.

## Updating the server

```bash
pct exec <CTID> -- bash /root/necesse-lxc-setup.sh
```
Re-runs SteamCMD (updates server files) and restarts the service.

## Why SteamCMD works cleanly here

This installer uses Debian's `steamcmd` apt package (from contrib/non-free)
rather than extracting Valve's tarball by hand. The apt package installs to
`/usr/games/steamcmd` with correct ownership and permissions, sidestepping the
"permission denied" / UID-ownership problems the raw tarball hits inside
unprivileged LXC containers.
