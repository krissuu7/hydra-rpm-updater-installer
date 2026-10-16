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
