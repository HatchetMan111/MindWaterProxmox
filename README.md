# MindWaterProxmox

[![Mindwtr](https://img.shields.io/badge/Mindwtr-GTD%20App-green)](https://github.com/dongdongbh/Mindwtr)
[![Proxmox VE](https://img.shields.io/badge/Proxmox%20VE-8.x-orange)](https://www.proxmox.com)

**Mindwtr** ([dongdongbh/Mindwtr](https://github.com/dongdongbh/Mindwtr)) als
Ein-Klick-LXC auf Proxmox VE – im Stil der [Proxmox VE Community Scripts](https://community-scripts.github.io/ProxmoxVE).

Mindwtr ist eine lokale, Open-Source-GTD-App („Getting Things Done“): Aufgaben
und Ideen erfassen, Inbox klären, Fokus-Ansicht, Weekly Review. Alles lokal im
LAN – keine Cloud-Dienste nötig.

Der Installer legt einen **unprivilegierten Debian-12-LXC** an und installiert
darin den offiziellen Mindwtr-Docker-Stack (GHCR-Images):

| Dienst | Zweck | Port |
|---|---|---|
| `mindwtr-app` | **Web UI / PWA** (Nginx, statischer Build) | `5173` |
| `mindwtr-cloud` | **Sync-Server + REST API** | `8787` |

---

## Installation (Einzeiler)

Auf der **Proxmox-Host-Shell** als root:

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/MindWaterProxmox/main/install/mindwtr.sh)"
```

Das Script:

1. erstellt einen LXC (Debian 12, unprivileged, `nesting=1,keyctl=1`, **onboot: 1**),
   Standard: 2 vCPU / 2 GB RAM / 8 GB Disk
2. installiert Docker + Compose im Container
3. lädt `compose.yaml` aus dem offiziellen Mindwtr-Repo und die veröffentlichten
   GHCR-Images (`ghcr.io/dongdongbh/mindwtr-app`, `ghcr.io/dongdongbh/mindwtr-cloud`)
4. erzeugt einen zufälligen Sync-Token und die `.env` (CORS-Origin automatisch
   auf die Container-IP)
5. richtet den systemd-Service `mindwtr.service` ein
   (`enable`, `After=network-online.target`, `Restart=always`)
6. verifiziert selbst: Service `active`, Web UI `HTTP 200`, Cloud `/health` `HTTP 200`
7. gibt die finale URL + Container-IP aus

### Ressourcen/Ports anpassen (optional, per Umgebungsvariable)

```bash
CTID=200 CORES=2 MEM_MB=2048 DISK_GB=8 \
APP_PORT=5173 CLOUD_PORT=8787 \
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/MindWaterProxmox/main/install/mindwtr.sh)"
```

| Variable | Default | Bedeutung |
|---|---|---|
| `CTID` | nächste freie | Container-ID; existiert sie schon → **Update-Modus** |
| `CORES` / `MEM_MB` / `DISK_GB` / `SWAP_MB` | 2 / 2048 / 8 / 2048 | Container-Ressourcen |
| `APP_PORT` | `5173` | Port der Web UI |
| `CLOUD_PORT` | `8787` | Port des Sync-Servers |
| `MINDWTR_TOKEN` | zufällig | Sync-Token (min. 20 Zeichen); bei Updates wird ein bestehender Token immer übernommen |
| `STORAGE` / `VZTMP_STORAGE` / `NET_BRIDGE` | auto / local / vmbr0 | Proxmox-Storage und Netzwerk-Bridge |

**Erwartete Ausgabe am Ende:**

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 Mindwtr erfolgreich installiert!
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 Web UI:     http://192.168.1.50:5173
 Sync/API:   http://192.168.1.50:8787  (Self-Hosted URL in der App)
 Container:  CTID 118 (onboot aktiv, reboot-sicher)
 Services:   systemctl status mindwtr  (im CT)
 Logs:       journalctl -u mindwtr -e  ·  /tmp/mindwtr-install-*.log (Host)
 Login-Daten: /root/mindwtr-ct118.credentials · Token im CT: /root/mindwtr-credentials
 ...
```

---

## Mindwtr benutzen

- **Web/PWA:** `http://<LXC-IP>:5173` im Browser öffnen (funktioniert offline als PWA).
- **Sync einrichten** (Desktop/Mobile-App oder PWA):
  *Settings → Sync → Self-Hosted*
  - URL: `http://<LXC-IP>:8787` (die App hängt automatisch `/v1/data` an)
  - Token: `pct exec <CTID> -- mindwtr-ctl token`
- **REST API** (Automatisierung), Base-URL `http://<LXC-IP>:8787/v1`:

  ```bash
  TOKEN=$(pct exec <CTID> -- mindwtr-ctl token)
  curl -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
       -d '{"input":"Rechnung prüfen /due:tomorrow #finance"}' \
       http://<LXC-IP>:8787/v1/tasks
  ```

> **Tipp:** Dem Container per DHCP-Reservation (Router) eine feste IP geben oder
> eine statische IP setzen. Die CORS-Origin wird beim jedem Service-Start
> automatisch an die aktuelle Container-IP angepasst (`mindwtr-ctl refresh-env`).

---

## Update

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/MindWaterProxmox/main/install/mindwtr.sh)"
```

Einfach erneut ausführen – der Installer erkennt die existierende CT und läuft
im **Update-Modus** (idempotent): Compose-Datei frisch vom Upstream, Images
neu ziehen, Daten (`/opt/mindwtr/data`) und Sync-Token bleiben erhalten.

Alternativ im Container:

```bash
pct exec <CTID> -- mindwtr-ctl update    # compose pull + up
pct exec <CTID> -- mindwtr-ctl status    # Service/Container/Health-Check
pct exec <CTID> -- mindwtr-ctl logs 100  # Compose-Logs
```

## Deinstallation

```bash
pct stop <CTID> && pct destroy <CTID> --purge
```

---

## Reboot-Sicherheit

- CT-Config: `onboot: 1` → Container startet mit dem Proxmox-Host
- `systemctl enable mindwtr` + `Restart=always`, `After=network-online.target docker.service`
- Compose: `restart: always` für beide Container (zweite Verteidigungslinie)
- Docker selbst: `enable docker.service`

## Testdurchlauf (Reboot-Test)

```bash
# 1) Container neu starten
pct reboot <CTID>

# 2) Kurz warten, dann verifizieren
pct exec <CTID> -- systemctl is-active mindwtr          # → active
pct exec <CTID> -- curl -fsS -o /dev/null -w '%{http_code}\n' http://localhost:5173/   # → 200
pct exec <CTID> -- curl -fsS -o /dev/null -w '%{http_code}\n' http://localhost:8787/health  # → 200
pct exec <CTID> -- mindwtr-ctl status
```

Erwartetes Log nach dem Reboot (`pct console <CTID>` bzw. `journalctl -u mindwtr`):

```
mindwtr.service: CORS-Origin gesetzt auf http://192.168.1.50:5173
… Pulling mindwtr-app … Pulling mindwtr-cloud
… Container mindwtr-cloud  Healthy
… Container mindwtr-app    Started
```

---

## Troubleshooting / Debugging

Bei jedem Fehler gibt das Script die **komplette Fehlermeldungskette** aus:
Exit-Code, Zeile, Befehl, Aufrufkette, Service-Status, Docker-/Compose-Logs
und die letzten 40–50 Logzeilen. Logs:

| Was | Wo |
|---|---|
| Host-Installationslog | `/tmp/mindwtr-install-<Zeit>.log` |
| Container-Installationslog | `/var/log/mindwtr-install.log` (im CT) |
| Servicelog | `journalctl -u mindwtr -e` (im CT) |
| Container-/Stack-Status | `pct exec <CTID> -- mindwtr-ctl status` |

Kompletten Ablauf mit Shell-Trace nachvollziehen:

```bash
# Host-Script mit Trace:
bash -x <(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/MindWaterProxmox/main/install/mindwtr.sh)

# Im Container (innerer Installer liegt unter /tmp):
pct exec <CTID> -- bash -x /tmp/mindwtr-inner.sh 5173 8787 "$(pct exec <CTID> -- mindwtr-ctl token)"
```

Häufige Fälle:

- **`pct`/`pveam` nicht gefunden** → Script auf dem PVE-Host ausführen, nicht in einer VM/SSH-Sitzung eines Containers.
- **Keine vztmpl-Storage** → `VZTMP_STORAGE=<name>` setzen (Storage mit Inhaltstyp *Container template*).
- **Images ziehen nicht** (GHCR nicht erreichbar) → Proxy/Firewall des Netzes prüfen; danach `pct exec <CTID> -- mindwtr-ctl update`.
- **PWA lädt, Sync schlägt fehl** → Self-Hosted-URL muss `http://<LXC-IP>:8787` sein (nicht Port 5173); Token mit `mindwtr-ctl token` abgleichen; CORS-Origin prüfen: `pct exec <CTID> -- cat /opt/mindwtr/.env`.
- **PVE-Firewall auf der CT aktiv** → Regeln für TCP `5173` + `8787` anlegen (im Standard-LXC ist keine Firewall aktiv).

---

## Repository-Struktur

```
MindWaterProxmox/
├── install/
│   ├── mindwtr.sh          # Host-Installer (CT-Erstellung, Update-Modus)
│   ├── mindwtr-inner.sh    # In-Container-Installer (Docker, Compose, systemd)
│   ├── mindwtr.service     # systemd-Unit (Restart=always)
│   └── mindwtr-ctl         # Verwaltungshelfer (status/logs/update/token/…)
└── README.md
```

App-Code: [dongdongbh/Mindwtr](https://github.com/dongdongbh/Mindwtr) (AGPL-3.0) –
dieses Repo enthält nur die Proxmox-Integration.
