#!/usr/bin/env bash
# ============================================================================
#  Mindwtr – Proxmox VE LXC Installer (Community-Scripts-Stil)
#
#  Einzeiler (auf dem Proxmox-Host als root):
#    bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/MindWaterProxmox/main/install/mindwtr.sh)"
#
#  Was es tut:
#    Erstellt einen unprivilegierten Debian-12-LXC (Docker-fähig) und
#    installiert darin Mindwtr (https://github.com/dongdongbh/Mindwtr) aus den
#    offiziellen GHCR-Images:
#      - mindwtr-app   → Web UI / PWA auf Port 5173
#      - mindwtr-cloud → Sync-Server + REST API auf Port 8787
#    Alles läuft lokal im LAN, keine Cloud-Dienste nötig.
#
#  Überschreibbare Umgebungsvariablen (Beispiele):
#    CTID=200 CORES=2 MEM_MB=2048 DISK_GB=8 bash -c "$(wget -qLO - https://...)"
#    MINDWTR_TOKEN="mein-geheimes-token-mind-20-zeichen" ...
#
#  Idempotent: erneutes Ausführen mit gleicher CT-ID = Update/Reparatur
#  (App-Code wird aktualisiert, Daten und Sync-Token bleiben erhalten).
#
#  Deinstallation:
#    pct stop CTID && pct destroy CTID --purge
# ============================================================================

set -Eeuo pipefail

# ───────────────────────────── Variablen ────────────────────────────────────
REPO_USER="${REPO_USER:-HatchetMan111}"
REPO_NAME="${REPO_NAME:-MindWaterProxmox}"
BRANCH="${BRANCH:-main}"
RAW_BASE="https://raw.githubusercontent.com/${REPO_USER}/${REPO_NAME}/${BRANCH}"

APP="mindwtr"
APP_NAME="Mindwtr"
INNER_FILE="mindwtr-inner.sh"

CTID="${CTID:-}"                      # leer → nächste freie CT-ID
HOST_NAME="${HOST_NAME:-mindwtr}"
STORAGE="${STORAGE:-auto}"            # "auto" → erste aktive Storage mit rootdir
VZTMP_STORAGE="${VZTMP_STORAGE:-local}"
NET_BRIDGE="${NET_BRIDGE:-vmbr0}"
PCT_OSTYPE="${PCT_OSTYPE:-debian}"
PCT_OSVERSION="${PCT_OSVERSION:-12}"

CORES="${CORES:-2}"                   # 1-2 vCPU Standard, bei Build mehr
MEM_MB="${MEM_MB:-2048}"              # 2 GB Standard
SWAP_MB="${SWAP_MB:-2048}"
DISK_GB="${DISK_GB:-8}"               # 8 GB Standard

APP_PORT="${APP_PORT:-5173}"           # Web UI / PWA
CLOUD_PORT="${CLOUD_PORT:-8787}"      # Sync-Server / REST API

# Sync-Token: env, oder wird sicher erzeugt (min. 20 Zeichen, wie Mindwtr
# verlangt). Bei Re-Install (Update-Modus) bleibt ein bestehender Token
# unverändert – er ist die Dataset-Identität auf dem Sync-Server!
MINDWTR_TOKEN="${MINDWTR_TOKEN:-}"

HOST_LOG="/tmp/${APP}-install-$(date +%Y%m%d-%H%M%S).log"

# ───────────────────────── Ausgabe-Helfer ───────────────────────────────────
YW='\033[33m'; GN='\033[1;92m'; RD='\033[01;31m'; BL='\033[36m'; CL='\033[m'
CM="${GN}✔${CL}"; CROSS="${RD}✘${CL}"; INFO="${BL}ℹ${CL}"
msg_info()  { echo -e " ${INFO} ${1}"; }
msg_ok()    { echo -e " ${CM} ${1}"; }
msg_fatal() { echo -e " ${CROSS} ${1}" >&2; exit 1; }

# ───────────────────── Vollständige Fehlermeldungskette ─────────────────────
on_error() {
  local ec="$1" ln="$2" cmd="$3"
  echo "" >&2
  echo -e "${RD}━━━━━━━━━━ FEHLERKETTE (vollständig) ━━━━━━━━━━${CL}" >&2
  echo -e " Exit-Code : ${ec}" >&2
  echo -e " Zeile     : ${ln}" >&2
  echo -e " Befehl    : ${cmd}" >&2
  if [[ -n "${CTID:-}" ]] && pct status "${CTID}" >/dev/null 2>&1; then
    echo -e " ── Container-Log (letzte 50 Zeilen) ──" >&2
    pct exec "${CTID}" -- bash -c \
      "tail -n 50 /var/log/mindwtr-install.log 2>/dev/null || true" >&2 || true
    echo -e " ── systemd/Docker im Container ──" >&2
    pct exec "${CTID}" -- bash -c \
      "systemctl status ${APP}.service --no-pager -l 2>&1 | tail -n 25; \
       docker ps -a 2>&1; docker compose -f /opt/mindwtr/compose.yaml logs --tail=40 2>&1" >&2 || true
  fi
  if [[ -s "$HOST_LOG" ]]; then
    echo -e " ── Host-Log: letzte 40 Zeilen (${HOST_LOG}) ──" >&2
    tail -n 40 "$HOST_LOG" >&2 || true
  fi
  echo -e "${YW} Debug-Tipps:${CL}" >&2
  echo -e "  • Trace-Modus: bash -x <(wget -qLO - ${RAW_BASE}/install/${APP}.sh)" >&2
  echo -e "  • Im Container: pct console ${CTID:-<CTID>} → journalctl -u ${APP} -e" >&2
  echo -e "  • Container-Install-Log: /var/log/mindwtr-install.log" >&2
  echo -e "${RD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CL}" >&2
  exit "$ec"
}
trap 'on_error $? $LINENO "$BASH_COMMAND"' ERR

exec > >(tee -a "$HOST_LOG") 2>&1

# ───────────────── 1. Host-Voraussetzungen prüfen ───────────────────────────
[[ $EUID -eq 0 ]] || msg_fatal "Bitte als root auf dem Proxmox-Host ausführen."
command -v pct   >/dev/null || msg_fatal "'pct' nicht gefunden – bitte auf einem Proxmox-VE-Host ausführen."
command -v pveam >/dev/null || msg_fatal "'pveam' nicht gefunden – bitte auf einem Proxmox-VE-Host ausführen."
command -v openssl >/dev/null || msg_fatal "'openssl' fehlt auf dem Host."

echo -e "${GN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CL}"
echo -e "${GN} ${APP_NAME} – LXC Installer (Community-Scripts-Stil)${CL}"
echo -e "${GN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CL}"

# ───────────────── 2. CT-ID ermitteln / Update-Modus ────────────────────────
if [[ -z "$CTID" ]]; then
  CTID="$(pvesh get /cluster/nextid)"
  msg_info "Keine CT-ID angegeben – verwende nächste freie ID: ${CTID}"
fi
if pct status "$CTID" >/dev/null 2>&1; then
  UPDATE_MODE=1
  msg_info "CT ${CTID} existiert bereits → Update-Modus (idempotente Neuinstallation)"
  msg_info "App wird aktualisiert; Daten & Sync-Token bleiben erhalten."
else
  UPDATE_MODE=0
fi

# ─────────────────── 3. Sync-Token handhaben (sicher) ───────────────────────
if [[ "$UPDATE_MODE" -eq 1 ]]; then
  # Bestehenden Token aus dem Container lesen, falls noch nicht per env gesetzt
  if [[ -z "$MINDWTR_TOKEN" ]]; then
    if pct exec "$CTID" -- test -f /root/mindwtr-credentials 2>/dev/null; then
      MINDWTR_TOKEN="$(pct exec "$CTID" -- cat /root/mindwtr-credentials \
                       | grep -E '^MINDWTR_TOKEN=' | cut -d= -f2-)" || true
      [[ -n "$MINDWTR_TOKEN" ]] && msg_info "Bestehenden Sync-Token übernommen (identitätswahrend)."
    fi
  fi
fi
if [[ -z "$MINDWTR_TOKEN" ]]; then
  MINDWTR_TOKEN="$(openssl rand -hex 32)"
  msg_info "Neuen zufälligen Sync-Token erzeugt (wird in CT gespeichert)."
fi
# Token temporär sicher zwischenspeichern, um ihn per pct push zu übertragen
TOKEN_FILE_HOST="$(mktemp)"; chmod 600 "$TOKEN_FILE_HOST"
printf 'MINDWTR_TOKEN=%s\n' "$MINDWTR_TOKEN" > "$TOKEN_FILE_HOST"
trap 'rm -f "$TOKEN_FILE_HOST"' EXIT

# ─────────────────── 4. Container erzeugen (nur bei Neu) ────────────────────
if [[ "$UPDATE_MODE" -eq 0 ]]; then
  msg_info "Storage wird ermittelt"
  if [[ "$STORAGE" == "auto" ]]; then
    STORAGE="$(pvesm status -content rootdir | awk 'NR>1 && $0 ~ /active/ {print $1; exit}')"
  fi
  [[ -n "$STORAGE" ]] || msg_fatal "Keine aktive Storage mit 'rootdir' gefunden. STORAGE=<name> setzen."
  pvesm status -content vztmpl | awk 'NR>1 {print $1}' | grep -qx "$VZTMP_STORAGE" \
    || msg_fatal "Storage '${VZTMP_STORAGE}' unterstützt keine vztmpl-Templates. VZTMP_STORAGE=<name> setzen."
  msg_ok "Rootfs-Storage: ${STORAGE}"

  msg_info "Debian-${PCT_OSVERSION}-Template wird gesucht"
  pveam update >/dev/null
  TEMPLATE="$(pveam available --section system \
              | grep "debian-${PCT_OSVERSION}-standard" | awk '{print $NF}' | sort -r | head -n1)"
  [[ -n "$TEMPLATE" ]] || msg_fatal "Kein debian-${PCT_OSVERSION}-standard-Template gefunden."
  if ! pveam list "$VZTMP_STORAGE" | grep -q "$TEMPLATE"; then
    pveam download "$VZTMP_STORAGE" "$TEMPLATE" >/dev/null
  fi
  msg_ok "Template: ${TEMPLATE}"

  ROOT_PW="$(openssl rand -base64 15)"
  msg_info "LXC-Container ${CTID} wird erstellt (${CORES} vCPU / ${MEM_MB} MB RAM / ${DISK_GB} GB)"
  pct create "$CTID" "${VZTMP_STORAGE}:vztmpl/${TEMPLATE}" \
    --hostname "$HOST_NAME" \
    --cores "$CORES" \
    --memory "$MEM_MB" \
    --swap "$SWAP_MB" \
    --rootfs "${STORAGE}:${DISK_GB}" \
    --net0 "name=eth0,bridge=${NET_BRIDGE},ip=dhcp" \
    --features nesting=1,keyctl=1 \
    --unprivileged 1 \
    --onboot 1 \
    --start 1 \
    --password "$ROOT_PW" \
    --description "Mindwtr GTD Web-App – http://<IP>:${APP_PORT}<br>Sync: http://<IP>:${CLOUD_PORT}<br>Installiert am $(date '+%Y-%m-%d %H:%M')" \
    >/dev/null
  printf '%s\n' "CT ${CTID} (${APP_NAME}) – Root-Passwort: ${ROOT_PW}" > "/root/${APP}-ct${CTID}.credentials"
  chmod 600 "/root/${APP}-ct${CTID}.credentials"
  msg_ok "Container erstellt – onboot aktiv, Root-PW in /root/${APP}-ct${CTID}.credentials"
else
  msg_info "Container wird gestartet (falls gestoppt)"
  pct start "$CTID" 2>/dev/null || true
  # onboot sicherstellen (falls der CT manuell angelegt wurde)
  pct set "$CTID" --onboot 1 2>/dev/null || true
fi

# ───────────────── 5. Auf Netzwerk im Container warten ───────────────────────
msg_info "Warte auf Netzwerk im Container"
NET_OK=0
for _ in $(seq 1 30); do
  if pct exec "$CTID" -- getent hosts deb.debian.org >/dev/null 2>&1; then NET_OK=1; break; fi
  sleep 2
done
[[ "$NET_OK" -eq 1 ]] || msg_fatal "Container ${CTID} hat kein Netzwerk (DNS/Route prüfen: pct exec ${CTID} -- ip a)."
msg_ok "Netzwerk bereit"

# ───────────── 6. Bootstrap + Inner-Script laden und ausführen ───────────────
msg_info "Bootstrap-Pakete im Container (ca-certificates, wget)"
pct exec "$CTID" -- bash -c \
  "export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && apt-get install -y -qq ca-certificates wget >/dev/null"

msg_info "Lade Installations-Script: ${RAW_BASE}/install/${INNER_FILE}"
pct exec "$CTID" -- wget -qO "/tmp/${INNER_FILE}" "${RAW_BASE}/install/${INNER_FILE}"

# Sync-Token ohne Prozesslisten-Exposure in den CT pushen
TOKEN_FILE_CT="/tmp/.mindwtr-token"
pct push "$CTID" "$TOKEN_FILE_HOST" "$TOKEN_FILE_CT" >/dev/null
pct exec "$CTID" -- chmod 600 "$TOKEN_FILE_CT"

msg_info "Installiere ${APP_NAME} im Container (Log: ${HOST_LOG})"
pct exec "$CTID" -- bash -c \
  "MINDWTR_TOKEN=\$(cat '$TOKEN_FILE_CT'); rm -f '$TOKEN_FILE_CT'; \
   bash '/tmp/${INNER_FILE}' '${APP_PORT}' '${CLOUD_PORT}' \"\$MINDWTR_TOKEN\"" 2>&1 | tee -a "$HOST_LOG"

# ──────────────────────────── 7. Abschlussbox ───────────────────────────────
CT_IP="$(pct exec "$CTID" -- hostname -I | awk '{print $1}')"

echo ""
echo -e "${GN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CL}"
echo -e "${GN} ${APP_NAME} erfolgreich installiert!${CL}"
echo -e "${GN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CL}"
echo -e " ${YW}Web UI:${CL}     http://${CT_IP}:${APP_PORT}"
echo -e " ${YW}Sync/API:${CL}   http://${CT_IP}:${CLOUD_PORT}  (Self-Hosted URL in der App)"
echo -e " ${YW}Container:${CL}  CTID ${CTID} (onboot aktiv, reboot-sicher)"
echo -e " ${YW}Services:${CL}   systemctl status ${APP}  (im CT)"
echo -e " ${YW}Logs:${CL}       journalctl -u ${APP} -e  ·  ${HOST_LOG} (Host)"
echo -e " ${YW}Login-Daten:${CL} /root/${APP}-ct${CTID}.credentials · Token im CT: /root/mindwtr-credentials"
echo -e ""
echo -e " ${YW}Sync einrichten:${CL} In der Web UI → Settings → Sync → Self-Hosted"
echo -e "   URL : http://${CT_IP}:${CLOUD_PORT}"
echo -e "   Token: siehe /root/mindwtr-credentials im Container (pct exec ${CTID} -- cat /root/mindwtr-credentials)"
echo -e ""
echo -e " Update   = Einzeiler erneut ausführen (idempotent, Token bleibt erhalten)"
echo -e " Deinstall: pct stop ${CTID} && pct destroy ${CTID} --purge"
echo -e "${GN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CL}"
