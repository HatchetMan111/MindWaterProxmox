#!/usr/bin/env bash
# ============================================================================
#  Mindwtr – In-Container-Installer (wird von mindwtr.sh via pct exec ausgeführt)
#
#  Macht aus einem frischen Debian-12-LXC:
#    Docker → Compose-Stack aus dem offiziellen Mindwtr-Repo (GHCR-Images)
#    → systemd-Service (Reboot-sicher) → Selbstverifikation.
#
#  Aufruf:  mindwtr-inner.sh <APP_PORT> <CLOUD_PORT> <MINDWTR_TOKEN>
#
#  Idempotent: beliebig oft re-launchbar (Update/Reparatur). Bestehende
#  Docker-Volumes/Daten werden nie gelöscht.
# ============================================================================

set -Eeuo pipefail

APP_PORT="${1:-5173}"
CLOUD_PORT="${2:-8787}"
MINDWTR_TOKEN="${3:?MINDWTR_TOKEN fehlt (Parameter 3)}"

APP_DIR="/opt/mindwtr"
SERVICE="mindwtr"
LOGFILE="/var/log/mindwtr-install.log"
UPSTREAM_REPO="https://github.com/dongdongbh/Mindwtr"
UPSTREAM_RAW="https://raw.githubusercontent.com/dongdongbh/Mindwtr/main"

exec > >(tee -a "$LOGFILE") 2>&1

info() { echo -e " \e[1;92m➤\e[0m $*"; }
warn() { echo -e " \e[1;33m⚠\e[0m $*"; }
ok()   { echo -e " \e[1;92m✔\e[0m $*"; }

on_error() {
  local exit_code=$1 line=$2 command_=${3:-}
  echo "" >&2
  echo "======================================================================" >&2
  echo "FEHLER: Mindwtr-In-Container-Installation abgebrochen" >&2
  echo "  Exit-Code : $exit_code" >&2
  echo "  Zeile     : $line" >&2
  echo "  Befehl    : $command_" >&2
  echo "--- Aufrufkette ---" >&2
  local i
  for ((i = 1; i < ${#FUNCNAME[@]}; i++)); do
    echo "  - ${FUNCNAME[i]} (${BASH_SOURCE[i]:-?}:${BASH_LINENO[i - 1]:-?})" >&2
  done
  echo "--- Service-Status ---" >&2
  systemctl status "$SERVICE" --no-pager -l 2>&1 | tail -n 25 >&2 || true
  echo "--- Docker-Status ---" >&2
  docker ps -a >&2 || true
  echo "--- Compose-Logs (letzte 50 Zeilen) ---" >&2
  (cd "$APP_DIR" && docker compose -f compose.yaml --env-file .env logs --tail=50) >&2 || true
  echo "--- Letzte 40 Logzeilen ($LOGFILE) ---" >&2
  tail -n 40 "$LOGFILE" >&2 || true
  echo "----------------------------------------------------------------------" >&2
  echo "Vollständiges Log : $LOGFILE" >&2
  echo "Mit Shell-Trace   : bash -x /tmp/mindwtr-inner.sh" >&2
  echo "======================================================================" >&2
}
trap 'on_error $? $LINENO "$BASH_COMMAND"' ERR

[[ $(id -u) -eq 0 ]] || { echo "Bitte als root im Container ausführen." >&2; exit 1; }

# Token-Format prüfen (Mindwtr verlangt 20–512 Zeichen)
if [[ ! "$MINDWTR_TOKEN" =~ ^.{20,512}$ ]]; then
  echo "FEHLER: Sync-Token muss 20–512 Zeichen lang sein (ist: ${#MINDWTR_TOKEN})." >&2
  exit 1
fi

# Bestehenden Token bevorzugen: Der Token ist die Dataset-Identität auf dem
# Sync-Server – versehentliches Rotieren bei Re-Install würde die alten Daten
# "verlieren" (sie blieben unangetastet unter dem alten Token liegen).
if [[ -f /root/mindwtr-credentials ]]; then
  EXISTING_TOKEN="$(grep -E '^MINDWTR_TOKEN=' /root/mindwtr-credentials | cut -d= -f2- || true)"
  if [[ -n "$EXISTING_TOKEN" && "$EXISTING_TOKEN" != "$MINDWTR_TOKEN" ]]; then
    warn "Übergebener Token weicht vom bestehenden ab – bestehender Token wird beibehalten."
  fi
  [[ -n "$EXISTING_TOKEN" ]] && MINDWTR_TOKEN="$EXISTING_TOKEN"
fi

# ───────────────────────────── 1. Systempakete ──────────────────────────────
info "Systempakete installieren"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
  ca-certificates curl gnupg git jq openssl >/dev/null

# ───────────────────────────── 2. Docker installieren ──────────────────────
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  ok "Docker bereits funktionsfähig – überspringe Installation."
else
  info "Docker Engine wird installiert (get.docker.com, Debian-Repo)"
  curl -fsSL https://get.docker.com | sh
fi
systemctl enable --now docker.service
ok "Docker $(docker --version | awk '{print $3}' | tr -d ',') aktiv"

# Docker Compose Plugin sicherstellen
if ! docker compose version >/dev/null 2>&1; then
  info "Docker Compose Plugin wird nachinstalliert"
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends docker-compose-plugin
fi

# ─────────────────────── 3. App-Verzeichnis + Compose ──────────────────────
info "Compose-Konfiguration aus dem offiziellen Mindwtr-Repo laden"
mkdir -p "$APP_DIR"
cd "$APP_DIR"
wget -qO compose.yaml "${UPSTREAM_RAW}/docker/compose.yaml"
ok "compose.yaml geladen (Quelle: ${UPSTREAM_REPO})"

# Datenverzeichnis: der Cloud-Container läuft als uid 1000 (bun) und bindet
# ./data → /app/cloud_data. Docker würde das Verzeichnis beim Start als root
# anlegen → der Server bricht mit 'data_dir_not_writable' ab. Deshalb hier
# explizit an uid 1000 übergeben (Anforderung aus dem Upstream-Docker-README).
mkdir -p "$APP_DIR/data"
chown -R 1000:1000 "$APP_DIR/data"
ok "Datenverzeichnis $APP_DIR/data bereit (Besitzer uid 1000)"

# ───────────────────── 4. Sync-Token + Umgebung erzeugen ────────────────────
# CORS-Origin: bei DHCP kann sich die IP ändern → wird vom systemd-Service
# bei jedem Start frisch in die .env geschrieben (siehe mindwtr-ctl refresh-env).
info "Ermittle Container-IP"
CT_IP="$(hostname -I | awk '{print $1}')"
info "Schreibe /root/mindwtr-credentials (Token bleibt bei Updates erhalten)"
printf 'MINDWTR_TOKEN=%s\n' "$MINDWTR_TOKEN" > /root/mindwtr-credentials
chmod 600 /root/mindwtr-credentials

# Port-Mapping anpassen, falls nicht Standard-Ports verwendet werden
if [[ "$APP_PORT" != "5173" || "$CLOUD_PORT" != "8787" ]]; then
  info "Passe Port-Mapping an: App=${APP_PORT}, Cloud=${CLOUD_PORT}"
  sed -i \
    -e "s|^\(\s*\)-\s*5173:5173$|\1- ${APP_PORT}:5173|" \
    -e "s|^\(\s*\)-\s*8787:8787$|\1- ${CLOUD_PORT}:8787|" \
    compose.yaml
fi

# Ports + Helfer für spätere CORS-Refreshes bereitstellen
cat > /etc/mindwtr.env <<EOF
APP_PORT=${APP_PORT}
CLOUD_PORT=${CLOUD_PORT}
EOF
chmod 600 /etc/mindwtr.env
INSTALL_BASE="https://raw.githubusercontent.com/HatchetMan111/MindWaterProxmox/main/install"
wget -qO /usr/local/bin/mindwtr-ctl "${INSTALL_BASE}/mindwtr-ctl"
chmod +x /usr/local/bin/mindwtr-ctl
/usr/local/bin/mindwtr-ctl refresh-env
ok "Helfer /usr/local/bin/mindwtr-ctl installiert (refresh-env|update|logs|token|status|run|down)"

# ───────────────────────── 5. systemd-Service ───────────────────────────────
info "systemd-Service wird eingerichtet"
wget -qO "/etc/systemd/system/${SERVICE}.service" "${INSTALL_BASE}/mindwtr.service"
systemctl daemon-reload
systemctl enable "${SERVICE}.service" >/dev/null 2>&1
ok "Service aktiviert (enable, After=network-online.target, Restart=always)"

# ───────────────────────────── 6. Start ────────────────────────────────────
info "Lade Docker-Images (ghcr.io/dongdongbh/mindwtr-app, mindwtr-cloud)"
docker compose -f "$APP_DIR/compose.yaml" --env-file "$APP_DIR/.env" pull
info "Starte Mindwtr-Stack via systemd"
systemctl restart "${SERVICE}.service"
ok "Service gestartet"

# ───────────────────────── 7. Selbstverifikation ───────────────────────────
info "Warte bis Web UI und Sync-Server antworten (max. 240 s)"
HTTP_OK_APP=0; HTTP_OK_CLOUD=0
for _ in $(seq 1 80); do
  if [[ "$HTTP_OK_APP" -eq 0 ]] && curl -fsS -o /dev/null --max-time 3 "http://localhost:${APP_PORT}/"; then HTTP_OK_APP=1; fi
  if [[ "$HTTP_OK_CLOUD" -eq 0 ]] && curl -fsS -o /dev/null --max-time 3 "http://localhost:${CLOUD_PORT}/health"; then HTTP_OK_CLOUD=1; fi
  [[ "$HTTP_OK_APP" -eq 1 && "$HTTP_OK_CLOUD" -eq 1 ]] && break
  # Fail-fast: Crashloop erkennen (z. B. Rechte-/Konfigurationsfehler), statt
  # die volle Wartezeit zu verbrauchen – Logs sofort in die Fehlerkette.
  if [[ "$HTTP_OK_CLOUD" -eq 0 ]]; then
    RESTARTS="$(docker inspect -f '{{.RestartCount}}' mindwtr-cloud 2>/dev/null || echo 0)"
    if [[ "${RESTARTS:-0}" -ge 5 ]]; then
      echo "FEHLER: mindwtr-cloud startet wiederholt neu (RestartCount=${RESTARTS}) – siehe Container-Logs." >&2
      docker logs mindwtr-cloud --tail 30 >&2 || true
      exit 1
    fi
  fi
  sleep 3
done
if [[ "$HTTP_OK_APP" -eq 0 || "$HTTP_OK_CLOUD" -eq 0 ]]; then
  echo "FEHLER: Services antworten nicht (App=${HTTP_OK_APP}, Cloud-Health=${HTTP_OK_CLOUD})." >&2
  echo "--- Service-Status ---"; systemctl status "$SERVICE" --no-pager -l | tail -n 25 >&2
  echo "--- Docker ---"; docker ps -a >&2
  echo "--- Compose-Logs ---"; (cd "$APP_DIR" && docker compose -f compose.yaml --env-file .env logs --tail=50) >&2
  exit 1
fi
ok "Web UI antwortet:  http://localhost:${APP_PORT}/  → HTTP 200"
ok "Sync-Server health: http://localhost:${CLOUD_PORT}/health → HTTP 200"

SVC_STATE="$(systemctl is-active ${SERVICE})"
[[ "$SVC_STATE" == "active" ]] || { echo "FEHLER: Service ist '${SVC_STATE}' statt active." >&2; exit 1; }
ok "systemd-Service: active (enabled, Restart=always)"

# Firewall: LXC hat normalerweise keine iptables-Regeln; Port öffnen, falls aktiv
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
  ufw allow "${APP_PORT}/tcp" >/dev/null
  ufw allow "${CLOUD_PORT}/tcp" >/dev/null
  ok "ufw: Ports ${APP_PORT}, ${CLOUD_PORT} freigegeben"
fi

echo ""
echo "======================================================================"
echo " Mindwtr im Container installiert und verifiziert"
echo "   Web UI : http://${CT_IP}:${APP_PORT}"
echo "   Sync   : http://${CT_IP}:${CLOUD_PORT}   (Self-Hosted URL in der App)"
echo "   Token  : /root/mindwtr-credentials (im Container)"
echo "======================================================================"
