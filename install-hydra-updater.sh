sudo bash <<'EOF'
set -euo pipefail

echo "==> Installing required packages"
dnf install -y curl jq libnotify util-linux systemd

install -d -m 0755 /usr/local/libexec
install -d -m 0755 /var/cache/hydra-rpm-updater
install -d -m 0755 /var/lib/hydra-rpm-updater

cat >/usr/local/libexec/hydra-rpm-updater <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

REPO="hydralauncher/hydra"
PKG_NAME="hydralauncher"
ASSET_REGEX='^hydralauncher-.*\.x86_64\.rpm$'
CACHE_DIR="/var/cache/hydra-rpm-updater"
STATE_DIR="/var/lib/hydra-rpm-updater"
GITHUB_API="https://api.github.com/repos/${REPO}/releases/latest"
PENDING_NOTIFY_FILE="${STATE_DIR}/pending-notify"
TMP_JSON="$(mktemp)"
trap 'rm -f "$TMP_JSON"' EXIT

log() {
  echo "[hydra-rpm-updater] $*"
  logger -t hydra-rpm-updater -- "$*"
}

need() {
  command -v "$1" >/dev/null 2>&1 || {
    log "Missing required command: $1"
    exit 1
  }
}

find_active_gui_user() {
  local session active type name uid state
  while read -r session _; do
    [[ -n "${session:-}" ]] || continue
    active="$(loginctl show-session "$session" -p Active --value 2>/dev/null || true)"
    type="$(loginctl show-session "$session" -p Type --value 2>/dev/null || true)"
    name="$(loginctl show-session "$session" -p Name --value 2>/dev/null || true)"
    uid="$(loginctl show-session "$session" -p User --value 2>/dev/null || true)"
    state="$(loginctl show-session "$session" -p State --value 2>/dev/null || true)"

    if [[ "$active" == "yes" && "$state" == "active" && ( "$type" == "wayland" || "$type" == "x11" ) && -n "$name" && -n "$uid" ]]; then
      printf "%s:%s\n" "$name" "$uid"
      return 0
    fi
  done < <(loginctl list-sessions --no-legend 2>/dev/null)

  return 1
}

send_notification_now() {
  local title="$1" body="$2"
  local user_info name uid runtime bus

  need runuser
  need loginctl
  need notify-send

  user_info="$(find_active_gui_user || true)"
  if [[ -z "${user_info:-}" ]]; then
    log "No active GUI session found; notification deferred"
    return 1
  fi

  name="${user_info%%:*}"
  uid="${user_info##*:}"
  runtime="/run/user/$uid"
  bus="unix:path=${runtime}/bus"

  if [[ ! -S "${runtime}/bus" ]]; then
    log "GUI session detected for ${name} (${uid}) but session bus is missing; notification deferred"
    return 1
  fi

  log "Attempting notification for ${name} (${uid})"
  if runuser -u "$name" -- env \
      DBUS_SESSION_BUS_ADDRESS="$bus" \
      XDG_RUNTIME_DIR="$runtime" \
      notify-send "$title" "$body"; then
    log "Notification sent successfully to ${name} (${uid})"
    return 0
  fi

  log "Notification attempt failed for ${name} (${uid}); deferred"
  return 1
}

queue_notification() {
  local title="$1" body="$2"
  printf '%s\n%s\n' "$title" "$body" >"$PENDING_NOTIFY_FILE"
  chmod 0644 "$PENDING_NOTIFY_FILE"
  log "Queued notification for later delivery"
}

flush_pending_notification() {
  local title body
  [[ -f "$PENDING_NOTIFY_FILE" ]] || return 0
  mapfile -t _msg <"$PENDING_NOTIFY_FILE"
  title="${_msg[0]:-Hydra Launcher}"
  body="${_msg[1]:-Wykryto aktualizację}"
  log "Pending notification exists; trying delivery"
  if send_notification_now "$title" "$body"; then
    rm -f "$PENDING_NOTIFY_FILE"
    log "Pending notification delivered and cleared"
  else
    log "Pending notification still waiting for available GUI session"
  fi
}

need curl
need jq
need dnf
need rpm
need loginctl
need logger

install -d -m 0755 "$CACHE_DIR" "$STATE_DIR"

flush_pending_notification

INSTALLED_VERSION="$(rpm -q --qf '%{VERSION}\n' "$PKG_NAME" 2>/dev/null || echo "0")"
log "Installed version: ${INSTALLED_VERSION}"

log "Fetching latest release metadata from GitHub"
curl -fsSL -H "Accept: application/vnd.github+json" "$GITHUB_API" -o "$TMP_JSON"

LATEST_TAG="$(jq -r '.tag_name // empty' "$TMP_JSON")"
LATEST_VERSION="${LATEST_TAG#v}"

if [[ -z "$LATEST_VERSION" ]]; then
  log "Could not determine latest version from GitHub"
  exit 1
fi

RPM_URL="$(jq -r --arg re "$ASSET_REGEX" '.assets[]? | select(.name | test($re)) | .browser_download_url' "$TMP_JSON" | head -n1)"
RPM_NAME="$(jq -r --arg re "$ASSET_REGEX" '.assets[]? | select(.name | test($re)) | .name' "$TMP_JSON" | head -n1)"

if [[ -z "${RPM_URL:-}" || "$RPM_URL" == "null" ]]; then
  log "No RPM asset matching ${ASSET_REGEX} found in latest release"
  exit 1
fi

if [[ -z "${RPM_NAME:-}" || "$RPM_NAME" == "null" ]]; then
  RPM_NAME="hydralauncher-${LATEST_VERSION}.x86_64.rpm"
fi

log "Latest upstream version: ${LATEST_VERSION}"

if [[ "$LATEST_VERSION" == "$INSTALLED_VERSION" ]]; then
  log "Hydra Launcher is already up to date (${INSTALLED_VERSION})"
  exit 0
fi

RPM_FILE="${CACHE_DIR}/${RPM_NAME}"
log "Downloading ${RPM_NAME}"
curl -fL --retry 3 --retry-delay 5 "$RPM_URL" -o "$RPM_FILE"

if [[ "$INSTALLED_VERSION" == "0" ]]; then
  log "Installing Hydra Launcher ${LATEST_VERSION}"
  dnf install -y "$RPM_FILE"
  echo "$LATEST_VERSION" > "${STATE_DIR}/last-version"
  TITLE="Hydra Launcher"
  BODY="Zainstalowano wersję ${LATEST_VERSION}"
  log "Hydra Launcher installed: ${LATEST_VERSION}"
else
  log "Updating Hydra Launcher ${INSTALLED_VERSION} -> ${LATEST_VERSION}"
  dnf install -y "$RPM_FILE"
  echo "$LATEST_VERSION" > "${STATE_DIR}/last-version"
  TITLE="Hydra Launcher"
  BODY="Zaktualizowano z ${INSTALLED_VERSION} do ${LATEST_VERSION}"
  log "Hydra Launcher updated to ${LATEST_VERSION}"
fi

if send_notification_now "$TITLE" "$BODY"; then
  log "Notification confirmed for current update/install event"
else
  queue_notification "$TITLE" "$BODY"
  log "Notification was not sent immediately; it is queued and will be retried on the next timer run"
fi
SCRIPT

chmod 0755 /usr/local/libexec/hydra-rpm-updater

cat >/etc/systemd/system/hydra-rpm-updater.service <<'UNIT'
[Unit]
Description=Hydra Launcher RPM updater
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/libexec/hydra-rpm-updater
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
UNIT

cat >/etc/systemd/system/hydra-rpm-updater.timer <<'UNIT'
[Unit]
Description=Run Hydra Launcher RPM updater periodically

[Timer]
OnBootSec=5min
OnUnitActiveSec=6h
RandomizedDelaySec=15min
Persistent=true
Unit=hydra-rpm-updater.service

[Install]
WantedBy=timers.target
UNIT

systemctl daemon-reload
systemctl enable --now hydra-rpm-updater.timer
systemctl start hydra-rpm-updater.service || true

echo
echo "==> Timer status"
systemctl status hydra-rpm-updater.timer --no-pager || true
echo
echo "==> Service status"
systemctl status hydra-rpm-updater.service --no-pager || true
echo
echo "==> Recent logs"
journalctl -u hydra-rpm-updater.service -n 50 --no-pager || true
EOF
