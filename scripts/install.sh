#!/usr/bin/env bash
set -Eeuo pipefail

log() {
  printf '\n==> %s\n' "$*"
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

if [[ "${EUID}" -ne 0 ]]; then
  exec sudo -E bash "$0" "$@"
fi

TARGET_USER="${SUDO_USER:-}"
[[ -n "${TARGET_USER}" && "${TARGET_USER}" != "root" ]] || \
  die "Run this script as a regular user: sudo ./scripts/install.sh"

TARGET_HOME="$(getent passwd "${TARGET_USER}" | cut -d: -f6)"
[[ -n "${TARGET_HOME}" && -d "${TARGET_HOME}" ]] || die "Cannot find home directory for ${TARGET_USER}"

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_FILE="${PROJECT_DIR}/compose.yaml"
[[ -f "${COMPOSE_FILE}" ]] || die "Missing ${COMPOSE_FILE}"

LAN_CIDR="${LAN_CIDR:-192.168.1.0/24}"
PUID="$(id -u "${TARGET_USER}")"
PGID="$(id -g "${TARGET_USER}")"

source /etc/os-release
[[ "${ID:-}" == "ubuntu" ]] || die "This installer supports Ubuntu only"
[[ "${VERSION_ID:-}" == "24.04" ]] || die "This installer targets Ubuntu 24.04 LTS"

log "Installing base packages"
apt-get update
apt-get install -y ca-certificates curl gnupg git openssh-server samba ufw

log "Installing Docker Engine and Compose plugin"
for package in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
  apt-get remove -y "${package}" >/dev/null 2>&1 || true
done

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

DOCKER_CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME}}"
printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu %s stable\n' \
  "$(dpkg --print-architecture)" "${DOCKER_CODENAME}" \
  > /etc/apt/sources.list.d/docker.list

apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker
usermod -aG docker "${TARGET_USER}"

log "Creating storage directories"
STORAGE_DIRS=(
  /srv/homeserver/appdata
  /srv/homeserver/storage/media/movies
  /srv/homeserver/storage/media/series
  /srv/homeserver/storage/media/anime
  /srv/homeserver/storage/downloads/complete
  /srv/homeserver/storage/downloads/incomplete
  /srv/homeserver/storage/shared/files
  /srv/homeserver/storage/shared/photos
  /srv/homeserver/storage/shared/memes
  /srv/homeserver/storage/backups
  /srv/homeserver/appdata/jellyfin/config
  /srv/homeserver/appdata/jellyfin/cache
  /srv/homeserver/appdata/qbittorrent
)
for directory in "${STORAGE_DIRS[@]}"; do
  install -d -o "${TARGET_USER}" -g "${TARGET_USER}" -m 0775 "${directory}"
done

log "Configuring headless power behavior"
install -d -m 0755 /etc/systemd/logind.conf.d /etc/systemd/sleep.conf.d
printf '%s\n' \
  '[Login]' \
  'HandleLidSwitch=ignore' \
  'HandleLidSwitchExternalPower=ignore' \
  'HandleLidSwitchDocked=ignore' \
  'IdleAction=ignore' \
  > /etc/systemd/logind.conf.d/90-server-lid.conf
printf '%s\n' \
  '[Sleep]' \
  'AllowSuspend=no' \
  'AllowHibernation=no' \
  'AllowHybridSleep=no' \
  'AllowSuspendThenHibernate=no' \
  > /etc/systemd/sleep.conf.d/90-server.conf

DEFAULT_IFACE="$(ip route show default 2>/dev/null | awk 'NR==1 {print $5}')"
if command -v nmcli >/dev/null 2>&1 && [[ "${DEFAULT_IFACE}" != wl* ]]; then
  nmcli radio wifi off || true
fi

log "Configuring Samba"
SMB_CONF=/etc/samba/smb.conf
cp -a "${SMB_CONF}" "${SMB_CONF}.bak.$(date +%Y%m%d%H%M%S)"
if ! grep -Eq '^[[:space:]]*netbios name[[:space:]]*=' "${SMB_CONF}"; then
  sed -i '/^\[global\]$/a\   netbios name = MOONSERVER' "${SMB_CONF}"
fi
if ! grep -q '^\[storage\]$' "${SMB_CONF}"; then
  cat >> "${SMB_CONF}" <<EOF

[storage]
   comment = Moonserver storage
   path = /srv/homeserver/storage
   browseable = yes
   read only = no
   valid users = ${TARGET_USER}
   force user = ${TARGET_USER}
   create mask = 0660
   directory mask = 0770
EOF
fi

if ! pdbedit -L 2>/dev/null | grep -q "^${TARGET_USER}:"; then
  echo "Set the Samba password for ${TARGET_USER}."
  smbpasswd -a "${TARGET_USER}"
fi
smbpasswd -e "${TARGET_USER}" >/dev/null
testparm -s >/dev/null
systemctl enable --now smbd
systemctl restart smbd

log "Configuring firewall"
ufw allow from "${LAN_CIDR}" to any port 22 proto tcp
ufw allow from "${LAN_CIDR}" to any port 445 proto tcp
ufw allow from "${LAN_CIDR}" to any port 8096 proto tcp
ufw allow from "${LAN_CIDR}" to any port 8080 proto tcp
ufw --force enable

log "Creating the local Compose environment"
if [[ ! -f "${PROJECT_DIR}/.env" ]]; then
  printf 'PUID=%s\nPGID=%s\nTZ=Europe/Moscow\n' "${PUID}" "${PGID}" > "${PROJECT_DIR}/.env"
  chown "${TARGET_USER}:${TARGET_USER}" "${PROJECT_DIR}/.env"
  chmod 0600 "${PROJECT_DIR}/.env"
fi

docker compose -f "${COMPOSE_FILE}" --project-directory "${PROJECT_DIR}" config --quiet
docker compose -f "${COMPOSE_FILE}" --project-directory "${PROJECT_DIR}" pull
docker compose -f "${COMPOSE_FILE}" --project-directory "${PROJECT_DIR}" up -d

log "Installation complete"
echo "Project: ${PROJECT_DIR}"
echo "Jellyfin: http://<server-ip>:8096"
echo "qBittorrent: http://<server-ip>:8080"
echo "Samba: \\\\<server-ip>\\storage"
echo "Run 'docker compose ps' after starting a new shell session."
echo "A reboot is recommended to apply lid and group changes."
