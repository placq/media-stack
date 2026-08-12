# Media Stack dla Proxmox LXC

Produkcyjny instalator kompletnego stacku multimedialnego. Główny skrypt jest
uruchamiany **na serwerze Proxmox VE**: tworzy osobny, nieuprzywilejowany LXC z
Debianem 13, przygotowuje urządzenia i uruchamia instalator aplikacji **wewnątrz
tego LXC**.

Docker ani żadna aplikacja multimedialna nie są instalowane na hoście Proxmox.

## Co powstaje

```text
Proxmox VE host
└── nieuprzywilejowany LXC „media”
    ├── Docker Engine + Compose
    ├── Gluetun → ProtonVPN → Transmission
    ├── Radarr, Sonarr, Prowlarr, Bazarr
    ├── Jellyfin i Seerr
    ├── opcjonalny FlareSolverr
    ├── opcjonalny Newt → Pangolin
    ├── opcjonalny Tailscale
    ├── automatyczne spięcie aplikacji ARR
    ├── synchronizacja portu ProtonVPN → Transmission
    └── opóźnione aktualizacje z backupem i rollbackiem
```

Provisioner może również przekazać urządzenie renderujące Intel/AMD do Jellyfin
i utworzyć osobny, zarządzany przez Proxmox wolumin na media.

## Najszybsza instalacja

### 1. Przygotuj dane

Przed startem warto mieć:

- płatne konto ProtonVPN z port forwardingiem;
- dla zalecanego WireGuard: klucz `PrivateKey` z konfiguracji ProtonVPN
  wygenerowanej z włączonym NAT-PMP;
- albo osobny login i hasło OpenVPN z panelu ProtonVPN — nie dane konta;
- opcjonalnie endpoint, ID i sekret Newt z Pangolin;
- opcjonalnie konto Tailscale;
- adresację sieci: DHCP z rezerwacją lub statyczny IPv4;
- decyzję, na którym storage Proxmox mają znajdować się system i media.

OpenVPN wymaga sufiksu `+pmp`; instalator dodaje go sam i nie dubluje, jeśli już
jest obecny.

### 2. Uruchom provisioner na hoście Proxmox

Zaloguj się do powłoki **hosta Proxmox jako root** i pobierz skrypt do pliku:

```bash
installer=$(mktemp)
curl -fsSL https://raw.githubusercontent.com/placq/media-stack/main/proxmox_lxc.sh -o "$installer"
bash "$installer"
rm -f "$installer"
```

Jeśli chcesz pobrać tylko ten jeden plik bez żadnego klonowania repo:

```bash
wget -O proxmox_lxc.sh https://raw.githubusercontent.com/placq/media-stack/main/proxmox_lxc.sh
chmod +x proxmox_lxc.sh
bash proxmox_lxc.sh
```

Nie uruchamiaj tego polecenia na laptopie ani stacji roboczej. Provisioner ma
twardą kontrolę środowiska i zakończy się, jeśli nie wykryje hosta Proxmox VE.

Nie używaj `curl | bash`. Provisioner celowo wymaga interaktywnego terminala i
przed utworzeniem LXC wyświetla kompletny plan do zatwierdzenia.

Skrypt poprosi o:

1. nowy CT ID i hostname;
2. storage oraz rozmiar dysku systemowego;
3. CPU, RAM i swap;
4. bridge, DHCP/statyczny IPv4 i opcjonalny VLAN;
5. opcjonalny osobny wolumin `/opt/media-stack/data`;
6. czy ten wolumin ma wejść do backupów `vzdump`;
7. opcjonalne przekazanie iGPU;
8. ostateczne potwierdzenie utworzenia LXC.

Następnie automatycznie:

- odświeży katalog `pveam` i pobierze najnowszy szablon Debian 13;
- utworzy nowy, nieuprzywilejowany LXC;
- włączy `nesting=1` i `keyctl=1` wymagane przez Docker;
- przekaże `/dev/net/tun` wymagany przez Gluetun i Tailscale;
- uruchomi LXC i poczeka na systemd, sieć oraz TUN;
- przeniesie do LXC jeden spójny snapshot projektu;
- uruchomi wewnętrzny kreator usług.

Druga seria pytań widoczna w tym samym terminalu dotyczy już wyłącznie
konfiguracji wewnątrz LXC: VPN, Pangolin, Transmission, Tailscale, FlareSolverr,
backupu zewnętrznego oraz transkodowania sprzętowego.

Po udanej instalacji CT otrzymuje ochronę Proxmox przed przypadkowym usunięciem.

## Ważne decyzje

### Sieć

Najprościej wybrać DHCP i ustawić w routerze rezerwację dla MAC nowego LXC.
Można też od razu podać statyczny IPv4. Panele Dockera są wiązane tylko z
loopbackiem i konkretnym adresem LAN, dlatego nie są przypadkowo publikowane na
każdym interfejsie.

Jeśli adres LXC później się zmieni:

```bash
pct exec CTID -- media-stack repair-ip
```

Polecenie wykryje nowy adres, atomowo zmieni `.env`, odtworzy bindingi i w razie
błędu przywróci poprzednią konfigurację.

### Storage

Provisioner może utworzyć osobny wolumin Proxmox zamontowany jako
`/opt/media-stack/data`. Dla NAS lub istniejącego bind mountu najlepiej najpierw
utworzyć LXC provisionerem bez woluminu danych, zatrzymać go, dodać świadomie
mapowany mount i dopiero wewnątrz LXC ponownie uruchomić `install_media.sh`.

W nieuprzywilejowanym LXC UID 1000 jest mapowany na UID 101000 hosta Proxmox.
Instalator testuje realny zapis jako użytkownik mediów i zatrzymuje się z jasnym
błędem, jeśli mapowanie jest niepoprawne. Nie wykonuje rekurencyjnego `chown` na
całej istniejącej bibliotece.

Katalogi pobierania i bibliotek są częścią jednego drzewa `/data`, a instalator
sprawdza możliwość tworzenia hardlinków.

### VPN

WireGuard jest domyślnym zaleceniem ze względu na mniejszy narzut. Obsługiwany
jest również OpenVPN. W obu wariantach Transmission używa bezpośrednio
przestrzeni sieciowej Gluetun (`network_mode: service:gluetun`), więc utrata VPN
odcina mu wyjście zamiast przełączać ruch na zwykły interfejs LXC.

Losowy port przydzielony przez ProtonVPN jest co minutę odczytywany z Gluetun i
ustawiany przez uwierzytelnione API Transmission. Skrypt nie parsuje logów i nie
wymaga ręcznej zmiany portu po reconnectcie.

### Dostęp zdalny

Pangolin i Tailscale są niezależne i opcjonalne:

- Pangolin publikuje deklaratywnie tylko Jellyfin oraz Seerr;
- Newt czyta metadane kontenerów przez ograniczony Docker Socket Proxy, nie przez
  bezpośrednio zamontowane gniazdo Dockera;
- panele administracyjne nie mają etykiet publicznych;
- Tailscale Serve udostępnia prywatne endpointy HTTPS dla wszystkich paneli.

## Model dostępu

| Usługa | LAN | Tailscale | Pangolin publiczny |
| --- | :---: | :---: | :---: |
| Jellyfin | Tak | Tak | Tak |
| Seerr | Tak | Tak | Tak, domyślnie z SSO |
| Transmission | Tak | Tak | Nie |
| Radarr | Tak | Tak | Nie |
| Sonarr | Tak | Tak | Nie |
| Prowlarr | Tak | Tak | Nie |
| Bazarr | Tak | Tak | Nie |
| FlareSolverr | Nie | Nie | Nie |

Nie przekierowuj tych portów na routerze. Publiczny dostęp powinien przechodzić
wyłącznie przez Pangolin, a administracja zdalna przez polityki Tailscale.

## Co jest konfigurowane automatycznie

Po pierwszym starcie `media-stack configure` używa bieżących schematów API
aplikacji, zamiast polegać na sztywnym JSON-ie konkretnej wersji. Operacja jest
idempotentna i ustawia:

- `/data/media/movies` jako root folder Radarr;
- `/data/media/tv` jako root folder Sonarr;
- Transmission jako download client obu aplikacji;
- kategorię `movies` dla Radarr i `tv` dla Sonarr;
- pełną synchronizację Prowlarr z Radarr i Sonarr;
- wewnętrzne adresy kontenerów bez Remote Path Mappings.

Ręcznie pozostają czynności wymagające decyzji użytkownika: konto i biblioteki
Jellyfin, logowanie Seerr, profile jakości, indexery oraz ewentualny proxy
FlareSolverr.

Jeśli automatyczne spięcie wykonało się zanim aplikacje były gotowe, można je
bezpiecznie powtórzyć:

```bash
pct exec CTID -- media-stack configure
```

## Zarządzanie z hosta Proxmox

```bash
# stan kontenerów i adresy
pct exec CTID -- media-stack status

# pełna diagnostyka: TUN, storage, hardlinki, healthchecki, VPN i timery
pct exec CTID -- media-stack doctor

# logi jednej usługi
pct exec CTID -- media-stack logs gluetun

# spójny backup konfiguracji przy zatrzymanym stacku
pct exec CTID -- media-stack backup

# wejście do LXC
pct enter CTID
```

Przydatne polecenia już wewnątrz LXC:

```bash
media-stack status
media-stack doctor
cd /opt/media-stack && docker compose ps
systemctl status media-stack-update.timer
systemctl status media-stack-port-sync.timer
journalctl -u media-stack-update.service -n 100 --no-pager
journalctl -u media-stack-port-sync.service -n 100 --no-pager
```

## Aktualizacje i rollback

Timer nocny pobiera metadane nowych obrazów, ale kandydat musi pozostać
niezmieniony przez siedem dni. Grupy zależnych usług dojrzewają razem:

- Gluetun + Transmission;
- Newt + Docker Socket Proxy;
- pozostałe aplikacje osobno.

Przed wdrożeniem stack jest zatrzymywany, a konfiguracja i sekrety trafiają do
sprawdzonego archiwum. Po aktualizacji wymagane są działające kontenery,
healthchecki, endpointy HTTP, brak pętli restartów i aktywny port ProtonVPN przez
pełne 60 sekund. Niepowodzenie przywraca poprzednie obrazy i konfigurację.

Opcjonalny backup NAS zapisuje także oczekiwane źródło i punkt montowania.
Zmiana lub zniknięcie mountu zatrzymuje backup/aktualizację zamiast zapisać dane
na lokalnym katalogu pod pustym mountpointem.

Lokalnie przechowywanych jest pięć backupów i dwa obrazy rollbacku na usługę;
na zewnętrznym filesystemie dziesięć backupów.

## Sekrety

Hasła nie trafiają do `.env`, wygenerowanej instrukcji ani środowiska
kontenerów tam, gdzie upstream obsługuje pliki:

```text
/opt/media-stack/secrets/
├── proton_openvpn_user              # tylko dla OpenVPN
├── proton_openvpn_password          # tylko dla OpenVPN
├── proton_wireguard_private_key     # tylko dla WireGuard
├── transmission_user
└── transmission_password
```

Pliki mają tryb `0600`. Gluetun i LinuxServer Transmission korzystają z Docker
Compose secrets. Newt używa własnego pliku konfiguracyjnego `0600`.

## Instalacja w istniejącym LXC

Jeśli LXC został już utworzony ręcznie, na hoście Proxmox ustaw co najmniej:

```bash
pct set CTID --features nesting=1,keyctl=1
pct set CTID --dev0 /dev/net/tun
pct stop CTID
pct start CTID
```

Następnie wejdź do kontenera (`pct enter CTID`) i wykonaj:

```bash
apt-get update
apt-get install -y ca-certificates curl
installer=$(mktemp)
curl -fsSL https://raw.githubusercontent.com/placq/media-stack/main/install_media.sh -o "$installer"
bash "$installer"
rm -f "$installer"
```

`install_media.sh` jest bezpieczny do ponownego uruchomienia: zachowuje puste
sekrety z poprzedniej konfiguracji, waliduje nowy Compose przed podmianą i przy
błędzie odtwarza poprzednie pliki.

## Diagnostyka awarii provisionera

Provisioner nigdy nie usuwa automatycznie częściowo utworzonego LXC. Jeśli etap
wewnętrzny się nie powiedzie:

```bash
pct config CTID
pct enter CTID
bash /root/media-stack-source/install_media.sh
```

Sprawdź przede wszystkim:

```bash
test -c /dev/net/tun && echo TUN_OK
ip route
systemctl status docker --no-pager
cd /opt/media-stack && docker compose logs --tail=100 gluetun
```

CT ma po udanej instalacji włączoną ochronę. Przed świadomym usunięciem trzeba ją
wyłączyć:

```bash
pct set CTID --protection 0
```

## Pliki projektu

| Plik | Rola |
| --- | --- |
| `proxmox_lxc.sh` | provisioner uruchamiany wyłącznie na hoście Proxmox |
| `install_media.sh` | instalator uruchamiany wyłącznie wewnątrz LXC |
| `templates/compose*.yaml` | testowalne profile stacku |
| `media_stack.sh` | status, doctor, konfiguracja ARR, backup i naprawa IP |
| `sync_transmission_port.sh` | synchronizacja ProtonVPN → Transmission |
| `update_stack.sh` | opóźnione aktualizacje, backup, healthcheck i rollback |

Projekt opiera konfigurację LXC na oficjalnym `pct`, Dockera na podpisanym
repozytorium APT Docker CE, Tailscale na podpisanym repozytorium APT, a składnię
Pangolin na deklaratywnych blueprintach/etykietach Newt.

Dokumentacja referencyjna: [Proxmox `pct`](https://pve.proxmox.com/pve-docs/pct.1.html),
[Docker Engine na Debianie](https://docs.docker.com/engine/install/debian/),
[Tailscale w nieuprzywilejowanym LXC](https://tailscale.com/kb/1130/lxc-unprivileged/),
[ProtonVPN port forwarding](https://protonvpn.com/support/port-forwarding-manual-setup),
[Gluetun dla ProtonVPN](https://github.com/qdm12/gluetun-wiki/blob/main/setup/providers/protonvpn.md),
[Pangolin Blueprints](https://docs.pangolin.net/manage/blueprints) oraz
[Docker dla Seerr](https://docs.seerr.dev/getting-started/docker/).
