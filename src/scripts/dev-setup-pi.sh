#!/bin/bash
# SOS-GUIDE — Configuration du Raspberry Pi en mode développement
#
# Lance depuis la machine de dev :
#   bash src/scripts/dev-setup-pi.sh
#
# Prérequis : sudo passwordless actif sur le Pi (voir README)
#   ! ssh -t admin@192.168.1.133 "sudo bash -c 'echo admin ALL=\(ALL\) NOPASSWD:ALL > /etc/sudoers.d/90-sos-tmp'"
#
# Ce script :
#   - Installe nginx + php8.4-fpm sur le Pi (via apt)
#   - Déploie les fichiers SOS-GUIDE dans /var/www/sos-guide/
#   - Configure nginx en mode dev (port 80, pas de hostapd/dnsmasq/iptables)
#   - Active le routeur dev (bascule STARTER ↔ PRODUCTION depuis le navigateur)
#   - Conserve Kronos intact (ports 18080-18082 non touchés)

set -euo pipefail

PI="admin@192.168.1.133"
V3="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WEB_REMOTE="/var/www/sos-guide"

GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}✔${NC}  $1"; }
info() { echo -e "  ${CYAN}ℹ${NC}  $1"; }
step() { echo -e "\n  ${BOLD}▶${NC}  ${BOLD}$1${NC}"; }

echo ""
echo "════════════════════════════════════════════════════"
echo "  SOS-GUIDE — Dev Setup Pi (192.168.1.133)"
echo "════════════════════════════════════════════════════"

# ── Vérification SSH ──────────────────────────────────────────────────────────
step "Vérification accès SSH + sudo"
ssh -q "$PI" "sudo -n true" || {
    echo ""
    echo "  Sudo passwordless requis. Lance d'abord :"
    echo "  ! ssh -t admin@192.168.1.133 \"sudo bash -c 'echo admin ALL=\\(ALL\\) NOPASSWD:ALL > /etc/sudoers.d/90-sos-tmp'\""
    exit 1
}
ok "SSH + sudo OK"

# ── Installation des paquets ──────────────────────────────────────────────────
step "Installation nginx + php8.4-fpm sur le Pi"
ssh "$PI" "sudo apt-get update -qq && \
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    nginx php8.4-fpm php8.4-mbstring php8.4-gd php8.4-intl php8.4-curl apache2-utils"
ok "Paquets installés"

# ── Déploiement des fichiers web ──────────────────────────────────────────────
step "Déploiement des sources vers le Pi"

ssh "$PI" "sudo mkdir -p $WEB_REMOTE/data && sudo chown -R admin:admin $WEB_REMOTE"

# Portail (index.html, data/, img/, lib/)
rsync -az --delete \
    --exclude='config.json' \
    "$V3/src/web/" "$PI:$WEB_REMOTE/"
ok "src/web/ → $WEB_REMOTE/"

# starter.html comme template (tokens injectés par dev-router.php à la volée)
rsync -az "$V3/src/firstboot/starter.html"    "$PI:$WEB_REMOTE/starter-template.html"
rsync -az "$V3/src/firstboot/api_install.php" "$PI:$WEB_REMOTE/"
rsync -az "$V3/src/firstboot/qrcode.min.js"  "$PI:$WEB_REMOTE/" 2>/dev/null || true
ok "src/firstboot/ → $WEB_REMOTE/"

# Fichiers dev (routeur + switch)
rsync -az "$V3/src/dev/dev-router.php"  "$PI:$WEB_REMOTE/"
rsync -az "$V3/src/dev/dev-switch.php"  "$PI:$WEB_REMOTE/"
ok "src/dev/ → $WEB_REMOTE/"

# ── Configuration distante ────────────────────────────────────────────────────
step "Configuration nginx + PHP-FPM + sudoers sur le Pi"
ssh "$PI" "sudo bash -s" << 'REMOTE'
set -euo pipefail

WEB_DIR="/var/www/sos-guide"
PHP_VER=$(php -v 2>/dev/null | head -n1 | cut -d' ' -f2 | cut -d'.' -f1-2)
[ -z "$PHP_VER" ] && PHP_VER="8.4"

# ── Répertoires runtime ───────────────────────────────────────────────────────
mkdir -p /var/lib/sos-guide /var/log
touch /var/log/sos-guide-firstboot-audit.log

# ── config.json par défaut (préservé si existant) ─────────────────────────────
CONFIG="$WEB_DIR/data/config.json"
if [ ! -f "$CONFIG" ]; then
    cat > "$CONFIG" << 'CFGEOF'
{
  "establishment": { "name": "SOS-GUIDE DEV", "address": "", "lat": "", "lon": "", "type": "erp",
    "localCrisisNumber": "", "localRisk": "", "localSamuNumber": "", "localPoliceNumber": "",
    "localPompiersNumber": "", "localMairieNumber": "", "localPrefecture": "", "localDsden": "",
    "localRadioFreq": "", "localCroixRouge": "", "localPccAddress": "", "localMeetingPoint": "",
    "localEvacuationPlan": "" },
  "reassurance": { "message": "Restez calme, les secours sont informés et arrivent." },
  "wifiChannel": 11, "enableLoRa": false, "enableEthernet": false, "installed": false
}
CFGEOF
fi

# ── Compte admin dev ──────────────────────────────────────────────────────────
htpasswd -cb /etc/nginx/.htpasswd admin dev-sos-guide 2>/dev/null
chmod 640 /etc/nginx/.htpasswd

# ── Config nginx dev (port 80, pas d'AP ni iptables) ─────────────────────────
cat > /etc/nginx/sites-available/sos-guide-dev << NGINXEOF
server {
    listen 80 default_server;
    server_name _;
    root $WEB_DIR;
    index dev-router.php;

    access_log /var/log/nginx/sos-guide-access.log;
    error_log  /var/log/nginx/sos-guide-error.log warn;

    location = /dev-switch {
        include /etc/nginx/fastcgi_params;
        fastcgi_param SCRIPT_FILENAME $WEB_DIR/dev-switch.php;
        fastcgi_pass unix:/run/php/php${PHP_VER}-fpm.sock;
    }

    location = /api/install {
        include /etc/nginx/fastcgi_params;
        fastcgi_param SCRIPT_FILENAME $WEB_DIR/api_install.php;
        fastcgi_param REMOTE_ADDR     "127.0.0.1";
        fastcgi_pass unix:/run/php/php${PHP_VER}-fpm.sock;
    }

    location /admin {
        auth_basic "Administration SOS-GUIDE";
        auth_basic_user_file /etc/nginx/.htpasswd;
        try_files \$uri \$uri/ =404;
        location ~ \\.php$ {
            include /etc/nginx/fastcgi_params;
            fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
            fastcgi_pass unix:/run/php/php${PHP_VER}-fpm.sock;
        }
    }

    location ~ \\.php$ {
        include /etc/nginx/fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_pass unix:/run/php/php${PHP_VER}-fpm.sock;
    }

    location /data/ { add_header Cache-Control "no-store"; }

    location / {
        try_files \$uri \$uri/ /dev-router.php;
        add_header Cache-Control "no-store";
    }

    location ~ /\\.    { deny all; }
    location ~* \\.(sh|conf|log|sql)$ { deny all; }
}
NGINXEOF

ln -sf /etc/nginx/sites-available/sos-guide-dev /etc/nginx/sites-enabled/sos-guide-dev
rm -f /etc/nginx/sites-enabled/default
nginx -t

# ── Mock finalize_install.sh ──────────────────────────────────────────────────
cat > /usr/local/bin/finalize_install.sh << 'MOCKEOF'
#!/bin/bash
mkdir -p /var/lib/sos-guide
echo "dev-installed" > /var/lib/sos-guide/installed
chmod 400 /var/lib/sos-guide/installed
exit 0
MOCKEOF
chmod +x /usr/local/bin/finalize_install.sh

# ── Sudoers www-data ──────────────────────────────────────────────────────────
cat > /etc/sudoers.d/sos-guide-dev << 'SUDOEOF'
www-data ALL=(root) NOPASSWD: /usr/local/bin/finalize_install.sh
SUDOEOF
chmod 440 /etc/sudoers.d/sos-guide-dev
visudo -cf /etc/sudoers.d/sos-guide-dev

# ── Permissions ───────────────────────────────────────────────────────────────
chown -R www-data:www-data "$WEB_DIR"
chmod -R u+rw,g+r "$WEB_DIR"
chown www-data:www-data /var/log/sos-guide-firstboot-audit.log

# ── Démarrage services ────────────────────────────────────────────────────────
systemctl enable "php${PHP_VER}-fpm" nginx
systemctl restart "php${PHP_VER}-fpm" nginx
REMOTE

ok "nginx + PHP-FPM configurés et démarrés"

# ── Nettoyage sudo temporaire ─────────────────────────────────────────────────
step "Nettoyage sudo temporaire"
ssh "$PI" "sudo rm -f /etc/sudoers.d/90-sos-tmp" 2>/dev/null || true
ok "Sudo temporaire retiré"

# ── Résumé ────────────────────────────────────────────────────────────────────
echo ""
echo -e "  ${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "  ${BOLD}║  SOS-GUIDE DEV — Pi prêt                            ║${NC}"
echo -e "  ${BOLD}╠══════════════════════════════════════════════════════╣${NC}"
echo -e "  ${BOLD}║  Starter   : http://192.168.1.133/                   ║${NC}"
echo -e "  ${BOLD}║  Bascule   : bouton ⇄ dans la barre DEV              ║${NC}"
echo -e "  ${BOLD}║  Admin     : http://192.168.1.133/admin               ║${NC}"
echo -e "  ${BOLD}║              login: admin / dev-sos-guide             ║${NC}"
echo -e "  ${BOLD}╠══════════════════════════════════════════════════════╣${NC}"
echo -e "  ${BOLD}║  Sync temps réel :                                   ║${NC}"
echo -e "  ${BOLD}║    bash src/scripts/sync.sh                          ║${NC}"
echo -e "  ${BOLD}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
