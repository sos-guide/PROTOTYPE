#!/bin/bash
# sos-guide-reset-starter.sh v2.5
# Réinitialise le Pi en mode STARTER (état sortie d'usine).
#
# Utilisation : sudo bash sos-guide-reset-starter.sh [--force]
#
# Ce que fait ce script :
#   1. Supprime le marqueur d'installation (/var/lib/sos-guide/installed)
#   2. Supprime le token CSRF en cours (/run/sos-guide/firstboot_token)
#   3. Supprime le mot de passe admin (.htpasswd)
#   4. Vide /var/www/sos-guide/ sauf data/ (config.json conservé optionnellement)
#   5. Ré-active le service sos-guide-firstboot
#   6. Relance firstboot.sh ou déclenche un reboot (selon --reboot)
#
# AVERTISSEMENT : action destructive — le Pi retourne à l'état non configuré.
# Accès admin, SSID de production et tous les réglages sont effacés.

set -euo pipefail

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

ok()   { echo -e "  ${GREEN}✔${NC}  $1"; }
warn() { echo -e "  ${YELLOW}⚠${NC}  $1"; }
err()  { echo -e "  ${RED}✘${NC}  $1" >&2; }
info() { echo -e "  ${CYAN}ℹ${NC}  $1"; }

INSTALL_MARKER="/var/lib/sos-guide/installed"
HTPASSWD_FILE="/etc/nginx/.htpasswd"
WEB_DIR="/var/www/sos-guide"
TOKEN_FILE="/run/sos-guide/firstboot_token"
FIRSTBOOT_BIN="/usr/local/bin/firstboot.sh"
FIRSTBOOT_SVC="sos-guide-firstboot.service"

FORCE=false
DO_REBOOT=false
KEEP_CONFIG=false

for arg in "$@"; do
    case "$arg" in
        --force)      FORCE=true ;;
        --reboot)     DO_REBOOT=true ;;
        --keep-config) KEEP_CONFIG=true ;;
    esac
done

if [ "$(id -u)" -ne 0 ]; then
    err "Root requis : sudo bash $0"
    exit 1
fi

echo ""
echo -e "  ${BOLD}${RED}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "  ${BOLD}${RED}║  SOS-GUIDE — RÉINITIALISATION FACTORY RESET              ║${NC}"
echo -e "  ${BOLD}${RED}║  Le Pi va retourner en mode STARTER (non configuré)      ║${NC}"
echo -e "  ${BOLD}${RED}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""

if ! "$FORCE"; then
    echo -e "  ${YELLOW}Cette opération est IRRÉVERSIBLE.${NC}"
    echo -e "  Tous les réglages de production seront effacés."
    echo ""
    read -r -p "  Confirmer la réinitialisation ? (taper OUI pour confirmer) : " CONFIRM
    if [ "$CONFIRM" != "OUI" ]; then
        info "Réinitialisation annulée."
        exit 0
    fi
fi

echo ""
info "Démarrage de la réinitialisation — $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

# 1. Supprimer le marqueur d'installation
if [ -f "$INSTALL_MARKER" ]; then
    rm -f "$INSTALL_MARKER"
    ok "Marqueur d'installation supprimé"
else
    info "Marqueur d'installation déjà absent"
fi

# 2. Supprimer le token CSRF actif
rm -f "$TOKEN_FILE" 2>/dev/null || true
ok "Token CSRF supprimé"

# 3. Supprimer le mot de passe admin
if [ -f "$HTPASSWD_FILE" ]; then
    rm -f "$HTPASSWD_FILE"
    ok ".htpasswd supprimé (admin désactivé)"
fi

# 4. Vider les fichiers web de production (garder data/ si --keep-config)
if command -v chattr &>/dev/null; then
    find "$WEB_DIR" -type f ! -path "$WEB_DIR/data/*" \
        -exec chattr -i {} \; 2>/dev/null || true
fi
find "$WEB_DIR" -type f ! -path "$WEB_DIR/data/*" -delete 2>/dev/null || true
ok "Fichiers web de production supprimés"

if "$KEEP_CONFIG"; then
    info "config.json conservé (--keep-config)"
else
    warn "config.json conservé — les données de lieu persistent (supprimer manuellement si requis)"
fi

# 5. Supprimer les sudoers de production, garder firstboot
rm -f /etc/sudoers.d/sos-guide-reload 2>/dev/null || true
ok "Sudoers de production supprimés"

# 6. Supprimer l'hash d'intégrité (invalide après reset)
rm -f /root/integrity.hash 2>/dev/null || true
rm -f "${WEB_DIR}/INTEGRITY_ALERT.flag" 2>/dev/null || true
ok "Hash d'intégrité supprimé"

# 7. Réactiver le service firstboot
if [ -f "/usr/local/bin/sos-guide-tls-setup.sh" ] || \
   systemctl list-unit-files 2>/dev/null | grep -q "$FIRSTBOOT_SVC"; then
    # Recréer le service si absent
    if ! systemctl list-unit-files 2>/dev/null | grep -q "$FIRSTBOOT_SVC"; then
        cat > "/etc/systemd/system/${FIRSTBOOT_SVC}" <<'UNITEOF'
[Unit]
Description=SOS-GUIDE First Boot Setup
After=network.target
ConditionPathExists=!/var/lib/sos-guide/installed

[Service]
Type=oneshot
ExecStart=/usr/local/bin/firstboot.sh
RemainAfterExit=yes
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
UNITEOF
    fi
    systemctl daemon-reload
    systemctl enable "$FIRSTBOOT_SVC" 2>/dev/null || true
    ok "Service $FIRSTBOOT_SVC réactivé"
fi

echo ""
echo -e "  ${BOLD}${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "  ${BOLD}${GREEN}║  ✅  Factory reset terminé                               ║${NC}"
echo -e "  ${BOLD}${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""

if "$DO_REBOOT"; then
    warn "Redémarrage dans 5 secondes..."
    sleep 5
    reboot
elif [ -x "$FIRSTBOOT_BIN" ]; then
    info "Lancement de firstboot.sh directement (sans reboot)..."
    exec "$FIRSTBOOT_BIN"
else
    warn "firstboot.sh absent — redémarrer le Pi pour activer le mode STARTER"
    info "Commande : sudo reboot"
fi
