#!/usr/bin/env bash
set -Eeuo pipefail
umask 022

# One-file installer + runtime updater for Fedora / dnf-based systems.
# Public source: https://github.com/krissuu7/hydra-rpm-updater-installer
SELF_URL="https://raw.githubusercontent.com/krissuu7/hydra-rpm-updater-installer/main/install-hydra-updater.sh"
SELF_PATH="/usr/local/libexec/hydra-rpm-updater"
REPO="hydralauncher/hydra"
PKG_NAME="hydralauncher"
ASSET_REGEX='^hydralauncher-.*\.x86_64\.rpm$'
CACHE_DIR="/var/cache/hydra-rpm-updater"
STATE_DIR="/var/lib/hydra-rpm-updater"
GITHUB_API="https://api.github.com/repos/${REPO}/releases/latest"
PENDING_NOTIFY_FILE="${STATE_DIR}/pending-notify"

log() {
  printf '[hydra-rpm-updater] %s\n' "$*"
  logger -t hydra-rpm-updater -- "$*" 2>/dev/null || true
}
need() {
  command -v "$1" >/dev/null 2>&1 || { log "Brak wymaganego polecenia: $1"; exit 1; }
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
    if [[ "$active" == "yes" && "$state" == "active" &&
          ( "$type" == "wayland" || "$type" == "x11" ) &&
          -n "$name" && -n "$uid" ]]; then
      printf '%s:%s\n' "$name" "$uid"
      return 0
    fi
  done < <(loginctl list-sessions --no-legend 2>/dev/null)
  return 1
}

send_notification_now() {
  local title="$1" body="$2" user_info name uid runtime bus
  user_info="$(find_active_gui_user || true)"
  [[ -n "${user_info:-}" ]] || { log "Brak aktywnej sesji graficznej; powiadomienie odroczone"; return 1; }
  name="${user_info%%:*}"
  uid="${user_info##*:}"
  runtime="/run/user/$uid"
  bus="unix:path=${runtime}/bus"
  [[ -S "${runtime}/bus" ]] || { log "Brak magistrali D-Bus sesji; powiadomienie odroczone"; return 1; }
  if runuser -u "$name" -- env \
      DBUS_SESSION_BUS_ADDRESS="$bus" \
      XDG_RUNTIME_DIR="$runtime" \
      notify-send "$title" "$body"; then
    log "Wysłano powiadomienie do ${name}"
    return 0
  fi
  log "Nie udało się wysłać powiadomienia; zostanie ponowione"
  return 1
}

queue_notification() {
  printf '%s\n%s\n' "$1" "$2" >"$PENDING_NOTIFY_FILE"
  chmod 0644 "$PENDING_NOTIFY_FILE"
  log "Powiadomienie zapisano do późniejszego wysłania"
}

flush_pending_notification() {
  local title body
  [[ -f "$PENDING_NOTIFY_FILE" ]] || return 0
  local -a msg=()
  mapfile -t msg <"$PENDING_NOTIFY_FILE"
  title="${msg[0]:-Hydra Launcher}"
  body="${msg[1]:-Wykryto aktualizację}"
  if send_notification_now "$title" "$body"; then
    rm -f "$PENDING_NOTIFY_FILE"
    log "Wysłano zaległe powiadomienie"
  fi
}

install_updater() {
  if [[ "$EUID" -ne 0 ]]; then
    echo "Uruchom instalator przez sudo, np. curl ... | sudo bash" >&2
    exit 1
  fi
  if ! command -v dnf >/dev/null 2>&1; then
    echo "Ten skrypt wymaga Fedory lub dystrybucji korzystającej z dnf." >&2
    exit 1
  fi

  echo "==> Instalowanie wymaganych pakietów"
  dnf install -y curl jq libnotify util-linux systemd

  install -d -m 0755 /usr/local/libexec "$CACHE_DIR" "$STATE_DIR"
  local tmp
  tmp="$(mktemp)"
  trap 'rm -f "${tmp:-}"' EXIT

  echo "==> Pobieranie skryptu do instalacji"
  curl -fsSL --retry 3 --retry-delay 2 "$SELF_URL" -o "$tmp"
  bash -n "$tmp"
  install -o root -g root -m 0755 "$tmp" "$SELF_PATH"
  rm -f "$tmp"
  trap - EXIT

  cat >/etc/systemd/system/hydra-rpm-updater.service <<'HYDRA_SERVICE'
[Unit]
Description=Hydra Launcher RPM updater
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/libexec/hydra-rpm-updater --run
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
HYDRA_SERVICE

  cat >/etc/systemd/system/hydra-rpm-updater.timer <<'HYDRA_TIMER'
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
HYDRA_TIMER

  systemctl daemon-reload
  systemctl enable --now hydra-rpm-updater.timer

  echo
  echo "==> Uruchamianie pierwszego sprawdzenia aktualizacji"
  systemctl start hydra-rpm-updater.service
  echo
  echo "==> Status timera"
  systemctl status hydra-rpm-updater.timer --no-pager || true
  echo
  echo "==> Ostatnie logi"
  journalctl -u hydra-rpm-updater.service -n 30 --no-pager || true
}

run_updater() {
  if [[ "$EUID" -ne 0 ]]; then
    echo "Tryb aktualizatora musi działać jako root." >&2
    exit 1
  fi
  for cmd in curl jq dnf rpm loginctl runuser notify-send cmp bash; do need "$cmd"; done
  install -d -m 0755 "$CACHE_DIR" "$STATE_DIR"

  local tmp_self tmp_json tmp_rpm installed_version latest_tag latest_version rpm_url rpm_name title body
  tmp_self="$(mktemp "${SELF_PATH}.XXXXXX")"
  tmp_json="$(mktemp)"
  tmp_rpm=""
  cleanup_runtime() {
    rm -f "${tmp_self:-}" "${tmp_json:-}"
    [[ -z "${tmp_rpm:-}" ]] || rm -f "$tmp_rpm"
  }
  trap cleanup_runtime EXIT

  # Update this same script from GitHub. Check syntax before replacing it.
  if curl -fsSL --connect-timeout 15 --max-time 60 "$SELF_URL" -o "$tmp_self" &&
     bash -n "$tmp_self"; then
    if ! cmp -s "$tmp_self" "$SELF_PATH"; then
      chmod 0755 "$tmp_self"
      chown root:root "$tmp_self"
      mv -f "$tmp_self" "$SELF_PATH"
      tmp_self=""
      log "Kod aktualizatora zmienił się na GitHubie; uruchamiam nową wersję"
      trap - EXIT
      rm -f "$tmp_json"
      exec "$SELF_PATH" --run
    fi
  else
    log "Nie udało się pobrać lub sprawdzić kodu aktualizatora; używam lokalnej wersji"
  fi
  rm -f "$tmp_self"
  tmp_self=""

  flush_pending_notification

  installed_version="$(rpm -q --qf '%{VERSION}\n' "$PKG_NAME" 2>/dev/null || echo "0")"
  log "Zainstalowana wersja Hydry: ${installed_version}"

  curl -fsSL --retry 3 --retry-delay 3 \
    -H "Accept: application/vnd.github+json" "$GITHUB_API" -o "$tmp_json"
  latest_tag="$(jq -r '.tag_name // empty' "$tmp_json")"
  latest_version="${latest_tag#v}"
  [[ -n "$latest_version" ]] || { log "Nie udało się ustalić wersji najnowszego wydania"; exit 1; }

  rpm_url="$(jq -r --arg re "$ASSET_REGEX" '.assets[]? | select(.name | test($re)) | .browser_download_url' "$tmp_json" | head -n1)"
  rpm_name="$(jq -r --arg re "$ASSET_REGEX" '.assets[]? | select(.name | test($re)) | .name' "$tmp_json" | head -n1)"
  [[ -n "$rpm_url" && "$rpm_url" != "null" ]] || { log "W najnowszym wydaniu nie znaleziono pasującego pakietu x86_64 RPM"; exit 1; }
  [[ -n "$rpm_name" && "$rpm_name" != "null" ]] || rpm_name="hydralauncher-${latest_version}.x86_64.rpm"

  log "Najnowsza wersja Hydry: ${latest_version}"
  if [[ "$latest_version" == "$installed_version" ]]; then
    log "Hydra Launcher jest aktualna (${installed_version})"
    exit 0
  fi

  # A single temporary RPM; the EXIT trap removes it after dnf finishes, on success or failure.
  tmp_rpm="$(mktemp "${CACHE_DIR}/hydra-update.XXXXXX.rpm")"
  log "Pobieranie ${rpm_name}"
  curl -fL --retry 3 --retry-delay 5 "$rpm_url" -o "$tmp_rpm"
  rpm -qp "$tmp_rpm" >/dev/null

  if [[ "$installed_version" == "0" ]]; then
    log "Instalowanie Hydra Launcher ${latest_version}"
    dnf install -y "$tmp_rpm"
    title="Hydra Launcher"
    body="Zainstalowano wersję ${latest_version}"
  else
    log "Aktualizowanie Hydra Launcher ${installed_version} -> ${latest_version}"
    dnf install -y "$tmp_rpm"
    title="Hydra Launcher"
    body="Zaktualizowano z ${installed_version} do ${latest_version}"
  fi

  printf '%s\n' "$latest_version" >"${STATE_DIR}/last-version.tmp"
  mv -f "${STATE_DIR}/last-version.tmp" "${STATE_DIR}/last-version"
  log "Hydra Launcher została pomyślnie zainstalowana/zaktualizowana do ${latest_version}"

  if send_notification_now "$title" "$body"; then
    log "Powiadomienie o udanej instalacji/aktualizacji zostało wysłane"
  else
    queue_notification "$title" "$body"
  fi
}

case "${1:-}" in
  --run)
    run_updater
    ;;
  --help|-h)
    cat <<'HELP'
Hydra RPM Updater

Instalacja:
  curl -fsSL https://raw.githubusercontent.com/krissuu7/hydra-rpm-updater-installer/main/install-hydra-updater.sh | sudo bash

Ręczne sprawdzenie:
  sudo systemctl start hydra-rpm-updater.service

Logi:
  journalctl -u hydra-rpm-updater.service -n 100 --no-pager
HELP
    ;;
  "")
    install_updater
    ;;
  *)
    echo "Nieznany argument: $1" >&2
    echo "Użyj --help, aby zobaczyć dostępne polecenia." >&2
    exit 2
    ;;
esac
