#!/bin/bash
# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  SOS-GUIDE – Finalisation installation (mode STARTER → PRODUCTION)         ║
# ║  Version : 2.3 — Mai 2026                                                  ║
# ║                                                                             ║
# ║  CORRECTIONS v2.3 :                                                        ║
# ║  ✅ Idempotence : chattr -i sur les fichiers avant ré-écriture              ║
# ║     (re-exécution du script ne bloque plus sur les fichiers verrouillés)   ║
# ║  ✅ Génération automatique de /etc/nginx/.htpasswd avec mdp aléatoire      ║
# ║     (l'admin /admin était non protégé ou inaccessible sans ce fichier)     ║
# ║  ✅ chattr +i data/ exclu correctement (config.json doit rester modifiable)║
# ╚══════════════════════════════════════════════════════════════════════════════╝

set -euo pipefail

# ── Couleurs ─────────────────────────────────────────────────────────────────
RED='\033[0;31m';  GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m';  NC='\033[0m'
BOLD='\033[1m';    DIM='\033[2m'

ok()      { echo -e "  ${GREEN}✔${NC}  $1"; }
warn()    { echo -e "  ${YELLOW}⚠${NC}  $1"; }
err()     { echo -e "  ${RED}✘${NC}  $1" >&2; }
info()    { echo -e "  ${CYAN}ℹ${NC}  $1"; }
step()    { echo -e "\n  ${BOLD}${BLUE}▶${NC}  ${BOLD}$1${NC}"; }
sep()     { echo -e "  ${DIM}──────────────────────────────────────────────${NC}"; }

# ── Chemins constants ─────────────────────────────────────────────────────────
CONFIG_FILE="/var/www/sos-guide/data/config.json"
WEB_DIR="/var/www/sos-guide"
INTEGRITY_HASH="/root/integrity.hash"
INSTALL_MARKER="/var/lib/sos-guide/installed"
AUDIT_LOG="/var/log/sos-guide-install.log"
HTPASSWD_FILE="/etc/nginx/.htpasswd"

# ── Journalisation ────────────────────────────────────────────────────────────
mkdir -p /var/lib/sos-guide /var/log
exec > >(tee -a "$AUDIT_LOG") 2>&1
echo ""
echo "════════════════════════════════════════════════════"
echo "  SOS-GUIDE finalisation — $(date '+%Y-%m-%d %H:%M:%S')"
echo "════════════════════════════════════════════════════"

# ── Vérifications préalables ──────────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
    err "Root requis"
    exit 1
fi

if [ ! -f "$CONFIG_FILE" ]; then
    err "config.json introuvable : $CONFIG_FILE"
    exit 1
fi

# ── Installation de jq si absent ─────────────────────────────────────────────
if ! command -v jq &>/dev/null; then
    info "Installation de jq..."
    apt-get update -qq && apt-get install -y -qq jq
fi

# ── FIX v2.3 : Déverrouillage préalable pour idempotence ─────────────────────
# Si le script est re-exécuté (changement de config), les fichiers marqués
# chattr +i bloqueraient toute réécriture. On les déverrouille en amont.
step "Déverrouillage préalable (idempotence)"
sep
if command -v chattr &>/dev/null; then
    find "$WEB_DIR" -type f ! -path "$WEB_DIR/data/*" \
        -exec chattr -i {} \; 2>/dev/null || true
    ok "Fichiers web déverrouillés pour mise à jour"
else
    info "chattr non disponible — ignoré"
fi

# ══════════════════════════════════════════════════════════════════════════════
# ÉTAPE 1 — LECTURE DE LA CONFIGURATION
# ══════════════════════════════════════════════════════════════════════════════
step "Lecture de la configuration"
sep

NODE_NAME=$(jq -r '.establishment.name // "SOS-GUIDE"'     "$CONFIG_FILE")
WIFI_PASSWORD=$(jq -r '.wifiPassword // ""'                 "$CONFIG_FILE")
ENABLE_LORA=$(jq -r '.enableLoRa // false'                  "$CONFIG_FILE")
ENABLE_ETHERNET=$(jq -r '.enableEthernet // false'          "$CONFIG_FILE")
WIFI_CHANNEL=$(jq -r '.wifiChannel // "11"'                 "$CONFIG_FILE")

ok "Nœud       : ${NODE_NAME}"
ok "LoRa       : ${ENABLE_LORA}"
ok "Ethernet   : ${ENABLE_ETHERNET}"
ok "Canal WiFi : ${WIFI_CHANNEL}"

# ── Détection dynamique des interfaces ────────────────────────────────────────
detect_wifi_iface() {
    for iface in /sys/class/net/*; do
        iface=$(basename "$iface")
        if iw dev "$iface" info &>/dev/null 2>&1; then
            echo "$iface"; return 0
        fi
    done
    return 1
}

detect_eth_iface() {
    local iface
    iface=$(ip -o link show | awk -F': ' '/^[0-9]+: (en|eth)/{print $2; exit}')
    [ -n "$iface" ] && { echo "$iface"; return 0; }
    return 1
}

WIFI_IFACE=$(detect_wifi_iface || true)
if [ -z "$WIFI_IFACE" ]; then
    err "Aucune interface WiFi détectée"
    exit 1
fi

ETH_IFACE=$(detect_eth_iface || true)
[ -z "$ETH_IFACE" ] && ETH_IFACE="eth0"

LOCAL_IP="10.0.0.1"
SSID="⛑️ SOS-GUIDE - ${NODE_NAME}"

ok "Interface WiFi : ${BOLD}${WIFI_IFACE}${NC}"
ok "Interface ETH  : ${BOLD}${ETH_IFACE}${NC}"
ok "SSID           : ${SSID}"

# ══════════════════════════════════════════════════════════════════════════════
# ÉTAPE 2 — CONFIGURATION HOSTAPD
# ══════════════════════════════════════════════════════════════════════════════
step "Configuration hostapd (WiFi AP)"
sep

HOSTAPD_CONF="/etc/hostapd/hostapd.conf"
[ -f "$HOSTAPD_CONF" ] && cp "$HOSTAPD_CONF" "${HOSTAPD_CONF}.bak"

cat > "$HOSTAPD_CONF" <<EOF
interface=${WIFI_IFACE}
driver=nl80211
ssid=${SSID}
hw_mode=g
channel=${WIFI_CHANNEL}
wmm_enabled=1
beacon_int=100
dtim_period=1
max_num_sta=50
country_code=FR
ap_isolate=1
ieee80211d=1
ieee80211n=1
ignore_broadcast_ssid=0
auth_algs=1
EOF

if [ -n "$WIFI_PASSWORD" ] && [ ${#WIFI_PASSWORD} -ge 8 ]; then
    cat >> "$HOSTAPD_CONF" <<EOF
wpa=2
wpa_passphrase=${WIFI_PASSWORD}
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
EOF
    ok "WPA2 activé (mot de passe configuré)"
else
    echo "wpa=0" >> "$HOSTAPD_CONF"
    warn "Réseau WiFi ouvert (pas de mot de passe)"
fi

cat > /etc/default/hostapd <<EOF
DAEMON_CONF="${HOSTAPD_CONF}"
DAEMON_OPTS=""
EOF

ok "hostapd.conf écrit"

# ══════════════════════════════════════════════════════════════════════════════
# ÉTAPE 3 — CONFIGURATION DNSMASQ
# ══════════════════════════════════════════════════════════════════════════════
step "Configuration dnsmasq (DHCP + DNS captif)"
sep

DNSMASQ_CONF="/etc/dnsmasq.conf"
[ -f "$DNSMASQ_CONF" ] && cp "$DNSMASQ_CONF" "${DNSMASQ_CONF}.bak"

cat > "$DNSMASQ_CONF" <<EOF
# SOS-GUIDE — DNS/DHCP captif
bind-dynamic
interface=${WIFI_IFACE}
listen-address=${LOCAL_IP}
dhcp-authoritative
dhcp-range=${LOCAL_IP%.*}.100,${LOCAL_IP%.*}.200,1h
dhcp-option=3,${LOCAL_IP}
dhcp-option=6,${LOCAL_IP}
dhcp-option=114,"http://${LOCAL_IP}/"
address=/sos.guide/${LOCAL_IP}
address=/#/${LOCAL_IP}
no-resolv
no-hosts
cache-size=0
log-facility=/dev/null
EOF

ok "dnsmasq.conf écrit"

# ══════════════════════════════════════════════════════════════════════════════
# ÉTAPE 4 — CONFIGURATION SYSTEMD-NETWORKD
# ══════════════════════════════════════════════════════════════════════════════
step "Configuration réseau (systemd-networkd)"
sep

cat > /etc/systemd/network/20-wlan-ap.network <<EOF
[Match]
Name=${WIFI_IFACE}

[Network]
Address=${LOCAL_IP}/24
IPv6AcceptRA=no
IPv6LinkLocalAddressGenerationMode=none
IPv6Disable=1

[Link]
WakeOnLan=off

[WLAN]
PowerSave=off
EOF

ok "Réseau WiFi AP configuré (${LOCAL_IP}/24)"

if [ "$ENABLE_ETHERNET" = "true" ]; then
    cat > "/etc/systemd/network/10-${ETH_IFACE}.network" <<EOF
[Match]
Name=${ETH_IFACE}

[Network]
DHCP=yes
IPv6AcceptRA=no
DNS=1.1.1.1
DNS=8.8.4.4

[DHCP]
RouteMetric=10
EOF
    ok "Interface Ethernet ${ETH_IFACE} : DHCP configuré"
else
    info "Ethernet désactivé — mode WiFi seul"
fi

# ══════════════════════════════════════════════════════════════════════════════
# ÉTAPE 5 — CONFIGURATION PHP-FPM + NGINX
# ══════════════════════════════════════════════════════════════════════════════
step "Configuration Nginx"
sep

PHP_VERSION=$(php -v 2>/dev/null | head -n1 | cut -d' ' -f2 | cut -d'.' -f1-2)
[ -z "$PHP_VERSION" ] && PHP_VERSION="8.2"
ok "PHP-FPM version : ${PHP_VERSION}"

NGINX_CONF="/etc/nginx/sites-available/sos-guide"
[ -f "$NGINX_CONF" ] && cp "$NGINX_CONF" "${NGINX_CONF}.bak"

cat > "$NGINX_CONF" <<NGINXEOF
server {
    listen 80 default_server;
    server_name _;
    root /var/www/sos-guide;
    index index.php index.html;
    access_log off;
    error_log off;
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 3;

    # ── Portail captif multi-OS ─────────────────────────────────────
    location = /hotspot-detect.html       { return 302 http://10.0.0.1/; }
    location = /library/test/success.html { return 302 http://10.0.0.1/; }
    location = /generate_204              { return 302 http://10.0.0.1/; }
    location = /generate_205              { return 302 http://10.0.0.1/; }
    location = /gen_204                   { return 302 http://10.0.0.1/; }
    location = /connecttest.txt           { return 302 http://10.0.0.1/; }
    location = /ncsi.txt                  { return 302 http://10.0.0.1/; }
    location = /success.txt               { return 302 http://10.0.0.1/; }
    location = /canonical.html            { return 302 http://10.0.0.1/; }
    location = /fwlink/                   { return 302 http://10.0.0.1/; }

    location = /health {
        access_log off;
        default_type text/plain;
        add_header Cache-Control "no-store";
        return 200 "OK\n";
    }

    # ── API reload-network (locale uniquement) ──────────────────────
    location = /api/reload-network {
        allow 127.0.0.1;
        allow ::1;
        deny all;
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/var/run/php/phpPHP_VERSION-fpm.sock;
    }

    # ── Admin protégé par htpasswd ──────────────────────────────────
    location /admin {
        auth_basic "Administration SOS-GUIDE";
        auth_basic_user_file /etc/nginx/.htpasswd;
        try_files \$uri \$uri/ =404;
        location ~ \.php$ {
            include snippets/fastcgi-php.conf;
            fastcgi_pass unix:/var/run/php/phpPHP_VERSION-fpm.sock;
        }
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/var/run/php/phpPHP_VERSION-fpm.sock;
    }

    location /img/  {
        alias /var/www/sos-guide/img/;
        expires 1y;
        add_header Cache-Control "public, immutable";
    }

    location /data/ {
        alias /var/www/sos-guide/data/;
        add_header Cache-Control "no-store";
    }

    location / {
        try_files \$uri \$uri/ /index.html;
        add_header Cache-Control "no-store, no-cache, must-revalidate";
        add_header X-Content-Type-Options "nosniff";
        add_header X-Frame-Options "SAMEORIGIN";
        add_header X-Robots-Tag "noindex, nofollow";
    }

    location ~ /\.         { deny all; }
    location ~* \.(env|ini|log|sh|sql|conf|cfg)$ { deny all; }
}

# ── Connectivité Google/Samsung/MIUI ────────────────────────────────
server {
    listen 80;
    server_name connectivitycheck.gstatic.com connectivitycheck.android.com
                connectivitycheck.hicloud.com connect.rom.miui.com
                wifi.vivo.com.cn www.samsung.com;
    access_log off;
    location = /generate_204 { return 302 http://10.0.0.1/; }
    location /               { return 302 http://10.0.0.1/; }
}
NGINXEOF

sed -i "s|phpPHP_VERSION|php${PHP_VERSION}|g" "$NGINX_CONF"
ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default

if ! nginx -t &>/dev/null; then
    err "Syntaxe nginx invalide — restauration de la config précédente"
    [ -f "${NGINX_CONF}.bak" ] && cp "${NGINX_CONF}.bak" "$NGINX_CONF"
    nginx -t && ok "Config précédente restaurée"
    exit 1
fi
ok "Nginx : syntaxe validée"

# ── FIX v2.3 : Génération automatique du fichier .htpasswd ───────────────────
# Sans ce fichier, nginx retourne 500 sur /admin (auth_basic_user_file manquant)
step "Génération du mot de passe administrateur"
sep

if [ ! -f "$HTPASSWD_FILE" ]; then
    # Générer un mot de passe fort aléatoire (18 chars alphanum)
    ADMIN_PASS=$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 18)

    if command -v htpasswd &>/dev/null; then
        htpasswd -cb "$HTPASSWD_FILE" admin "$ADMIN_PASS" 2>/dev/null
    else
        # Fallback : openssl apr1 (compatible Apache/nginx)
        HASHED=$(openssl passwd -apr1 "$ADMIN_PASS")
        echo "admin:${HASHED}" > "$HTPASSWD_FILE"
    fi

    chmod 640 "$HTPASSWD_FILE"
    chown root:www-data "$HTPASSWD_FILE"

    # Sauvegarder le mot de passe dans le marqueur d'installation (lisible par root seul)
    echo "ADMIN_USER=admin" >> "$INSTALL_MARKER.tmp"
    echo "ADMIN_PASS=${ADMIN_PASS}" >> "$INSTALL_MARKER.tmp"

    ok "Compte admin créé"
    echo ""
    echo -e "  ${BOLD}${YELLOW}┌─────────────────────────────────────────────────┐${NC}"
    echo -e "  ${BOLD}${YELLOW}│  MOT DE PASSE ADMIN (noter maintenant !)        │${NC}"
    echo -e "  ${BOLD}${YELLOW}│                                                 │${NC}"
    echo -e "  ${BOLD}${YELLOW}│  URL      : http://${LOCAL_IP}/admin             │${NC}"
    echo -e "  ${BOLD}${YELLOW}│  Login    : admin                               │${NC}"
    echo -e "  ${BOLD}${YELLOW}│  Password : ${ADMIN_PASS}           │${NC}"
    echo -e "  ${BOLD}${YELLOW}│                                                 │${NC}"
    echo -e "  ${BOLD}${YELLOW}│  Sauvegardé dans : ${INSTALL_MARKER}    │${NC}"
    echo -e "  ${BOLD}${YELLOW}└─────────────────────────────────────────────────┘${NC}"
    echo ""
else
    ok "Fichier .htpasswd existant conservé (réinstallation)"
    info "Pour réinitialiser : sudo rm ${HTPASSWD_FILE} && sudo bash $0"
fi

# ── Endpoint /api/reload-network ──────────────────────────────────────────────
API_RELOAD="/var/www/sos-guide/api_reload_network.php"
cat > "$API_RELOAD" <<'PHPEOF'
<?php
/**
 * SOS-GUIDE — /api/reload-network
 * Accessible uniquement depuis 127.0.0.1 (nginx deny all other)
 */
header('Content-Type: application/json');

$remote = $_SERVER['REMOTE_ADDR'] ?? '';
if ($remote !== '127.0.0.1' && $remote !== '::1') {
    http_response_code(403);
    echo json_encode(['success' => false, 'message' => 'Accès refusé']);
    exit;
}

if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
    http_response_code(405);
    echo json_encode(['success' => false, 'message' => 'POST requis']);
    exit;
}

$log = []; $errors = [];

exec('sudo /usr/local/bin/sos-guide-regen-hash.sh 2>&1', $o, $r);
$r === 0 ? $log[] = 'Hash SHA256 régénéré' : $errors[] = 'Hash: ' . implode(' ', $o);

exec('sudo /bin/systemctl reload nginx 2>&1', $o, $r);
$r === 0 ? $log[] = 'nginx rechargé (zero-downtime)' : $errors[] = 'nginx: ' . implode(' ', $o);

exec('sudo /bin/systemctl reload dnsmasq 2>&1', $o, $r);
$r === 0 ? $log[] = 'dnsmasq rechargé (baux conservés)' : $errors[] = 'dnsmasq: ' . implode(' ', $o);

$reloadWifi = ($_POST['reload_wifi'] ?? 'false') === 'true';
if ($reloadWifi) {
    exec('sudo /bin/systemctl restart hostapd 2>&1', $o, $r);
    $r === 0 ? $log[] = 'hostapd redémarré (~3s)' : $errors[] = 'hostapd: ' . implode(' ', $o);
}

$entry = ['ts' => date('c'), 'ip' => $remote, 'action' => 'reload-network',
          'log' => $log, 'errors' => $errors];
file_put_contents('/var/log/sos-guide-admin-audit.log',
    json_encode($entry) . "\n", FILE_APPEND | LOCK_EX);

$success = empty($errors);
http_response_code($success ? 200 : 207);
echo json_encode(['success' => $success, 'log' => $log, 'errors' => $errors]);
PHPEOF

chown www-data:www-data "$API_RELOAD"
chmod 640 "$API_RELOAD"
ok "api_reload_network.php créé"

# ── Script de régénération du hash ────────────────────────────────────────────
cat > /usr/local/bin/sos-guide-regen-hash.sh <<'HASHEOF'
#!/bin/bash
WEB_DIR="/var/www/sos-guide"
HASH_FILE="/root/integrity.hash"
TEMP_HASH="${HASH_FILE}.tmp"
find "$WEB_DIR" -type f ! -path "$WEB_DIR/data/config.json" \
    -exec sha256sum {} \; > "$TEMP_HASH"
sha256sum "$WEB_DIR/data/config.json" >> "$TEMP_HASH" 2>/dev/null || true
sha256sum /etc/nginx/sites-available/sos-guide >> "$TEMP_HASH" 2>/dev/null || true
mv "$TEMP_HASH" "$HASH_FILE"
chmod 400 "$HASH_FILE"
logger "SOS-GUIDE: hash SHA256 régénéré ($(wc -l < "$HASH_FILE") fichiers)"
HASHEOF
chmod 755 /usr/local/bin/sos-guide-regen-hash.sh
ok "sos-guide-regen-hash.sh installé"

# ── Sudoers ───────────────────────────────────────────────────────────────────
SUDOERS_FILE="/etc/sudoers.d/sos-guide-reload"
cat > "$SUDOERS_FILE" <<'SUDOEOF'
www-data ALL=(root) NOPASSWD: /bin/systemctl reload nginx
www-data ALL=(root) NOPASSWD: /bin/systemctl reload dnsmasq
www-data ALL=(root) NOPASSWD: /bin/systemctl restart hostapd
www-data ALL=(root) NOPASSWD: /usr/local/bin/sos-guide-regen-hash.sh
root ALL=(root) NOPASSWD: /usr/local/bin/sos-guide-regen-hash.sh
SUDOEOF
chmod 440 "$SUDOERS_FILE"
if visudo -c -f "$SUDOERS_FILE" &>/dev/null; then
    ok "sudoers configuré"
else
    err "Fichier sudoers invalide — suppression"
    rm -f "$SUDOERS_FILE"
fi

# ══════════════════════════════════════════════════════════════════════════════
# ÉTAPE 6 — FIREWALL IPTABLES
# ══════════════════════════════════════════════════════════════════════════════
step "Firewall iptables"
sep

iptables -F; iptables -t nat -F; iptables -t mangle -F
iptables -P INPUT DROP; iptables -P FORWARD DROP; iptables -P OUTPUT ACCEPT
iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -m conntrack --ctstate INVALID -j DROP
iptables -A INPUT -p tcp --tcp-flags ALL NONE -j DROP
iptables -A INPUT -p tcp --tcp-flags ALL ALL -j DROP

if [ "$ENABLE_ETHERNET" = "true" ]; then
    iptables -A INPUT -i "${ETH_IFACE}" -p tcp --dport 22 \
        -m conntrack --ctstate NEW \
        -m limit --limit 3/min --limit-burst 3 -j ACCEPT
    ok "SSH autorisé sur ${ETH_IFACE} (3 conn/min)"
fi

iptables -A INPUT -i "${WIFI_IFACE}" -p tcp --dport 80 \
    -m limit --limit 30/second --limit-burst 200 -j ACCEPT
iptables -A INPUT -i "${WIFI_IFACE}" -p tcp --dport 443 \
    -m limit --limit 30/second --limit-burst 200 -j ACCEPT
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A INPUT -i "${WIFI_IFACE}" -p udp --dport 67 -j ACCEPT
iptables -A INPUT -i "${WIFI_IFACE}" -p udp --dport 53 -j ACCEPT
iptables -A INPUT -i "${WIFI_IFACE}" -p tcp --dport 53 -j ACCEPT
iptables -A INPUT -i "${WIFI_IFACE}" -j DROP

iptables -t nat -A PREROUTING -i "${WIFI_IFACE}" -p tcp --dport 80  \
    -j DNAT --to-destination "${LOCAL_IP}:80"
iptables -t nat -A PREROUTING -i "${WIFI_IFACE}" -p tcp --dport 443 \
    -j DNAT --to-destination "${LOCAL_IP}:443"
iptables -t nat -A PREROUTING -i "${WIFI_IFACE}" -p udp --dport 53  \
    -j DNAT --to-destination "${LOCAL_IP}:53"
iptables -t nat -A PREROUTING -i "${WIFI_IFACE}" -p tcp --dport 53  \
    -j DNAT --to-destination "${LOCAL_IP}:53"

iptables -A FORWARD -i "${WIFI_IFACE}" -o "${WIFI_IFACE}" -j DROP
iptables -A FORWARD -i "${WIFI_IFACE}" -o "${ETH_IFACE}"  -j DROP
iptables -A FORWARD -i "${WIFI_IFACE}" -j DROP

mkdir -p /etc/iptables
netfilter-persistent save &>/dev/null
ok "Règles iptables sauvegardées"

if ! iptables -C FORWARD -i "${WIFI_IFACE}" -o "${ETH_IFACE}" -j DROP 2>/dev/null; then
    err "CRITIQUE : Règle isolation WiFi→Internet manquante"
    exit 1
fi
ok "Isolation WiFi → Internet vérifiée ✓"

# ══════════════════════════════════════════════════════════════════════════════
# ÉTAPE 7 — VERROUILLAGE DES FICHIERS WEB
# FIX v2.3 : data/ explicitement exclu + config.json toujours modifiable
# ══════════════════════════════════════════════════════════════════════════════
step "Verrouillage du contenu web (chattr)"
sep

chown -R www-data:www-data "$WEB_DIR"
chmod -R a-w "$WEB_DIR"

if command -v chattr &>/dev/null; then
    # Verrouiller tous les fichiers sauf data/ (config.json doit rester éditable)
    find "$WEB_DIR" -type f ! -path "$WEB_DIR/data/*" \
        -exec chattr +i {} \; 2>/dev/null || true
    # data/ : déverrouillé explicitement, writable par www-data
    chattr -R -i "$WEB_DIR/data/" 2>/dev/null || true
    chmod 755 "$WEB_DIR/data/"
    chown www-data:www-data "$WEB_DIR/data/"
    ok "chattr +i : fichiers web verrouillés (data/ exclu — config.json modifiable)"
else
    warn "chattr non supporté sur ce système de fichiers"
fi

# ══════════════════════════════════════════════════════════════════════════════
# ÉTAPE 8 — LoRa (si activé)
# ══════════════════════════════════════════════════════════════════════════════
if [ "$ENABLE_LORA" = "true" ]; then
    step "Activation service LoRa"
    sep
    if systemctl list-unit-files | grep -q "lora-service"; then
        systemctl enable lora-service  2>/dev/null || true
        systemctl start  lora-service  2>/dev/null || true
        systemctl is-active --quiet lora-service \
            && ok "lora-service démarré" \
            || warn "lora-service non actif — vérifier lora-service.py"
    else
        warn "lora-service.service absent"
    fi
fi

# ══════════════════════════════════════════════════════════════════════════════
# ÉTAPE 9 — RELOAD À CHAUD (PAS DE REBOOT SYSTÈME)
# ══════════════════════════════════════════════════════════════════════════════
step "Reload à chaud des services (SANS REBOOT SYSTÈME)"
sep

SVC_ERRORS=0

# 9.1 systemd-networkd
info "Rechargement systemd-networkd..."
if networkctl reload 2>/dev/null; then
    sleep 1
    ip -4 addr show "${WIFI_IFACE}" | grep -q "${LOCAL_IP}" \
        && ok "systemd-networkd : ${WIFI_IFACE} → ${LOCAL_IP}/24 ✓" \
        || { sleep 2
             ip -4 addr show "${WIFI_IFACE}" | grep -q "${LOCAL_IP}" \
                && ok "systemd-networkd : ${WIFI_IFACE} → ${LOCAL_IP}/24 ✓" \
                || { warn "IP non visible (ajout manuel)"
                     ip addr add "${LOCAL_IP}/24" dev "${WIFI_IFACE}" 2>/dev/null || true; }; }
else
    systemctl restart systemd-networkd 2>/dev/null || true; sleep 2
fi

# 9.2 dnsmasq (SIGHUP conserve les baux)
info "Rechargement dnsmasq (baux DHCP conservés)..."
if systemctl reload dnsmasq 2>/dev/null; then
    sleep 1
    systemctl is-active --quiet dnsmasq \
        && ok "dnsmasq rechargé ✓" \
        || { err "dnsmasq arrêté après reload"
             systemctl start dnsmasq; SVC_ERRORS=$((SVC_ERRORS + 1)); }
else
    systemctl restart dnsmasq
    sleep 1
    systemctl is-active --quiet dnsmasq \
        && ok "dnsmasq redémarré (fallback)" \
        || { err "dnsmasq DOWN"; SVC_ERRORS=$((SVC_ERRORS + 1)); }
fi

# 9.3 hostapd (restart requis si SSID/WPA/canal changé)
info "Redémarrage hostapd (~3s d'interruption WiFi)..."
systemctl unmask hostapd 2>/dev/null || true
systemctl enable hostapd &>/dev/null
ip link set "${WIFI_IFACE}" down 2>/dev/null || true
sleep 1
ip link set "${WIFI_IFACE}" up   2>/dev/null || true
sleep 1
if systemctl restart hostapd; then
    sleep 3
    systemctl is-active --quiet hostapd \
        && ok "hostapd redémarré ✓ (SSID '${SSID}')" \
        || { err "hostapd DOWN après restart"
             journalctl -u hostapd --no-pager -n 5
             SVC_ERRORS=$((SVC_ERRORS + 1)); }
else
    err "hostapd restart échoué"; SVC_ERRORS=$((SVC_ERRORS + 1))
fi

# 9.4 PHP-FPM
info "Rechargement PHP-FPM ${PHP_VERSION}..."
systemctl enable "php${PHP_VERSION}-fpm" &>/dev/null 2>&1 || true
systemctl is-active --quiet "php${PHP_VERSION}-fpm" \
    && systemctl reload "php${PHP_VERSION}-fpm" 2>/dev/null \
    || systemctl start "php${PHP_VERSION}-fpm"
systemctl is-active --quiet "php${PHP_VERSION}-fpm" \
    && ok "PHP-FPM ${PHP_VERSION} actif ✓" \
    || { err "PHP-FPM ${PHP_VERSION} DOWN"; SVC_ERRORS=$((SVC_ERRORS + 1)); }

# 9.5 nginx (zero-downtime)
info "Rechargement nginx (zero-downtime)..."
if nginx -t &>/dev/null; then
    systemctl is-active --quiet nginx \
        && nginx -s reload || systemctl start nginx
    sleep 1
    systemctl is-active --quiet nginx \
        && ok "nginx actif ✓" \
        || { err "nginx DOWN"; SVC_ERRORS=$((SVC_ERRORS + 1)); }
else
    err "nginx config invalide"; SVC_ERRORS=$((SVC_ERRORS + 1))
fi

# 9.6 Vérification mode AP
info "Vérification mode AP WiFi..."
AP_OK=false
for i in $(seq 1 10); do
    iw dev "${WIFI_IFACE}" info 2>/dev/null | grep -q "type AP" && { AP_OK=true; break; }
    sleep 1
done
$AP_OK && ok "Interface ${WIFI_IFACE} en mode AP ✓" \
         || warn "Mode AP non confirmé dans les 10s"

# ══════════════════════════════════════════════════════════════════════════════
# ÉTAPE 10 — HASH SHA256
# ══════════════════════════════════════════════════════════════════════════════
step "Régénération du hash SHA256 d'intégrité"
sep

if /usr/local/bin/sos-guide-regen-hash.sh; then
    FILE_COUNT=$(wc -l < "$INTEGRITY_HASH" 2>/dev/null || echo "0")
    ok "Hash SHA256 régénéré — ${FILE_COUNT} fichiers surveillés"
else
    err "Régénération du hash échouée"; SVC_ERRORS=$((SVC_ERRORS + 1))
fi

# ══════════════════════════════════════════════════════════════════════════════
# ÉTAPE 11 — DÉSACTIVATION FIRSTBOOT
# ══════════════════════════════════════════════════════════════════════════════
step "Désactivation du service firstboot"
sep

systemctl disable sos-guide-firstboot.service 2>/dev/null || true
rm -f /etc/systemd/system/sos-guide-firstboot.service
systemctl daemon-reload &>/dev/null

mkdir -p /var/lib/sos-guide
{
    echo "date=$(date -Iseconds)"
    echo "node=${NODE_NAME}"
    echo "wifi=${WIFI_IFACE}"
    echo "ssid=${SSID}"
    echo "lora=${ENABLE_LORA}"
    echo "version=2.3"
} > "$INSTALL_MARKER"

# Fusionner les credentials si générés
[ -f "$INSTALL_MARKER.tmp" ] && { cat "$INSTALL_MARKER.tmp" >> "$INSTALL_MARKER"; rm "$INSTALL_MARKER.tmp"; }
chmod 400 "$INSTALL_MARKER"

ok "Mode firstboot désactivé"
ok "Marqueur d'installation créé : ${INSTALL_MARKER} (chmod 400)"

# ══════════════════════════════════════════════════════════════════════════════
# RÉSUMÉ
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "  ${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
if [ "$SVC_ERRORS" -eq 0 ]; then
    echo -e "  ${BOLD}║  ✅  SOS-GUIDE — PRODUCTION READY (sans reboot)          ║${NC}"
else
    echo -e "  ${BOLD}║  ⚠️   SOS-GUIDE — ACTIF avec ${SVC_ERRORS} avertissement(s)        ║${NC}"
fi
echo -e "  ${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""

for svc in hostapd dnsmasq nginx; do
    systemctl is-active --quiet "$svc" \
        && echo -e "  ${GREEN}✔${NC}  $svc" \
        || echo -e "  ${RED}✘${NC}  $svc  ← journalctl -u $svc"
done
systemctl is-active --quiet "php${PHP_VERSION}-fpm" \
    && echo -e "  ${GREEN}✔${NC}  php${PHP_VERSION}-fpm" \
    || echo -e "  ${RED}✘${NC}  php${PHP_VERSION}-fpm"

echo ""
echo -e "  ${CYAN}SSID diffusé   :${NC} ${BOLD}${SSID}${NC}"
echo -e "  ${CYAN}Portail captif :${NC} http://${LOCAL_IP}/"
echo -e "  ${CYAN}Administration :${NC} http://${LOCAL_IP}/admin  (login: admin)"
echo -e "  ${CYAN}Credentials    :${NC} ${INSTALL_MARKER}  (root uniquement)"
echo -e "  ${CYAN}Hash intégrité :${NC} ${INTEGRITY_HASH}"
echo ""
echo -e "  ${DIM}⚠  Les clients doivent se reconnecter au WiFi${NC}"
echo -e "  ${DIM}ℹ  Logs : journalctl -u hostapd -u dnsmasq -u nginx -f${NC}"
echo ""

exit "$SVC_ERRORS"
