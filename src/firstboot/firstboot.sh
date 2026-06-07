#!/bin/bash
# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  SOS-GUIDE First Boot v2.5 — Mode STARTER                                  ║
# ║                                                                              ║
# ║  ✅ SUPPRESSION du PIN HDMI physique (bloquant sans écran)                   ║
# ║  ✅ Réseau WiFi toujours ouvert (aucun mot de passe)                          ║
# ║  ✅ Token CSRF one-shot                                                        ║
# ║  ✅ Détection dynamique d'interface WiFi                                       ║
# ║  ✅ Sans reboot système                                                        ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

# ── Couleurs ─────────────────────────────────────────────────────────────────
RED='\033[0;31m';  GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m';    NC='\033[0m'
ok()   { echo -e "  ${GREEN}✔${NC}  $1"; }
warn() { echo -e "  ${YELLOW}⚠${NC}  $1"; }
err()  { echo -e "  ${RED}✘${NC}  $1" >&2; }
info() { echo -e "  ${CYAN}ℹ${NC}  $1"; }

# ── Chemins ──────────────────────────────────────────────────────────────────
WEB_DIR="/var/www/sos-guide"
CONFIG_JSON="$WEB_DIR/data/config.json"
RUNTIME_DIR="/run/sos-guide"
TOKEN_FILE="$RUNTIME_DIR/firstboot_token"
RATE_FILE="$RUNTIME_DIR/rate_limit"
LOG_FILE="/var/log/sos-guide-firstboot.log"

exec >> "$LOG_FILE" 2>&1
echo ""
echo "══════════════════════════════════════════════"
echo "  SOS-GUIDE firstboot v2.5 — $(date '+%Y-%m-%d %H:%M:%S')"
echo "══════════════════════════════════════════════"

# ── Vérifications ────────────────────────────────────────────────────────────
[ "$(id -u)" -eq 0 ] || { err "Root requis"; exit 1; }

if [ -f "/var/lib/sos-guide/installed" ]; then
    info "Système déjà installé — firstboot ignoré"
    exit 0
fi

# ── Répertoire runtime sécurisé ──────────────────────────────────────────────
mkdir -p "$RUNTIME_DIR"
chmod 700 "$RUNTIME_DIR"
rm -f "$TOKEN_FILE" "$RATE_FILE"

# ── Génération du token CSRF one-shot ─────────────────────────────────────────
TOKEN=$(openssl rand -hex 32)
echo "$TOKEN" > "$TOKEN_FILE"
chmod 400 "$TOKEN_FILE"
ok "Token CSRF généré"

# ── Détection dynamique de l'interface WiFi ──────────────────────────────────
WIFI_IFACE=""
for iface in /sys/class/net/*; do
    iface=$(basename "$iface")
    if iw dev "$iface" info &>/dev/null 2>&1; then
        WIFI_IFACE="$iface"
        break
    fi
done
if [ -z "$WIFI_IFACE" ]; then
    WIFI_IFACE=$(ip link show | awk '/wl/{print $2}' | tr -d ':' | head -1)
fi
[ -z "$WIFI_IFACE" ] && { err "Aucune interface WiFi détectée"; exit 1; }
ok "Interface WiFi : $WIFI_IFACE"

# ── Sélection automatique du canal WiFi ──────────────────────────────────────
CHANNEL=11
if command -v iw &>/dev/null; then
    SCAN=$(iw dev "$WIFI_IFACE" scan 2>/dev/null | grep "DS Parameter" | \
           grep -oP 'channel \K\d+' | sort | uniq -c | sort -rn || true)
    C1=$(echo "$SCAN" | awk '$2==1{print $1}');  C1=${C1:-0}
    C6=$(echo "$SCAN" | awk '$2==6{print $1}');  C6=${C6:-0}
    C11=$(echo "$SCAN" | awk '$2==11{print $1}'); C11=${C11:-0}
    if   [ "$C1"  -le "$C6"  ] && [ "$C1"  -le "$C11" ]; then CHANNEL=1
    elif [ "$C6"  -le "$C1"  ] && [ "$C6"  -le "$C11" ]; then CHANNEL=6
    else CHANNEL=11; fi
    ok "Canal WiFi auto-sélectionné : $CHANNEL"
else
    ok "Canal WiFi par défaut : $CHANNEL"
fi

# ── Arrêt des services existants ─────────────────────────────────────────────
systemctl stop hostapd dnsmasq nginx 2>/dev/null || true

# ── Configuration hostapd STARTER — réseau ouvert ────────────────────────────
cat > /etc/hostapd/hostapd.conf <<EOF
interface=${WIFI_IFACE}
driver=nl80211
ssid=⛑️ SOS-GUIDE - STARTER
hw_mode=g
channel=${CHANNEL}
wmm_enabled=1
macaddr_acl=0
auth_algs=1
ignore_broadcast_ssid=0
wpa=0
country_code=FR
ieee80211d=1
ieee80211n=1
ap_isolate=0
EOF

cat > /etc/default/hostapd <<EOF
DAEMON_CONF="/etc/hostapd/hostapd.conf"
DAEMON_OPTS=""
EOF

ok "hostapd STARTER ouvert configuré (canal $CHANNEL)"

# ── Configuration réseau IP statique ─────────────────────────────────────────
ip link set "$WIFI_IFACE" down 2>/dev/null || true
sleep 0.5
ip link set "$WIFI_IFACE" up
ip addr flush dev "$WIFI_IFACE" 2>/dev/null || true
ip addr add 10.0.0.1/24 dev "$WIFI_IFACE" 2>/dev/null || true
ok "IP 10.0.0.1/24 sur $WIFI_IFACE"

# ── Configuration dnsmasq STARTER ────────────────────────────────────────────
cat > /etc/dnsmasq.conf <<EOF
interface=${WIFI_IFACE}
bind-interfaces
dhcp-range=10.0.0.100,10.0.0.200,1h
dhcp-option=3,10.0.0.1
dhcp-option=6,10.0.0.1
dhcp-option=114,"http://10.0.0.1/"
address=/#/10.0.0.1
no-resolv
no-hosts
cache-size=0
log-facility=/dev/null
EOF
ok "dnsmasq STARTER configuré"

# ── PHP-FPM : détection version ──────────────────────────────────────────────
PHP_VERSION=$(php -v 2>/dev/null | head -n1 | cut -d' ' -f2 | cut -d'.' -f1-2)
[ -z "$PHP_VERSION" ] && PHP_VERSION="8.2"
ok "PHP-FPM version : $PHP_VERSION"

# ── Copie des fichiers firstboot ──────────────────────────────────────────────
mkdir -p "$WEB_DIR/data"

BOOT_PATHS=("/boot/firmware/firstboot" "/boot/firstboot")
FOUND_BOOT=""
for bp in "${BOOT_PATHS[@]}"; do
    [ -f "$bp/starter.html" ] && { FOUND_BOOT="$bp"; break; }
done

if [ -z "$FOUND_BOOT" ]; then
    err "Fichiers firstboot introuvables"
    exit 1
fi

cp "$FOUND_BOOT/starter.html"        "$WEB_DIR/"
cp "$FOUND_BOOT/api_install.php"     "$WEB_DIR/"
cp "$FOUND_BOOT/finalize_install.sh" /usr/local/bin/ 2>/dev/null || true
chmod +x /usr/local/bin/finalize_install.sh 2>/dev/null || true

chown www-data:www-data "$WEB_DIR/starter.html" "$WEB_DIR/api_install.php"
chmod 644 "$WEB_DIR/starter.html"
chmod 640 "$WEB_DIR/api_install.php"
ok "Fichiers firstboot copiés depuis $FOUND_BOOT"

# ── Injection des variables dans starter.html ─────────────────────────────────
# v2.5 : injecter CSRF + canal + SSID (réseau STARTER ouvert, plus de PIN)
STARTER_SSID="⛑️ SOS-GUIDE - STARTER"
sed -i "s|%%CSRF_TOKEN%%|$TOKEN|g"     "$WEB_DIR/starter.html"
sed -i "s|%%WIFI_CHANNEL%%|$CHANNEL|g" "$WEB_DIR/starter.html"
sed -i "s|%%STARTER_SSID%%|$STARTER_SSID|g" "$WEB_DIR/starter.html"
chown www-data:www-data "$WEB_DIR/starter.html"
ok "Variables injectées dans starter.html (SSID + CSRF)"

# ── Création du config.json initial ──────────────────────────────────────────
if [ ! -f "$CONFIG_JSON" ]; then
    cat > "$CONFIG_JSON" <<CONFIGEOF
{
  "establishment": { "name": "", "address": "" },
  "reassurance": { "message": "" },
  "wifiChannel": ${CHANNEL},
  "installed": false
}
CONFIGEOF
    chown www-data:www-data "$CONFIG_JSON"
    chmod 640 "$CONFIG_JSON"
    ok "config.json initial créé"
fi

# ── Configuration nginx STARTER ───────────────────────────────────────────────
cat > /etc/nginx/sites-available/sos-guide <<NGINXEOF
server {
    listen 80 default_server;
    server_name _;
    root /var/www/sos-guide;
    index starter.html;
    access_log off;
    error_log /dev/null;

    location = /hotspot-detect.html       { return 302 http://10.0.0.1/; }
    location = /library/test/success.html { return 302 http://10.0.0.1/; }
    location = /generate_204              { return 302 http://10.0.0.1/; }
    location = /gen_204                   { return 302 http://10.0.0.1/; }
    location = /connecttest.txt           { return 302 http://10.0.0.1/; }
    location = /ncsi.txt                  { return 302 http://10.0.0.1/; }
    location = /success.txt               { return 302 http://10.0.0.1/; }

    location = /api/install {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/var/run/php/php${PHP_VERSION}-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root/api_install.php;
    }

    location / {
        try_files \$uri \$uri/ /starter.html;
    }

    location ~ /\.              { deny all; }
    location ~* \.(env|ini|log|sh|sql|conf|cfg)$ { deny all; }
}
NGINXEOF

ln -sf /etc/nginx/sites-available/sos-guide /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default

if ! nginx -t &>/dev/null; then
    err "Nginx : configuration invalide"
    exit 1
fi
ok "nginx configuré"

# ── Démarrage des services ────────────────────────────────────────────────────
systemctl unmask hostapd dnsmasq nginx 2>/dev/null || true
systemctl enable hostapd dnsmasq nginx "php${PHP_VERSION}-fpm"

systemctl start "php${PHP_VERSION}-fpm"
sleep 1
systemctl start hostapd
sleep 2
systemctl start dnsmasq
sleep 1
systemctl start nginx


# ── Génération de l'identité cryptographique LoRa (Ed25519) ──────────────────
# Idempotent : ne régénère pas si les clés existent déjà
KEYPAIR_SCRIPT="/usr/local/bin/sos_keypair_gen.py"
if [ -f "$KEYPAIR_SCRIPT" ]; then
    if python3 "$KEYPAIR_SCRIPT" 2>/dev/null; then
        FINGERPRINT=$(cat /etc/sos-guide/node_fingerprint.txt 2>/dev/null || echo "?")
        ok "Identité LoRa Ed25519 : $FINGERPRINT"
    else
        warn "Génération clés LoRa échouée — LoRa fonctionnera sans signature"
    fi
else
    warn "sos_keypair_gen.py absent — clés LoRa non générées"
fi

# ── Génération du secret API LoRa ─────────────────────────────────────────────
API_SECRET_FILE="/etc/sos-guide/api_secret"
if [ ! -f "$API_SECRET_FILE" ]; then
    mkdir -p /etc/sos-guide
    openssl rand -hex 32 > "$API_SECRET_FILE"
    chmod 400 "$API_SECRET_FILE"
    ok "Secret API LoRa généré"
fi

# ── Marquage firstboot ────────────────────────────────────────────────────────
mkdir -p /var/lib/sos-guide
touch /var/lib/sos-guide/firstboot-done

# ── Log journal uniquement (pas de console HDMI) ─────────────────────────────
# v2.4 : suppression de l'affichage HDMI — tout passe par journalctl
echo "=========================================="
echo "  SOS-GUIDE STARTER v2.5"
echo "  SSID   : ⛑️ SOS-GUIDE - STARTER"
echo "  WiFi   : réseau ouvert (sans mot de passe)"
echo "  URL    : http://10.0.0.1/"
echo "  Canal  : $CHANNEL"
echo "=========================================="
logger "SOS-GUIDE: firstboot v2.5 démarré — SSID=SOS-GUIDE-STARTER ouvert canal=$CHANNEL iface=$WIFI_IFACE"

# Désactiver ce service (ne s'exécute qu'une seule fois)
systemctl disable sos-guide-firstboot.service 2>/dev/null || true

exit 0

