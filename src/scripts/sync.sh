#!/bin/bash
# SOS-GUIDE — Synchronisation temps réel V3/src/ → Pi 192.168.1.133
#
# Lance depuis la racine du projet :
#   bash src/scripts/sync.sh
#
# Prérequis : clé SSH configurée pour admin@192.168.1.133
# Optionnel  : inotify-tools (pacman -S inotify-tools) pour le temps réel
#              Sinon : polling toutes les 2s

PI="admin@192.168.1.133"
WEB_REMOTE="/var/www/sos-guide"
V3="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; NC='\033[0m'; BOLD='\033[1m'
ok()   { echo -e "  ${GREEN}✔${NC}  $1"; }
info() { echo -e "  ${CYAN}ℹ${NC}  $1"; }
warn() { echo -e "  ${YELLOW}⚠${NC}  $1"; }

# ── Transfert vers le Pi ──────────────────────────────────────────────────────
sync_to_pi() {
    local errs=0

    # Portail production (index.html, data/, img/, lib/)
    rsync -az --no-perms --no-group --no-owner --omit-dir-times --delete \
        --exclude='config.json' \
        --exclude='dev-router.php' \
        --exclude='dev-switch.php' \
        "$V3/src/web/" "$PI:$WEB_REMOTE/" 2>/dev/null || errs=$((errs+1))

    # Starter : copié comme template (token injecté par dev-router.php à la volée)
    rsync -az --no-perms --no-group --no-owner \
        "$V3/src/firstboot/starter.html" \
        "$PI:$WEB_REMOTE/starter-template.html" 2>/dev/null || errs=$((errs+1))

    # API firstboot
    rsync -az --no-perms --no-group --no-owner \
        "$V3/src/firstboot/api_install.php" \
        "$PI:$WEB_REMOTE/" 2>/dev/null || errs=$((errs+1))

    rsync -az --no-perms --no-group --no-owner \
        "$V3/src/firstboot/qrcode.min.js" \
        "$PI:$WEB_REMOTE/" 2>/dev/null || true  # optionnel

    # Fichiers dev (routeur + switch)
    rsync -az --no-perms --no-group --no-owner \
        "$V3/src/dev/dev-router.php" \
        "$V3/src/dev/dev-switch.php" \
        "$PI:$WEB_REMOTE/" 2>/dev/null || errs=$((errs+1))

    if [ "$errs" -eq 0 ]; then
        ok "$(date '+%H:%M:%S')  sync OK"
    else
        warn "$(date '+%H:%M:%S')  sync avec ${errs} erreur(s)"
    fi
}

# ── Démarrage ─────────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════"
echo "  SOS-GUIDE Sync → $PI"
echo "  Source : $V3/src/"
echo "════════════════════════════════════════════════════"

info "Sync initial..."
sync_to_pi

# ── Surveillance des changements ──────────────────────────────────────────────
WATCH_DIRS=(
    "$V3/src/web"
    "$V3/src/firstboot"
    "$V3/src/dev"
)

if command -v inotifywait &>/dev/null; then
    info "Mode temps réel actif (inotifywait)"
    inotifywait -mrq -e modify,create,delete,move "${WATCH_DIRS[@]}" | while read -r _dir _event _file; do
        # Debounce 400ms : absorbe les sauvegardes en rafale (éditeurs)
        while read -t 0.4 -r _; do :; done
        sync_to_pi
    done
else
    warn "inotify-tools absent — polling 2s (pacman -S inotify-tools pour le temps réel)"
    PREV_HASH=""
    while true; do
        sleep 2
        CURR_HASH=$(find "${WATCH_DIRS[@]}" -type f -exec stat -c '%Y %n' {} \; 2>/dev/null | md5sum | cut -c1-8)
        if [ "$CURR_HASH" != "$PREV_HASH" ]; then
            sync_to_pi
            PREV_HASH="$CURR_HASH"
        fi
    done
fi
