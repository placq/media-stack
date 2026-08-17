# Media Stack dla Proxmox LXC

Powtarzalny instalator produkcyjnego stacku multimedialnego dla Proxmox VE.
Główny skrypt uruchamia się na hoście Proxmox, tworzy **nieuprzywilejowany LXC z Debianem 13**, przygotowuje storage i urządzenia, a następnie instaluje Dockera oraz cały stack wyłącznie wewnątrz kontenera.

Projekt celowo zajmuje się tylko warstwą mediów. Zdalny dostęp, reverse proxy i inne elementy infrastruktury sieciowej są konfigurowane poza tym LXC.

## Co powstaje

```text
Proxmox VE
└── LXC media (unprivileged, Debian 13)
    ├── Docker Engine + Compose
    ├── Gluetun → ProtonVPN
    │   └── Transmission
    ├── Sonarr
    ├── Radarr
    ├── Prowlarr
    ├── Bazarr
    ├── Jellyfin
    ├── Seerr
    ├── opcjonalny FlareSolverr
    ├── automatyczne spięcie *Arr + Bazarr
    ├── synchronizacja forwarded port ProtonVPN → Transmission
    ├── diagnostyka storage/VPN/iGPU/usług
    └── opóźnione aktualizacje z backupem i rollbackiem
```

## Założenia

- Proxmox VE jako host.
- Płatny ProtonVPN z obsługą port forwardingu.
- **WireGuard jest domyślnym i zalecanym protokołem VPN.**
- OpenVPN pozostaje dostępny jako fallback.
- Media i downloady powinny znajdować się na jednym filesystemie, aby Sonarr/Radarr mogły używać hardlinków.
- Jellyfin może dostać `/dev/dri/renderD128` do sprzętowego transkodowania Intel/AMD.

## Instalacja

Na hoście Proxmox jako `root`:

```bash
installer=$(mktemp)
curl -fsSL https://raw.githubusercontent.com/placq/media-stack/main/proxmox_lxc.sh -o "$installer"
bash "$installer"
rm -f "$installer"
```

Nie używaj `curl | bash`. Provisioner wymaga interaktywnego terminala i pokazuje plan przed utworzeniem LXC.

### Provisioner pyta tylko o rzeczy, których nie da się bezpiecznie zgadnąć

1. CT ID i hostname;
2. storage LXC;
3. CPU/RAM/swap;
4. DHCP lub statyczny IPv4 i opcjonalny VLAN;
5. gdzie mają leżeć media;
6. opcjonalne przekazanie iGPU;
7. dane ProtonVPN;
8. login do Transmission;
9. czy uruchomić FlareSolverr;
10. opcjonalny zewnętrzny katalog backupu.

Domyślny rootfs LXC to **64 GiB**. Dane multimedialne mogą być osobnym woluminem Proxmox albo istniejącym filesystemem hosta.

## VPN i Transmission

Domyślnie instalator wybiera **WireGuard**. Należy podać `PrivateKey` z konfiguracji ProtonVPN przygotowanej do port forwardingu.

Transmission nie ma własnego namespace sieciowego:

```text
Transmission
    │
    └── network_mode: service:gluetun
                        │
                        └── ProtonVPN
```

Dzięki temu Transmission korzysta bezpośrednio z sieci Gluetun. Forwarded port jest pobierany w pierwszej kolejności z control API Gluetun, a dla zgodności z serią v3 dostępny jest fallback do pliku statusowego. Port jest następnie ustawiany przez uwierzytelnione RPC Transmission.

OpenVPN jest obsługiwany jako fallback i używa osobnych danych OpenVPN ProtonVPN. Instalator automatycznie dodaje wymagany sufiks `+pmp`, jeśli go brakuje.

## Storage i hardlinki

Wszystkie aplikacje widzą jedno drzewo `/data`:

```text
/data
├── torrents
│   ├── incomplete
│   ├── movies
│   └── tv
└── media
    ├── movies
    └── tv
```

Taki układ pozwala Sonarr/Radarr importować pliki przez hardlink zamiast kopiować je między osobnymi mountami.

Dla istniejącego filesystemu hosta provisioner:

- odmawia użycia ścieżki znajdującej się na rootfs Proxmoxa;
- mapuje UID/GID nieuprzywilejowanego LXC;
- sprawdza faktyczny zapis jako użytkownik aplikacji;
- wykonuje test hardlinka;
- zapisuje sentinel identyfikujący właściwy filesystem;
- dodaje `ExecStartPre` do Dockera, który blokuje start, jeśli właściwy dysk zniknie lub pod mountpointem pojawi się inny filesystem.

To zapobiega przypadkowemu zapisywaniu filmów na dysku systemowym po awarii mounta.

## Co konfiguruje się automatycznie

Po pierwszym starcie `media-stack configure` ustawia idempotentnie:

- `/data/media/movies` jako root folder Radarr;
- `/data/media/tv` jako root folder Sonarr;
- Transmission jako download client Radarr i Sonarr;
- kategorię `movies` dla Radarr;
- kategorię `tv` dla Sonarr;
- Prowlarr → Radarr z `fullSync`;
- Prowlarr → Sonarr z `fullSync`;
- Bazarr → Sonarr wraz z API key;
- Bazarr → Radarr wraz z API key.

Instalator wywołuje tę konfigurację sam po pierwszym uruchomieniu. Polecenie można bezpiecznie powtarzać:

```bash
media-stack configure
```

### Co nadal wymaga decyzji użytkownika

Tego projekt nie zgaduje, ponieważ są to dane konta albo preferencje:

- utworzenie pierwszego konta Jellyfin;
- wybór bibliotek i ustawień odtwarzania w Jellyfin;
- pierwsze logowanie i wybór serwera biblioteki w Seerr;
- indexery w Prowlarr;
- profile jakości i polityka pobierania;
- języki/profil napisów w Bazarr.

Poza tym połączenia pomiędzy aplikacjami są wykonywane automatycznie.

## iGPU / sprzętowe transkodowanie Jellyfin

Jeśli host ma `/dev/dri/renderD128`, provisioner proponuje przekazanie tego urządzenia do LXC. Do Jellyfin trafia tylko render node, a kontener otrzymuje właściwy GID urządzenia.

`media-stack doctor` sprawdza wtedy:

- czy render node istnieje w LXC;
- czy widzi go kontener Jellyfin;
- czy `vainfo` z pakietu Jellyfin FFmpeg potrafi otworzyć urządzenie DRM.

Po instalacji nadal należy w panelu Jellyfin wybrać sprzętową akcelerację właściwą dla sprzętu.

## Zarządzanie

W LXC:

```bash
media-stack status
media-stack doctor
media-stack configure
media-stack backup
media-stack logs gluetun
media-stack logs jellyfin
```

Z hosta Proxmox:

```bash
pct exec CTID -- media-stack status
pct exec CTID -- media-stack doctor
pct exec CTID -- media-stack configure
pct enter CTID
```

Jeśli adres IP LXC zmieni się mimo rezerwacji DHCP:

```bash
media-stack repair-ip
```

Polecenie wykryje aktualny adres, odtworzy bindingi Compose i w razie błędu przywróci poprzednią konfigurację.

## Diagnostyka

`media-stack doctor` sprawdza między innymi:

- `/dev/net/tun`;
- Docker i model Compose;
- aktualny binding LAN;
- zapis UID/GID do storage;
- hardlinki między `torrents` i `media`;
- stan i healthcheck wszystkich aktywnych kontenerów;
- czy Transmission naprawdę dzieli namespace sieciowy Gluetun;
- endpointy HTTP aplikacji;
- logowanie do Transmission;
- różnicę między publicznym IP LXC i VPN;
- forwarded port ProtonVPN;
- spięcie Bazarr → Sonarr/Radarr;
- iGPU/Jellyfin, jeśli HWA jest włączone;
- timery aktualizacji i synchronizacji portu;
- tożsamość zewnętrznego filesystemu backupowego.

## Aktualizacje

`media-stack-update.timer` uruchamia nocny check. Nowy obraz nie jest wdrażany od razu: kandydat musi pozostać niezmieniony przez domyślnie **7 dni**.

Zależne usługi aktualizują się razem, np. Gluetun + Transmission. Przed wdrożeniem powstaje backup konfiguracji i tagi rollbacku. Po zmianie wymagane są:

- działające kontenery;
- poprawne healthchecki;
- działające endpointy HTTP;
- brak pętli restartów;
- poprawny forwarded port VPN przez okres stabilizacji.

Jeśli walidacja się nie powiedzie, poprzednia konfiguracja i obrazy są automatycznie przywracane.

## Backup

`media-stack backup` tworzy spójny backup konfiguracji przy zatrzymanym stacku. Obejmuje konfiguracje aplikacji, sekrety, Compose i skrypty zarządzające, ale **nie bibliotekę filmów/seriali**.

Opcjonalny katalog zewnętrzny jest zapamiętywany wraz z tożsamością źródła i mountpointu. Jeśli mount zniknie albo zostanie podmieniony, backup kończy się błędem zamiast zapisywać pod pustym katalogiem na rootfs.

Backup tego stacku jest ochroną konfiguracji. Kopie danych ważnych dla całego homelabu powinny być realizowane niezależnie na poziomie infrastruktury.

## Sekrety

Sekrety nie są wpisywane bezpośrednio do Compose:

```text
/opt/media-stack/secrets/
├── proton_wireguard_private_key
├── proton_openvpn_user
├── proton_openvpn_password
├── transmission_user
└── transmission_password
```

Aktywny wariant VPN wykorzystuje pliki sekretów. Niepotrzebne sekrety drugiego protokołu są usuwane podczas rekonfiguracji.

## Pliki projektu

| Plik | Rola |
| --- | --- |
| `proxmox_lxc.sh` | tworzy i zabezpiecza LXC na hoście Proxmox |
| `install_media.sh` | instaluje stack wewnątrz LXC |
| `templates/compose.yaml` | główny model usług |
| `templates/compose.wireguard.yaml` | domyślna konfiguracja WireGuard |
| `templates/compose.openvpn.yaml` | fallback OpenVPN |
| `templates/compose.gpu.yaml` | passthrough render node do Jellyfin |
| `media_stack.sh` | status, doctor, automatyczna konfiguracja, backup i naprawa IP |
| `sync_transmission_port.sh` | synchronizacja forwarded port → Transmission |
| `update_stack.sh` | opóźnione aktualizacje, test stabilności i rollback |
| `tests/validate.sh` | statyczne testy kontraktów i wariantów Compose |

## Walidacja zmian

Repo uruchamia w GitHub Actions:

- `bash -n` dla skryptów;
- renderowanie wariantów Compose;
- testy niezmienników bezpieczeństwa;
- ShellCheck.

Lokalnie:

```bash
bash tests/validate.sh
shellcheck --severity=warning \
  proxmox_lxc.sh install_media.sh media_stack.sh \
  update_stack.sh sync_transmission_port.sh
```
