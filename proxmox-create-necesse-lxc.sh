#!/usr/bin/env bash
###############################################################################
# Necesse dedicated server LXC - automated provisioning for Proxmox
#
# One-liner from the Proxmox node shell (root):
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/blake165/necesse-lxc-creator/main/proxmox-create-necesse-lxc.sh)"
#
# Creates an LXC, installs Java + SteamCMD + the Necesse server inside it,
# sets it to autostart, and pre-seeds world name, slots, port, and password.
#
# Skip prompts: NONINTERACTIVE=1 CT_ROOT_PASSWORD=x bash -c "$(curl ...)"
###############################################################################
set -euo pipefail

# ----------------------------- configurable ---------------------------------
CTID="${CTID:-150}"
HOSTNAME="${HOSTNAME_CT:-necesse}"
CORES="${CORES:-2}"
MEMORY="${MEMORY:-4096}"                  # Necesse is light; 4GB is plenty
SWAP="${SWAP:-1024}"
DISK_GB="${DISK_GB:-20}"
STORAGE="${STORAGE:-local-lvm}"
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"
BRIDGE="${BRIDGE:-vmbr0}"

IP_CONFIG="${IP_CONFIG:-dhcp}"
GATEWAY="${GATEWAY:-}"

CT_ROOT_PASSWORD="${CT_ROOT_PASSWORD:-}"
ENABLE_SSH_ROOT="${ENABLE_SSH_ROOT:-1}"
NONINTERACTIVE="${NONINTERACTIVE:-0}"

# Necesse settings
NEC_WORLD="${NEC_WORLD:-world}"
NEC_SLOTS="${NEC_SLOTS:-10}"
NEC_PASSWORD="${NEC_PASSWORD:-}"
NEC_PORT="${NEC_PORT:-14159}"
NEC_MOTD="${NEC_MOTD:-A Necesse server}"

RAW_BASE="https://raw.githubusercontent.com/blake165/necesse-lxc-creator/main"
# -----------------------------------------------------------------------------

if [[ $EUID -ne 0 ]]; then echo "Run as root on the Proxmox host." >&2; exit 1; fi
if ! command -v pct &>/dev/null; then echo "pct not found - is this a Proxmox host?" >&2; exit 1; fi

LOCAL_SETUP="$(dirname "$(readlink -f "${BASH_SOURCE[0]:-$0}")" 2>/dev/null)/necesse-lxc-setup.sh"
if [[ -f "${LOCAL_SETUP}" ]]; then
  SETUP_SCRIPT="${LOCAL_SETUP}"
  echo "==> Using local necesse-lxc-setup.sh"
else
  SETUP_SCRIPT="$(mktemp /tmp/necesse-lxc-setup.XXXXXX.sh)"
  echo "==> Downloading necesse-lxc-setup.sh from ${RAW_BASE}..."
  if ! curl -fsSL -o "${SETUP_SCRIPT}" "${RAW_BASE}/necesse-lxc-setup.sh"; then
    echo "Failed to download necesse-lxc-setup.sh - check RAW_BASE in this script." >&2
    exit 1
  fi
fi

ask() { local q="$1" def="$2" ans; read -r -p "  ${q} [${def}]: " ans </dev/tty; echo "${ans:-$def}"; }

if [[ "${NONINTERACTIVE}" != "1" && -e /dev/tty ]]; then
  echo ""
  echo "============================================"
  echo "   Necesse LXC - interactive setup"
  echo "============================================"
  echo "Press Enter to accept the [default] value."
  echo ""

  while :; do
    CTID=$(ask "Container ID" "${CTID}")
    if ! [[ "${CTID}" =~ ^[0-9]+$ ]]; then echo "  ! Must be a number."
    elif pct status "${CTID}" &>/dev/null; then echo "  ! CTID ${CTID} is already in use, pick another."
    else break; fi
  done

  HOSTNAME=$(ask "Hostname" "${HOSTNAME}")
  CORES=$(ask "CPU cores" "${CORES}")
  MEMORY=$(ask "Container memory (MB)" "${MEMORY}")
  DISK_GB=$(ask "Disk size (GB)" "${DISK_GB}")
  STORAGE=$(ask "Storage for container disk" "${STORAGE}")
  BRIDGE=$(ask "Network bridge" "${BRIDGE}")

  NET_CHOICE=$(ask "Network: dhcp or static?" "$([[ ${IP_CONFIG} == dhcp ]] && echo dhcp || echo static)")
  if [[ "${NET_CHOICE}" == "static" ]]; then
    while :; do
      IP_CONFIG=$(ask "Static IP with CIDR (e.g. 192.168.1.80/24)" "$([[ ${IP_CONFIG} == dhcp ]] && echo '' || echo "${IP_CONFIG}")")
      [[ "${IP_CONFIG}" =~ ^[0-9.]+/[0-9]+$ ]] && break
      echo "  ! Format must be IP/prefix, e.g. 192.168.1.80/24"
    done
    while :; do
      GATEWAY=$(ask "Gateway (e.g. 192.168.1.1)" "${GATEWAY}")
      [[ -n "${GATEWAY}" ]] && break
      echo "  ! Gateway is required for a static IP."
    done
  else
    IP_CONFIG="dhcp"; GATEWAY=""
  fi

  if [[ -z "${CT_ROOT_PASSWORD}" ]]; then
    while :; do
      read -r -s -p "  Container root password: " PW1 </dev/tty; echo
      read -r -s -p "  Confirm password: " PW2 </dev/tty; echo
      if [[ -z "${PW1}" ]]; then echo "  ! Password cannot be empty."
      elif [[ "${PW1}" != "${PW2}" ]]; then echo "  ! Passwords do not match, try again."
      else CT_ROOT_PASSWORD="${PW1}"; break; fi
    done
  fi

  SSH_CHOICE=$(ask "Enable SSH root login (for uploading mods)? (yes/no)" "yes")
  [[ "${SSH_CHOICE}" =~ ^[Yy] ]] && ENABLE_SSH_ROOT=1 || ENABLE_SSH_ROOT=0

  echo ""
  echo "  -- Necesse settings --"
  NEC_WORLD=$(ask "World name" "${NEC_WORLD}")
  NEC_SLOTS=$(ask "Max players (slots)" "${NEC_SLOTS}")
  NEC_PORT=$(ask "Game UDP port" "${NEC_PORT}")
  NEC_MOTD=$(ask "Server MOTD / name" "${NEC_MOTD}")
  PW_CHOICE=$(ask "Set a join password? (yes/no)" "no")
  if [[ "${PW_CHOICE}" =~ ^[Yy] ]]; then
    while :; do
      read -r -s -p "  Server join password: " SP1 </dev/tty; echo
      read -r -s -p "  Confirm: " SP2 </dev/tty; echo
      if [[ "${SP1}" != "${SP2}" ]]; then echo "  ! Passwords do not match."
      else NEC_PASSWORD="${SP1}"; break; fi
    done
  fi

  echo ""
  echo "--------------------------------------------"
  echo "  CTID      : ${CTID}"
  echo "  Hostname  : ${HOSTNAME}"
  echo "  Cores/RAM : ${CORES} / ${MEMORY} MB"
  echo "  Disk      : ${DISK_GB} GB on ${STORAGE}"
  echo "  Network   : ${BRIDGE}, ${IP_CONFIG}${GATEWAY:+ gw ${GATEWAY}}"
  echo "  World     : ${NEC_WORLD} (${NEC_SLOTS} slots, UDP ${NEC_PORT})"
  echo "  Password  : $([[ -n ${NEC_PASSWORD} ]] && echo set || echo none)"
  echo "--------------------------------------------"
  CONFIRM=$(ask "Create this container? (yes/no)" "yes")
  [[ "${CONFIRM}" =~ ^[Yy] ]] || { echo "Aborted."; exit 0; }
  echo ""
else
  if [[ -z "${CT_ROOT_PASSWORD}" ]]; then
    echo "Non-interactive mode: set CT_ROOT_PASSWORD env var." >&2; exit 1
  fi
fi

if pct status "${CTID}" &>/dev/null; then
  echo "CTID ${CTID} already exists. Pick a free ID." >&2; exit 1
fi

echo "==> Checking for Debian 12 template..."
pveam update >/dev/null
TEMPLATE=$(pveam list "${TEMPLATE_STORAGE}" 2>/dev/null | awk '/debian-12-standard/ {print $1; exit}')
if [[ -z "${TEMPLATE}" ]]; then
  TEMPLATE_NAME=$(pveam available --section system | awk '/debian-12-standard/ {print $2; exit}')
  [[ -z "${TEMPLATE_NAME}" ]] && { echo "No debian-12-standard template available." >&2; exit 1; }
  echo "    Downloading ${TEMPLATE_NAME}..."
  pveam download "${TEMPLATE_STORAGE}" "${TEMPLATE_NAME}"
  TEMPLATE="${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE_NAME}"
fi
echo "    Using template: ${TEMPLATE}"

NET0="name=eth0,bridge=${BRIDGE},ip=${IP_CONFIG}"
if [[ "${IP_CONFIG}" != "dhcp" ]]; then
  [[ -z "${GATEWAY}" ]] && { echo "Static IP set but GATEWAY is empty." >&2; exit 1; }
  NET0+=",gw=${GATEWAY}"
fi

echo "==> Creating container ${CTID} (${HOSTNAME})..."
pct create "${CTID}" "${TEMPLATE}" \
  --hostname "${HOSTNAME}" \
  --cores "${CORES}" \
  --memory "${MEMORY}" \
  --swap "${SWAP}" \
  --rootfs "${STORAGE}:${DISK_GB}" \
  --net0 "${NET0}" \
  --unprivileged 1 \
  --features nesting=1 \
  --password "${CT_ROOT_PASSWORD}" \
  --onboot 1

echo "==> Starting container..."
pct start "${CTID}"

echo "==> Waiting for network inside the container..."
for i in $(seq 1 30); do
  pct exec "${CTID}" -- ping -c1 -W2 deb.debian.org &>/dev/null && break
  sleep 2
  [[ $i -eq 30 ]] && { echo "Container never got network access." >&2; exit 1; }
done

if [[ "${ENABLE_SSH_ROOT}" == "1" ]]; then
  echo "==> Enabling SSH root login..."
  pct exec "${CTID}" -- bash -c "
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq && apt-get install -y -qq openssh-server >/dev/null
    mkdir -p /etc/ssh/sshd_config.d
    printf 'PermitRootLogin yes\nPasswordAuthentication yes\n' > /etc/ssh/sshd_config.d/99-nec-root.conf
    systemctl enable ssh >/dev/null 2>&1 || true
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
  "
fi

echo "==> Pushing and running Necesse setup script..."
pct push "${CTID}" "${SETUP_SCRIPT}" /root/necesse-lxc-setup.sh
pct exec "${CTID}" -- env \
  NEC_WORLD="${NEC_WORLD}" \
  NEC_SLOTS="${NEC_SLOTS}" \
  NEC_PASSWORD="${NEC_PASSWORD}" \
  NEC_PORT="${NEC_PORT}" \
  NEC_MOTD="${NEC_MOTD}" \
  bash /root/necesse-lxc-setup.sh

CT_IP=$(pct exec "${CTID}" -- hostname -I | awk '{print $1}')

cat <<EOM

=============================================================================
 Container ${CTID} provisioned successfully!
=============================================================================
 Necesse server : ${CT_IP}:${NEC_PORT}  (Multiplayer -> Join in-game)
 Root login     : 'pct enter ${CTID}' or console
EOM
[[ "${ENABLE_SSH_ROOT}" == "1" ]] && echo " SSH            : ssh root@${CT_IP}  (password you chose in the wizard)"
cat <<EOM

 Watch first boot (world generation):
   pct exec ${CTID} -- journalctl -u necesse -f

 Forward on your router for outside players: ${NEC_PORT}/udp (UDP only).
 Set a DHCP reservation so ${CT_IP} doesn't change.

 Mods: drop .jar files in /home/necesse/.config/Necesse/mods then
   pct exec ${CTID} -- systemctl restart necesse
=============================================================================
EOM
