#!/usr/bin/env bash
###############################################################################
# Necesse dedicated server setup for a Proxmox LXC container
#
# Runs INSIDE the container as root. Normally invoked by
# proxmox-create-necesse-lxc.sh, but safe to re-run to repair/update:
#   bash /root/necesse-lxc-setup.sh
#
# Installs Java + SteamCMD (via the proper apt package, not the finicky
# tarball), downloads Necesse (Steam app 1169370) as a non-root 'necesse'
# user, and creates a systemd service that autostarts with the container.
###############################################################################
set -euo pipefail

# Passed in by the host wizard (with fallbacks):
NEC_WORLD="${NEC_WORLD:-world}"
NEC_SLOTS="${NEC_SLOTS:-10}"
NEC_PASSWORD="${NEC_PASSWORD:-}"          # blank = open server
NEC_PORT="${NEC_PORT:-14159}"
NEC_MOTD="${NEC_MOTD:-A Necesse server}"

NECUSER="necesse"
NEC_HOME="/home/${NECUSER}"
NEC_DIR="${NEC_HOME}/necesse-server"
APPID="1169370"

if [[ $EUID -ne 0 ]]; then echo "Please run as root." >&2; exit 1; fi

echo "==> Installing base dependencies + Java..."
export DEBIAN_FRONTEND=noninteractive
dpkg --add-architecture i386
apt-get update -qq
apt-get install -y -qq locales curl wget ca-certificates software-properties-common \
  default-jre-headless lib32gcc-s1 >/dev/null
sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
locale-gen en_US.UTF-8 >/dev/null 2>&1 || true
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

# --- The PROPER SteamCMD install: the apt package, not the tarball ----------
# This avoids the UID-ownership / permission-denied mess the raw tarball causes
# in LXC containers. Requires Debian's non-free + contrib components.
echo "==> Enabling non-free repo and installing SteamCMD (apt package)..."
# Add contrib/non-free to the Debian sources if not already present
if ! grep -qE 'non-free' /etc/apt/sources.list /etc/apt/sources.list.d/* 2>/dev/null; then
  sed -i 's/^\(deb .*debian.org\/debian .* main\)$/\1 contrib non-free non-free-firmware/' /etc/apt/sources.list 2>/dev/null || true
  # Fallback for the newer deb822 format (Debian 12+)
  if [[ -f /etc/apt/sources.list.d/debian.sources ]]; then
    sed -i 's/^Components: .*/Components: main contrib non-free non-free-firmware/' /etc/apt/sources.list.d/debian.sources
  fi
fi
apt-get update -qq
# Pre-accept the Steam license so the install is non-interactive
echo steam steam/question select "I AGREE" | debconf-set-selections
echo steamcmd steam/question select "I AGREE" | debconf-set-selections
echo steam steam/license note '' | debconf-set-selections
apt-get install -y -qq steamcmd >/dev/null
STEAMCMD="/usr/games/steamcmd"
if [[ ! -x "${STEAMCMD}" ]]; then
  echo "steamcmd apt package did not install correctly." >&2
  echo "Check that contrib/non-free are enabled in apt sources." >&2
  exit 1
fi

echo "==> Creating service user '${NECUSER}'..."
id "${NECUSER}" &>/dev/null || useradd -m -d "${NEC_HOME}" -s /bin/bash "${NECUSER}"
mkdir -p "${NEC_DIR}"
chown -R "${NECUSER}:${NECUSER}" "${NEC_HOME}"

echo "==> Downloading Necesse server (app ${APPID})..."
# Run as the necesse user so the files are owned correctly from the start.
runuser -u "${NECUSER}" -- "${STEAMCMD}" \
  +force_install_dir "${NEC_DIR}" \
  +login anonymous \
  +app_update "${APPID}" validate \
  +quit

# Locate the server jar (name has been stable as Server.jar)
SERVER_JAR=""
for cand in "${NEC_DIR}/Server.jar" "${NEC_DIR}"/*.jar; do
  [[ -f "$cand" ]] && { SERVER_JAR="$cand"; break; }
done
if [[ -z "${SERVER_JAR}" ]]; then
  echo "Necesse Server.jar not found after install in ${NEC_DIR}." >&2
  echo "Check the steamcmd output above for errors." >&2
  exit 1
fi
echo "    Server jar: ${SERVER_JAR}"

# Mods directory (drop .jar mods here - see README for the no-credentials method)
MODS_DIR="${NEC_HOME}/.config/Necesse/mods"
runuser -u "${NECUSER}" -- mkdir -p "${MODS_DIR}"

echo "==> Creating systemd service..."
PASS_ARG=""
[[ -n "${NEC_PASSWORD}" ]] && PASS_ARG="-password ${NEC_PASSWORD}"
cat > /etc/systemd/system/necesse.service <<EOF
[Unit]
Description=Necesse Dedicated Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${NECUSER}
Group=${NECUSER}
WorkingDirectory=${NEC_DIR}
ExecStart=/usr/bin/java -jar ${SERVER_JAR##*/} -nogui -world "${NEC_WORLD}" -slots ${NEC_SLOTS} -port ${NEC_PORT} -motd "${NEC_MOTD}" ${PASS_ARG}
Restart=on-failure
RestartSec=10
Environment=LANG=en_US.UTF-8
Environment=LC_ALL=en_US.UTF-8

[Install]
WantedBy=multi-user.target
EOF

chown -R "${NECUSER}:${NECUSER}" "${NEC_HOME}"
systemctl daemon-reload
systemctl enable necesse.service >/dev/null
systemctl restart necesse.service

cat <<EOM

=============================================================================
 Necesse dedicated server setup complete!
=============================================================================
 World      : ${NEC_WORLD}   (created on first boot)
 Slots      : ${NEC_SLOTS}
 Password   : $([[ -n ${NEC_PASSWORD} ]] && echo "set (from wizard)" || echo "none (open server)")
 Port       : ${NEC_PORT}/udp

 Watch it come up (first boot creates the world):
   journalctl -u necesse -f
 Look for the server finishing world generation and listening.

 Connect in-game: Multiplayer -> Join -> <container-ip>:${NEC_PORT}

 Forward on your router for outside players: ${NEC_PORT}/udp (UDP only).
 Set a DHCP reservation so the container IP stays put.

 MODS (no Steam credentials needed):
   1. On the Necesse Workshop page, find your mod; download its .jar
      (from the Necesse Discord/forums or by subscribing in-game and copying
      the .jar out of your own client's mods folder).
   2. Upload the .jar to: ${MODS_DIR}
   3. Restart: systemctl restart necesse
   (Workshop auto-download requires a Steam account that OWNS Necesse and is
    NOT Steam Guard protected - so manual .jar drop is the safer path.)

 Server files: ${NEC_DIR}
 World saves : ${NEC_HOME}/.config/Necesse/saves
=============================================================================
EOM
