# Media Stack Installer

Interaktywny instalator stosu multimedialnego dla Debiana lub Ubuntu, przygotowany przede wszystkim do działania w kontenerze LXC na Proxmox VE. Konfiguruje Docker, ProtonVPN, Pangolin, Tailscale, automatyczne przekazywanie portu do Transmission oraz opóźnione aktualizacje kontenerów.

## Instalacja od zera na Proxmox VE

Poniższa procedura prowadzi od świeżego hosta Proxmox do działającego stosu. Zakłada, że Proxmox VE jest już zainstalowany i panel WWW działa. Polecenia oznaczone jako **host Proxmox** wykonuj w powłoce węzła Proxmox, a oznaczone jako **LXC** — w konsoli utworzonego kontenera.

### 1. Przygotuj potrzebne dane

Przed rozpoczęciem przygotuj:

- płatne konto ProtonVPN obsługujące port forwarding;
- **osobny login i hasło OpenVPN** z panelu ProtonVPN: `Account → OpenVPN username` — nie są to dane logowania do konta Proton;
- adres endpointu Pangolin, np. `https://pangolin.example.com`;
- identyfikator i sekret tunelu Newt utworzonego w Pangolin;
- domenę bazową używaną przez Pangolin, np. `example.com`;
- konto Tailscale, do którego zostanie dodany serwer;
- opcjonalnie zamontowany katalog NAS przeznaczony na drugi egzemplarz backupu konfiguracji.

Nie dopisuj `+pmp` do loginu OpenVPN. Instalator robi to automatycznie.

### 2. Pobierz szablon systemu

W panelu Proxmox przejdź do magazynu przechowującego szablony, wybierz `CT Templates` i pobierz aktualny 64-bitowy szablon Debiana. Zalecany jest Debian 13; Debian 12 i aktualne wydania Ubuntu również są obsługiwane przez instalator.

### 3. Utwórz LXC

Wybierz `Create CT` i ustaw:

| Ustawienie | Zalecana wartość |
| --- | --- |
| Unprivileged container | włączone |
| Hostname | `media` |
| Start at boot | włączone |
| CPU | 4 rdzenie |
| RAM | 8 GB; praktyczne minimum to 4 GB bez ciężkiego transkodowania |
| Swap | 512 MB–1 GB |
| Dysk systemowy | co najmniej 32 GB |
| Network | `vmbr0`, DHCP na czas tworzenia |
| DNS | ustawienia hosta lub własny serwer DNS |

Po utworzeniu LXC ustaw w routerze rezerwację DHCP dla jego adresu MAC. Możesz zamiast tego skonfigurować statyczny IPv4 w Proxmox, ale przed instalacją adres musi być już docelowy. Instalator zapisuje go w powiązaniach portów Dockera; późniejsza zmiana IP wymaga ponownego wygenerowania konfiguracji.

Nie uruchamiaj jeszcze instalatora.

### 4. Włącz TUN, nesting i keyctl

Tailscale i Gluetun potrzebują `/dev/net/tun`, a Docker wewnątrz nieuprzywilejowanego LXC wymaga `nesting` oraz `keyctl`.

W aktualnym interfejsie Proxmox:

1. Otwórz LXC `media`.
2. W `Options → Features` włącz `Nesting` i `Keyctl`.
3. W `Resources` wybierz `Add → Device Passthrough`.
4. Jako `Device Path` podaj `/dev/net/tun` (w niektórych wersjach UI: `dev/net/tun`).
5. Zatrzymaj LXC poleceniem `Stop`, a następnie uruchom go ponownie. Sam restart systemu wewnątrz LXC nie wystarczy.

To samo można wykonać z powłoki **hosta Proxmox**. Zastąp `120` rzeczywistym numerem kontenera:

```bash
CTID=120
pct set "$CTID" --dev0 /dev/net/tun
pct set "$CTID" --features keyctl=1,nesting=1
pct stop "$CTID"
pct start "$CTID"
```

Tailscale będzie zainstalowany **wewnątrz LXC `media`**. Nie trzeba instalować go na hoście Proxmox.

### 5. Opcjonalnie dodaj osobny dysk na media

Najprostszy wariant to zarządzany przez Proxmox punkt montowania:

1. Otwórz `LXC → Resources → Add → Mount Point`.
2. Wybierz magazyn i rozmiar.
3. Ustaw ścieżkę wewnątrz kontenera na `/opt/media-stack/data`.
4. Zdecyduj, czy dane multimedialne mają być objęte backupem Proxmox. Duże biblioteki zazwyczaj wyłącza się z `vzdump` i zabezpiecza osobno.

Można też podmontować do LXC katalog z hosta lub NAS, ale w nieuprzywilejowanym LXC trzeba wtedy świadomie skonfigurować mapowanie UID/GID. Nie montuj przypadkowych katalogów systemowych hosta. Zawartość bind mountów nie jest automatycznie uwzględniana w `vzdump`.

Jeśli dane mają pozostać na dysku systemowym LXC, pomiń ten krok. Instalator sam utworzy `/opt/media-stack/data`.

### 6. Opcjonalnie przekaż Intel iGPU

Jeżeli Jellyfin ma używać Quick Sync, przekaż urządzenia GPU do LXC przed instalacją. Z powłoki **hosta Proxmox**:

```bash
CTID=120
pct set "$CTID" --dev1 /dev/dri/renderD128
test ! -e /dev/dri/card0 || pct set "$CTID" --dev2 /dev/dri/card0
pct stop "$CTID"
pct start "$CTID"
```

Następnie w **LXC** sprawdź:

```bash
ls -l /dev/dri/renderD128
```

Jeżeli urządzenie istnieje, instalator zaproponuje włączenie Quick Sync. Bez iGPU stos również działa — Jellyfin będzie transkodował programowo.

### 7. Sprawdź LXC przed instalacją

Otwórz konsolę LXC i wykonaj:

```bash
cat /etc/os-release
test -c /dev/net/tun && echo "TUN: OK" || echo "TUN: BRAK"
ip -4 address show dev eth0
ip route
```

Oczekiwany wynik to Debian/Ubuntu, `TUN: OK`, docelowy adres LAN i trasa domyślna. Jeżeli TUN jest niedostępny, wróć do kroku 4.

### 8. Pobierz i uruchom instalator

W **LXC** zaloguj się jako `root` i wykonaj:

```bash
apt-get update
apt-get install -y ca-certificates curl

installer=$(mktemp)
curl -fsSL https://raw.githubusercontent.com/placq/media-stack/main/install_media.sh -o "$installer"
bash "$installer"
rm -f "$installer"
```

Nie używaj `curl ... | bash`: instalator celowo wymaga interaktywnego terminala.

### 9. Odpowiedz na pytania instalatora

1. `Installation path` — pozostaw `/opt/media-stack`, chyba że świadomie używasz innej ścieżki.
2. `External backup directory` — podaj istniejący i zapisywalny katalog NAS, np. `/mnt/nas/media-stack-backups`, albo zostaw pusty. Instalator go nie tworzy, żeby brak montowania NAS nie został przeoczony.
3. `OpenVPN username/password` — wprowadź dane OpenVPN z panelu ProtonVPN. Nie używaj hasła konta Proton i nie dopisuj `+pmp`.
4. `Pangolin endpoint` — pełny adres panelu/tunelu, np. `https://pangolin.example.com`.
5. `Newt ID` i `Newt secret` — dane wygenerowane dla tego tunelu w Pangolin.
6. `Public base domain` — domena dla `jellyfin.domena` i `seerr.domena`.
7. `Transmission username/password` — dane do prywatnego panelu Transmission; zaakceptuj wygenerowane hasło albo wpisz własne silne hasło.
8. `Intel QuickSync` — wybierz `Y`, jeśli urządzenie `/dev/dri/renderD128` zostało poprawnie przekazane.

Podczas instalacji Tailscale wyświetli adres logowania. Otwórz go w przeglądarce i zatwierdź dodanie urządzenia `media` do właściwego tailnetu. Instalator będzie czekał na zakończenie tego kroku.

Instalacja może potrwać kilka–kilkanaście minut, ponieważ pobiera Dockera i wszystkie obrazy kontenerów. Nie przerywaj jej po pojawieniu się komunikatów `Pulling` lub podczas oczekiwania na healthcheck.

### 10. Sprawdź rezultat

Po zakończeniu, nadal w **LXC**, wykonaj:

```bash
cd /opt/media-stack
docker compose ps
tailscale status
tailscale serve status
systemctl --no-pager status media-stack-update.timer
systemctl --no-pager status media-stack-port-sync.timer
systemctl start media-stack-port-sync.service
journalctl -u media-stack-port-sync.service -n 20 --no-pager
```

W `docker compose ps` wszystkie kontenery powinny mieć stan `running`, a Gluetun i Seerr — `healthy`. Log synchronizatora powinien po zestawieniu VPN potwierdzić ustawienie portu Transmission. Pierwsza próba może poinformować, że ProtonVPN jeszcze nie przydzielił portu; timer ponowi ją automatycznie.

Sprawdź interfejsy z komputera w tej samej sieci, podstawiając adres LXC:

```text
http://ADRES_LXC:8096  Jellyfin
http://ADRES_LXC:5055  Seerr
http://ADRES_LXC:9091  Transmission
http://ADRES_LXC:7878  Radarr
http://ADRES_LXC:8989  Sonarr
http://ADRES_LXC:9696  Prowlarr
http://ADRES_LXC:6767  Bazarr
```

W Pangolin powinny zostać wykryte wyłącznie dwa publiczne zasoby: Jellyfin i Seerr. Pozostałe panele nie powinny być publikowane do Internetu.

### 11. Dokończ konfigurację aplikacji

Po pierwszym uruchomieniu:

1. Skonfiguruj bibliotekę Jellyfin w `/data/media/movies` i `/data/media/tv`.
2. Połącz Seerr z Jellyfin, Radarr i Sonarr.
3. Dodaj Transmission do Radarr i Sonarr jako host `gluetun`, port `9091`, z danymi podanymi instalatorowi.
4. W Radarr ustaw kategorię pobierania `movies`, a w Sonarr `tv`.
5. Połącz Prowlarr z Radarr i Sonarr.
6. Jeśli potrzebujesz FlareSolverr, dodaj w Prowlarr proxy o adresie `http://flaresolverr:8191`.
7. Włącz hardlinki w Radarr i Sonarr. Wszystkie aplikacje widzą wspólne drzewo `/data`, więc nie są potrzebne Remote Path Mappings.

### 12. Zabezpiecz dostęp

- Nie przekierowuj na routerze portów `5055`, `8096`, `9091`, `7878`, `8989`, `9696` ani `6767`.
- Publicznie przez Pangolin wystawiaj tylko Jellyfin i Seerr.
- Panele administracyjne otwieraj przez LAN lub Tailscale.
- W ACL/grants Tailscale ogranicz porty administracyjne do własnego użytkownika lub grupy administratorów.
- Ustaw regularny backup samego LXC w Proxmox. Backup konfiguracji wykonywany przed aktualizacją kontenerów nie zastępuje pełnego backupu Proxmox ani kopii biblioteki multimedialnej.

### 13. Diagnostyka

Najbardziej przydatne polecenia w **LXC**:

```bash
cd /opt/media-stack
docker compose ps
docker compose logs --tail=100 gluetun
docker compose logs --tail=100 seerr
journalctl -u tailscaled -n 100 --no-pager
journalctl -u media-stack-update.service -n 100 --no-pager
journalctl -u media-stack-port-sync.service -n 100 --no-pager
```

Typowe problemy:

- `Missing /dev/net/tun` — wykonaj ponownie krok 4 i użyj pełnego `Stop/Start` LXC.
- Docker nie uruchamia testowego kontenera — sprawdź `Nesting` i `Keyctl`.
- ProtonVPN odrzuca dane — użyto loginu do konta zamiast osobnych danych OpenVPN.
- Brak portu przekazanego przez ProtonVPN — konto musi obsługiwać port forwarding; poczekaj na zestawienie połączenia i sprawdź log Gluetun.
- Panele działają po IP, ale nie przez Tailscale — sprawdź `tailscale status`, `tailscale serve status` i reguły dostępu tailnetu.
- NAS nie jest dostępny — zamontuj go przed uruchomieniem instalatora lub pozostaw pole zewnętrznego backupu puste.

Materiały źródłowe: [Tailscale w nieuprzywilejowanym LXC](https://tailscale.com/kb/1130/lxc-unprivileged/), [dokumentacja `pct` i punktów montowania Proxmox](https://pve.proxmox.com/pve-docs/pct.1.html), [obsługiwane wydania Debiana w Docker Engine](https://docs.docker.com/engine/install/debian/), [dane OpenVPN i port forwarding ProtonVPN](https://protonvpn.com/support/port-forwarding-manual-setup).

## Model dostępu

| Usługa | LAN | Tailscale | Publicznie przez Pangolin |
| --- | :---: | :---: | :---: |
| Jellyfin | Tak | Tak | Tak |
| Seerr | Tak | Tak | Tak |
| Transmission | Tak | Tak | Nie |
| Sonarr | Tak | Tak | Nie |
| Radarr | Tak | Tak | Nie |
| Prowlarr | Tak | Tak | Nie |
| Bazarr | Tak | Tak | Nie |
| FlareSolverr | Nie | Nie | Nie |

Tylko Jellyfin i Seerr są dostępne z Internetu. Aplikacje administracyjne nasłuchują na loopbacku i wykrytym adresie LAN, a prywatny dostęp zdalny zapewnia Tailscale Serve.

## Zawarte usługi

- Jellyfin
- Seerr
- Transmission kierowany przez Gluetun i ProtonVPN
- Sonarr, Radarr, Prowlarr i Bazarr
- FlareSolverr
- Newt dla Pangolin
- ograniczony Docker Socket Proxy używany przez Newt do wykrywania etykiet

Newt nigdy nie otrzymuje bezpośredniego dostępu do gniazda Dockera hosta. Ruch związany z wykrywaniem przechodzi przez proxy tylko do odczytu, z wyłączonymi żądaniami zapisującymi. Seerr używa oficjalnego obrazu `ghcr.io/seerr-team/seerr:v3`.

## Automatyczne przekazywanie portu Transmission

Gluetun otrzymuje przekazany port od ProtonVPN. Timer systemd odczytuje go co minutę i aktualizuje Transmission przez uwierzytelnione API RPC. Zmiana portu po ponownym połączeniu VPN jest obsługiwana automatycznie; nie ma ręcznego helpera ani czynności w panelu.

```bash
sudo systemctl status media-stack-port-sync.timer
sudo systemctl start media-stack-port-sync.service
sudo journalctl -u media-stack-port-sync.service
```

## Automatyczne aktualizacje i odzyskiwanie

Nie ma panelu aktualizacji ani usługi powiadomień. Timer systemd sprawdza obrazy kontenerów każdej nocy.

- Kandydat na nowy obraz musi pozostać niezmieniony przez siedem dni przed instalacją.
- Kandydaci dojrzewają niezależnie w bezpiecznych grupach: Gluetun z Transmission, Newt z proxy oraz każda pozostała aplikacja osobno.
- Niedojrzała aktualizacja jednej grupy nie blokuje innych grup.
- Konfiguracja jest archiwizowana przed wdrożeniem; opcjonalna kopia trafia na zamontowany NAS.
- Aktualizator wymaga, aby kontenery, healthchecki, VPN i lokalne interfejsy HTTP działały stabilnie przez 60 sekund.
- Błąd startu, healthchecku albo pętla restartów automatycznie przywracają konfigurację i poprzednie obrazy.
- Zachowywanych jest pięć lokalnych backupów konfiguracji, dziesięć zewnętrznych backupów oraz dwa obrazy rollbacku na usługę.
- Nieudany kandydat musi ponownie odczekać przed następną automatyczną próbą.

Opóźnienie można zmienić w `/opt/media-stack/.env`:

```dotenv
UPDATE_DELAY_DAYS='7'
```

Instalator włącza również automatyczne aktualizacje bezpieczeństwa Debiana/Ubuntu w samym LXC. Aktualizacje obrazów kontenerów i systemu operacyjnego są obsługiwane osobno.

## Migracja z Jellyseerr

Jeśli zostanie znaleziony istniejący katalog `config/jellyseerr`, stary kontener jest zatrzymywany przed skopiowaniem bazy SQLite i konfiguracji. Najpierw powstaje archiwum migracyjne. Stary Jellyseerr jest usuwany dopiero wtedy, gdy nowy Seerr zgłosi stan `healthy`; błąd instalacji ponownie uruchamia stary kontener.

## Układ danych

```text
/opt/media-stack/
├── .env
├── docker-compose.yml
├── important_info.md
├── sync_transmission_port.sh
├── update_stack.sh
├── backups/
├── config/
└── data/
    ├── media/
    │   ├── movies/
    │   └── tv/
    └── torrents/
        ├── incomplete/
        ├── movies/
        └── tv/
```

Wszystkie ścieżki pobierania i biblioteki korzystają ze wspólnego montowania `/data`, dzięki czemu Sonarr i Radarr mogą używać hardlinków zamiast kopiować pliki.

## Przydatne polecenia

```bash
cd /opt/media-stack
sudo docker compose ps
sudo systemctl status media-stack-update.timer
sudo systemctl start media-stack-update.service
sudo journalctl -u media-stack-update.service
```

Sekrety są przechowywane wyłącznie w `.env`, który otrzymuje uprawnienia `600`. Wygenerowana dokumentacja nie zawiera haseł.
