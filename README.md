# Hydra RPM Updater Installer

Jednoplikowy instalator i aktualizator **Hydra Launcher** dla Fedory i kompatybilnych dystrybucji opartych na `dnf`.

Repozytorium: https://github.com/krissuu7/hydra-rpm-updater-installer

## Instalacja

Wklej tę komendę do terminala:

```bash
curl -fsSL https://raw.githubusercontent.com/krissuu7/hydra-rpm-updater-installer/main/install-hydra-updater.sh | sudo bash
```

Skrypt poprosi o hasło `sudo` (jeśli wymagane), zainstaluje zależności, zapisze aktualizator i skonfiguruje timer systemd. Nie trzeba pobierać repozytorium ani ręcznie tworzyć osobnych plików.

## Jak działa

- Skrypt z tego repozytorium jest jednocześnie instalatorem i właściwym aktualizatorem.
- Podczas instalacji zapisuje ten sam skrypt w `/usr/local/libexec/hydra-rpm-updater`.
- Timer systemd uruchamia automatyczne sprawdzanie 5 minut po starcie systemu, a następnie co około 6 godzin (z losowym opóźnieniem do 15 minut).
- Przy każdym sprawdzeniu aktualizator pobiera aktualny skrypt z GitHuba. Jeśli kod się zmienił, najpierw sprawdza składnię `bash -n`, następnie podmienia lokalny plik i uruchamia nową wersję.
- Sprawdza najnowsze wydanie z oficjalnego repozytorium `hydralauncher/hydra` i porównuje wersję zainstalowaną z najnowszą.
- Pobiera RPM wyłącznie, gdy potrzebna jest instalacja lub aktualizacja. Pakiet trafia do pliku tymczasowego w `/var/cache/hydra-rpm-updater/`; po zakończeniu działania `dnf` jest usuwany, również w przypadku błędu.
- Powiadomienie graficzne jest wysyłane tylko po udanej instalacji lub aktualizacji. Jeśli nie ma aktywnej sesji graficznej, powiadomienie zostaje zakolejkowane do kolejnego uruchomienia.
- Logi trafiają do dziennika systemd/journald.

## Ręczne sprawdzenie aktualizacji

```bash
sudo systemctl start hydra-rpm-updater.service
```

## Status timera

```bash
systemctl status hydra-rpm-updater.timer --no-pager
systemctl list-timers hydra-rpm-updater.timer
```

## Logi

```bash
journalctl -u hydra-rpm-updater.service -n 100 --no-pager
```

## Wyłączenie automatycznych kontroli

```bash
sudo systemctl disable --now hydra-rpm-updater.timer
```

Ponowne włączenie:

```bash
sudo systemctl enable --now hydra-rpm-updater.timer
```

## Wymagania i uwagi

- Fedora lub dystrybucja zgodna z `dnf`, `rpm` i `systemd`.
- Wymagane polecenia instalowane przez skrypt: `curl`, `jq`, `libnotify`, `util-linux`, `systemd`.
- Aktualizator działa jako usługa systemowa z uprawnieniami roota, ponieważ instalacja RPM wymaga uprawnień administratora.
- Aktualizacja samego skryptu jest automatyczna. Zmiany w definicjach usługi/timera systemd w przyszłości nadal wymagają ponownego uruchomienia jednoplikowego instalatora.
- Przed uruchomieniem skryptu z internetu warto sprawdzić jego treść i upewnić się, że pochodzi z zaufanego repozytorium.

## Plik

- `install-hydra-updater.sh` — jedyny skrypt potrzebny do instalacji i działania aktualizatora.
- `README.md` — instrukcja instalacji, użycia i diagnostyki.
