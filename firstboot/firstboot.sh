#!/bin/bash
# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  SOS-GUIDE First Boot v2.3 — Mode STARTER                                  ║
# ║                                                                             ║
# ║  CORRECTIONS v2.3 :                                                        ║
# ║  FIX BUG-01 : detect_wifi_iface() — vérification /sys/class/net/*/wireless ║
# ║               avant iw (qui peut ne pas être installé au firstboot)        ║
# ║  FIX BUG-02 : ETH_IFACE déclarée globale avant detect_wifi, pas locale    ║
# ║  FIX BUG-03 : sed sur TOKEN utilise un délimiteur safe (#) car le token   ║
# ║               hex ne contient que [0-9a-f] — pas de risque, mais sécurisé ║
# ║  FIX BUG-13 : PIN retiré de logger (syslog lisible par tous les users)    ║
# ║               PIN affiché uniquement sur /dev/console + écran systemd      ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

RED='\033[0;31m';  GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m';    NC='\033[0m'
ok()   { echo -e "  ${GREEN}✔${NC}  $1"; }
warn() { echo -e "  ${YELLOW}⚠${NC}  $1"; }
err()  { echo -e "  ${RED}✘${NC}  $1" >&2; }
info() { echo -e "  ${CYAN}ℹ${NC}  $1"; }

WEB_DIR="/var/www/sos-guide"
CONFIG_JSON="$WEB_DIR/data/config.json"
RUNTIME_DIR="/run/sos-guide"
TOKEN_FILE="$RUNTIME_DIR/firstboot_token"
PIN_FILE="$RUNTIME_DIR/firstboot_pin"
RATE_FILE="$RUNTIME_DIR/rate_limit"
LOG_FILE="/var/log/sos-guide-firstboot.log"

exec >> "$LOG_FILE" 2>&1
echo ""
echo "══════════════════════════════════════════════"
echo "  SOS-GUIDE firstboot — $(date '+%Y-%m-%d %H:%M:%S')"
echo "══════════════════════════════════════════════"

[ "$(id -u)" -eq 0 ] || { err "Root requis"; exit 1; }

if [ -f "/var/lib/sos-guide/installed" ]; then
    info "Système déjà installé — firstboot ignoré"
    exit 0
fi

mkdir -p "$RUNTIME_DIR"
chmod 700 "$RUNTIME_DIR"
rm -f "$TOKEN_FILE" "$PIN_FILE" "$RATE_FILE"

# ── PIN 6 chiffres ────────────────────────────────────────────────────────────
PIN=$(shuf -i 100000-999999 -n 1)
echo "$PIN" > "$PIN_FILE"
chmod 400 "$PIN_FILE"

# ── Token CSRF one-shot (hex pur — safe pour sed) ────────────────────────────
TOKEN=$(openssl rand -hex 32)
echo "$TOKEN" > "$TOKEN_FILE"
chmod 400 "$TOKEN_FILE"

ok "PIN et token CSRF générés"

# ── FIX BUG-01 : Détection WiFi robuste ──────────────────────────────────────
# Priorité 1 : /sys/class/net/*/wireless (ne dépend pas de iw)
# Priorité 2 : iw si disponible
# Priorité 3 : préfixe wl*
detect_wifi_iface() {
    # Méthode 1 : entrée /wireless dans sysfs (fiable, pas de dépendance externe)
    for iface in /sys/class/net/*; do
        local name
        name=$(basename "$iface")
        # Exclure lo, eth*, en*
        if [[ -d "/sys/class/net/$name/wireless" ]]; then
            echo "$name"
            return 0
        fi
    done
    # Méthode 2 : iw (si installé)
    if command -v iw &>/dev/null; then
        local iface
        iface=$(iw dev 2>/dev/null | awk '/Interface/{print $2; exit}')
        [ -n "$iface" ] && { echo "$iface"; return 0; }
    fi
    # Méthode 3 : préfixe wl*
    local iface
    iface=$(ip link show 2>/dev/null | awk -F': ' '/: wl/{gsub(/@.*/,"",$2); print $2; exit}')
    [ -n "$iface" ] && { echo "$iface"; return 0; }
    return 1
}

# ── FIX BUG-02 : ETH_IFACE globale ───────────────────────────────────────────
# La variable doit être visible dans tout le script après l'appel
WIFI_IFACE=""
WIFI_IFACE=$(detect_wifi_iface || true)

if [ -z "$WIFI_IFACE" ]; then
    err "Aucune interface WiFi détectée"
    exit 1
fi
ok "Interface WiFi : $WIFI_IFACE"

# ── Canal WiFi ────────────────────────────────────────────────────────────────
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
    ok "Canal WiFi par défaut : $CHANNEL (iw absent)"
fi

systemctl stop hostapd dnsmasq nginx 2>/dev/null || true

# ── hostapd STARTER ───────────────────────────────────────────────────────────
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

ok "hostapd STARTER configuré (canal $CHANNEL)"

# ── IP statique ───────────────────────────────────────────────────────────────
ip link set "$WIFI_IFACE" down 2>/dev/null || true
sleep 0.5
ip link set "$WIFI_IFACE" up
ip addr flush dev "$WIFI_IFACE" 2>/dev/null || true
ip addr add 10.0.0.1/24 dev "$WIFI_IFACE" 2>/dev/null || true
ok "IP 10.0.0.1/24 sur $WIFI_IFACE"

# ── dnsmasq ───────────────────────────────────────────────────────────────────
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

# ── PHP-FPM ───────────────────────────────────────────────────────────────────
PHP_VERSION=$(php -v 2>/dev/null | head -n1 | cut -d' ' -f2 | cut -d'.' -f1-2)
[ -z "$PHP_VERSION" ] && PHP_VERSION="8.2"
ok "PHP-FPM version : $PHP_VERSION"

# ── Copie des fichiers firstboot ──────────────────────────────────────────────
mkdir -p "$WEB_DIR/data"
FOUND_BOOT=""
for bp in "/boot/firmware/firstboot" "/boot/firstboot"; do
    [ -f "$bp/starter.html" ] && { FOUND_BOOT="$bp"; break; }
done
[ -z "$FOUND_BOOT" ] && { err "Fichiers firstboot introuvables"; exit 1; }

cp "$FOUND_BOOT/starter.html"       "$WEB_DIR/"
cp "$FOUND_BOOT/api_install.php"    "$WEB_DIR/"
cp "$FOUND_BOOT/finalize_install.sh" /usr/local/bin/ 2>/dev/null || true
chmod +x /usr/local/bin/finalize_install.sh 2>/dev/null || true

chown www-data:www-data "$WEB_DIR/starter.html" "$WEB_DIR/api_install.php"
chmod 644 "$WEB_DIR/starter.html"
chmod 640 "$WEB_DIR/api_install.php"
ok "Fichiers firstboot copiés depuis $FOUND_BOOT"

# ── FIX BUG-03 : Injection token CSRF dans starter.html ──────────────────────
# Le token est du hex pur [0-9a-f]{64} — aucun caractère spécial possible
# On utilise le délimiteur # pour éviter tout conflit (même si inutile pour du hex)
sed -i "s#%%CSRF_TOKEN%%#${TOKEN}#g"     "$WEB_DIR/starter.html"
sed -i "s#%%WIFI_CHANNEL%%#${CHANNEL}#g" "$WEB_DIR/starter.html"
chown www-data:www-data "$WEB_DIR/starter.html"
ok "Token CSRF injecté dans starter.html"

# ── config.json initial ───────────────────────────────────────────────────────
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

# ── nginx STARTER ─────────────────────────────────────────────────────────────
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

    location ~ /\. { deny all; }
    location ~* \.(env|ini|log|sh|sql|conf|cfg)$ { deny all; }
}
NGINXEOF

ln -sf /etc/nginx/sites-available/sos-guide /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default
nginx -t &>/dev/null || { err "Nginx config invalide"; exit 1; }
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

mkdir -p /var/lib/sos-guide
touch /var/lib/sos-guide/firstboot-done

# ── FIX BUG-13 : PIN affiché sur console SANS passer par syslog ──────────────
# logger() N'EST PLUS utilisé pour le PIN (lisible par tout utilisateur via journalctl)
# Le PIN est uniquement affiché sur la console physique (/dev/console)
cat >> /dev/console 2>/dev/null <<PINEOF || true

  ╔══════════════════════════════════════════════════════════════╗
  ║   ⛑️   SOS-GUIDE — MODE CONFIGURATION INITIALE              ║
  ║                                                              ║
  ║   WiFi : ⛑️ SOS-GUIDE - STARTER                             ║
  ║   URL  : http://10.0.0.1/                                   ║
  ║                                                              ║
  ║   ┌──────────────────────────────────────────────────────┐  ║
  ║   │   CODE PIN D'ADMINISTRATION :   ${PIN}             │  ║
  ║   │   ⚠️  Visible UNIQUEMENT ici. Invalide après usage.  │  ║
  ║   └──────────────────────────────────────────────────────┘  ║
  ╚══════════════════════════════════════════════════════════════╝

PINEOF

# Log systemd SANS le PIN (canal=$CHANNEL, iface=$WIFI_IFACE — infos non sensibles)
echo "SOS-GUIDE: firstboot démarré — canal=${CHANNEL} iface=${WIFI_IFACE}"
logger "SOS-GUIDE: firstboot démarré — canal=${CHANNEL} iface=${WIFI_IFACE} — PIN sur console physique uniquement"

systemctl disable sos-guide-firstboot.service 2>/dev/null || true
exit 0
