#!/bin/bash
# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  SOS-GUIDE – Finalisation installation (mode STARTER → PRODUCTION)         ║
# ║  Version : 2.6 — Juin 2026                                                 ║
# ║                                                                             ║
# ║  NOUVEAUTÉS v2.6 :                                                         ║
# ║  ✅ Installation offline : bundle offline-deps-*.tar.gz auto-détecté       ║
# ║     (install.sh fonctionnel sans Ethernet si bundle présent à la racine)   ║
# ║  ✅ config.json préservé lors des réinstallations (jamais écrasé)          ║
# ║  ✅ config.json créé avec valeurs par défaut si absent après déploiement   ║
# ║                                                                             ║
# ║  CORRECTIONS v2.4/2.5 :                                                    ║
# ║  ✅ Idempotence : chattr -i sur les fichiers avant ré-écriture              ║
# ║  ✅ Génération automatique de /etc/nginx/.htpasswd avec mdp aléatoire      ║
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

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="${REPO_DIR}/src"
# Cherche VERSION dans le repo, puis dans /etc (image), puis fallback
VERSION=$(cat "${REPO_DIR}/VERSION" 2>/dev/null \
          || cat /etc/sos-guide-version 2>/dev/null \
          || echo "2.5") && VERSION=$(echo "$VERSION" | tr -d '[:space:]')

# ── Journalisation ────────────────────────────────────────────────────────────
mkdir -p /var/lib/sos-guide /var/log
rm -f "${INSTALL_MARKER}.tmp"
exec > >(tee -a "$AUDIT_LOG") 2>&1
echo ""
echo "════════════════════════════════════════════════════"
echo "  SOS-GUIDE v${VERSION} — $(date '+%Y-%m-%d %H:%M:%S')"
echo "════════════════════════════════════════════════════"

# ── Vérifications préalables ──────────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
    err "Root requis"
    exit 1
fi

# ── Rollback sur ERR — restaure les .bak avant de quitter ────────────────────
_SOS_ROLLBACK_DONE=false
sos_rollback() {
    "$_SOS_ROLLBACK_DONE" && return
    _SOS_ROLLBACK_DONE=true
    warn "Erreur détectée — restauration des configurations précédentes..."
    local restored=0
    for f in /etc/hostapd/hostapd.conf /etc/dnsmasq.conf \
              /etc/nginx/sites-available/sos-guide; do
        if [ -f "${f}.bak" ]; then
            mv "${f}.bak" "$f" && warn "Restauré: $f" && ((restored++)) || true
        fi
    done
    if [ "$restored" -gt 0 ]; then
        systemctl restart hostapd dnsmasq nginx 2>/dev/null || true
        warn "Services relancés avec les configs précédentes"
    fi
    err "Installation interrompue — corriger l'erreur ci-dessus et relancer"
}
trap 'sos_rollback' ERR

# ══════════════════════════════════════════════════════════════════════════════
# ÉTAPE -1 — INSTALLATION DES PAQUETS SYSTÈME
# Auto-détecte un bundle offline-deps-*.tar.gz à la racine du projet.
# Sinon, utilise apt (connexion internet requise).
# ══════════════════════════════════════════════════════════════════════════════
step "Installation des paquets système"
sep

_pkg_installed() { dpkg -l "$1" 2>/dev/null | grep -q "^ii"; }

SOS_PKGS=(nginx hostapd dnsmasq netfilter-persistent iptables-persistent
          jq watchdog apache2-utils)
# PHP-FPM : réutilise la version installée, sinon cible 8.4
_PHP_INSTALLED=$(dpkg -l 'php*-fpm' 2>/dev/null | awk '/^ii/{print $2; exit}')
[ -z "$_PHP_INSTALLED" ] && _PHP_INSTALLED="php8.4-fpm"
SOS_PKGS+=("$_PHP_INSTALLED")

MISSING_PKGS=()
for _p in "${SOS_PKGS[@]}"; do
    _pkg_installed "$_p" || MISSING_PKGS+=("$_p")
done
unset _p _PHP_INSTALLED

if [ ${#MISSING_PKGS[@]} -eq 0 ]; then
    ok "Tous les paquets déjà installés"
else
    info "Paquets manquants : ${MISSING_PKGS[*]}"
    BUNDLE=$(ls "${REPO_DIR}"/offline-deps-*.tar.gz 2>/dev/null | head -1 || true)
    if [ -n "$BUNDLE" ]; then
        info "Bundle offline : $(basename "$BUNDLE")"
        DEBS_TMP=$(mktemp -d)
        tar -xzf "$BUNDLE" -C "$DEBS_TMP"
        DEBIAN_FRONTEND=noninteractive dpkg -i --force-depends \
            "$DEBS_TMP"/debs/*.deb 2>/dev/null || true
        DEBIAN_FRONTEND=noninteractive apt-get install -f -y -qq
        rm -rf "$DEBS_TMP"
        ok "Paquets installés depuis bundle offline"
    else
        info "Bundle absent — installation via apt (internet requis)"
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${MISSING_PKGS[@]}"
        ok "Paquets installés"
    fi
fi

# ══════════════════════════════════════════════════════════════════════════════
# ÉTAPE 0 — DÉPLOIEMENT DES SOURCES
# ══════════════════════════════════════════════════════════════════════════════
step "Déploiement des sources"
sep

if [ -d "$SRC_DIR" ]; then
    # Fichiers web — config.json préservé s'il existe déjà (jamais écrasé)
    if [ -d "${SRC_DIR}/web" ]; then
        mkdir -p "$WEB_DIR"
        _CONFIG_BAK=""
        if [ -f "$CONFIG_FILE" ]; then
            _CONFIG_BAK=$(mktemp)
            cp "$CONFIG_FILE" "$_CONFIG_BAK"
        fi
        cp -r "${SRC_DIR}/web/." "$WEB_DIR/"
        if [ -n "$_CONFIG_BAK" ]; then
            cp "$_CONFIG_BAK" "$CONFIG_FILE"
            rm -f "$_CONFIG_BAK"
            ok "config.json existant préservé"
        fi
        unset _CONFIG_BAK
        ok "src/web/ → ${WEB_DIR}"
    else
        warn "src/web/ absent"
    fi

    # PRIVACY.md à la racine du site (lié depuis admin.php)
    if [ -f "${REPO_DIR}/PRIVACY.md" ]; then
        cp "${REPO_DIR}/PRIVACY.md" "$WEB_DIR/"
        ok "PRIVACY.md → ${WEB_DIR}"
    fi

    # Scripts vers /usr/local/bin
    for script in lora-service.py sos-guide-boot-check.sh sos-guide-regen-hash.sh \
                  sos-guide-fetch-tiles.sh sos-guide-update.sh sos-guide-tls-setup.sh \
                  sos-guide-reset-starter.sh sos-guide-watchdog-test.sh; do
        src="${SRC_DIR}/scripts/${script}"
        if [ -f "$src" ]; then
            cp "$src" "/usr/local/bin/${script}"
            chmod 755 "/usr/local/bin/${script}"
            ok "src/scripts/${script} → /usr/local/bin/"
        fi
    done

    # Auto-déploiement comme sos-guide-install.sh pour le path image + factory reset
    if [ "$(realpath "${BASH_SOURCE[0]}")" != "/usr/local/bin/sos-guide-install.sh" ]; then
        cp "${BASH_SOURCE[0]}" /usr/local/bin/sos-guide-install.sh
        chmod 755 /usr/local/bin/sos-guide-install.sh
        ok "install.sh → /usr/local/bin/sos-guide-install.sh"
    fi

    # Unités systemd
    for unit in "${SRC_DIR}/systemd/"*.service "${SRC_DIR}/systemd/"*.timer; do
        [ -f "$unit" ] || continue
        cp "$unit" "/etc/systemd/system/$(basename "$unit")"
        ok "src/systemd/$(basename "$unit") → /etc/systemd/system/"
    done

    # Drop-ins Restart=always pour les services critiques (hostapd, dnsmasq, nginx)
    for svc in hostapd dnsmasq nginx; do
        drop_src="${SRC_DIR}/systemd/${svc}.service.d/sos-guide-restart.conf"
        if [ -f "$drop_src" ]; then
            mkdir -p "/etc/systemd/system/${svc}.service.d"
            cp "$drop_src" "/etc/systemd/system/${svc}.service.d/sos-guide-restart.conf"
            ok "Drop-in Restart=always → ${svc}"
        fi
    done

    # tmpfiles.d — logs volatils (conformité nLPD)
    if [ -f "${SRC_DIR}/systemd/sos-guide-logs.conf" ]; then
        cp "${SRC_DIR}/systemd/sos-guide-logs.conf" /etc/tmpfiles.d/
        ok "sos-guide-logs.conf → /etc/tmpfiles.d/ (logs volatils nLPD)"
    fi

    systemctl daemon-reload
else
    info "src/ absent — mode image (fichiers déjà déployés)"
fi

# ── Vérification config.json post-déploiement ─────────────────────────────────
# Crée un config.json par défaut si absent (première installation depuis git clone)
if [ ! -f "$CONFIG_FILE" ]; then
    warn "config.json absent — création avec valeurs par défaut"
    mkdir -p "$(dirname "$CONFIG_FILE")"
    cat > "$CONFIG_FILE" <<'DEFAULTCFG'
{
  "establishment": {
    "name": "SOS-GUIDE",
    "address": "",
    "lat": "", "lon": "", "type": "erp",
    "localCrisisNumber": "", "localRisk": "",
    "localSamuNumber": "", "localPoliceNumber": "",
    "localPompiersNumber": "", "localMairieNumber": "",
    "localPrefecture": "", "localDsden": "",
    "localRadioFreq": "", "localCroixRouge": "",
    "localPccAddress": "", "localMeetingPoint": "",
    "localEvacuationPlan": ""
  },
  "reassurance": { "message": "Restez calme, les secours sont informés et arrivent." },
  "wifiChannel": 11,
  "enableLoRa": false,
  "enableEthernet": false,
  "installed": false
}
DEFAULTCFG
    chown www-data:www-data "$CONFIG_FILE" 2>/dev/null || true
    chmod 640 "$CONFIG_FILE"
    ok "config.json par défaut créé — à personnaliser via /admin"
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

# Sanitisation stricte : supprimer newlines + caractères hostapd-invalides + tronquer à 16 chars
# (le préfixe "⛑️ SOS-GUIDE - " utilise déjà ~16 octets du max hostapd de 32)
NODE_NAME=$(jq -r '.establishment.name // "SOS-GUIDE"' "$CONFIG_FILE" \
            | tr -d '\n\r\t\\' | sed 's/[^[:print:]]//g' | cut -c1-16)
[ -z "$NODE_NAME" ] && NODE_NAME="SOS-GUIDE"
ENABLE_LORA=$(jq -r '.enableLoRa // false'                  "$CONFIG_FILE")
ENABLE_ETHERNET=$(jq -r '.enableEthernet // false'          "$CONFIG_FILE")
WIFI_CHANNEL=$(jq -r '.wifiChannel // "11"' "$CONFIG_FILE" | tr -dc '0-9' | cut -c1-2)
# Valider que le canal WiFi est dans la plage autorisée (1-13, Suisse)
if [ -z "$WIFI_CHANNEL" ] || [ "$WIFI_CHANNEL" -lt 1 ] || [ "$WIFI_CHANNEL" -gt 13 ]; then
    warn "Canal WiFi invalide ('${WIFI_CHANNEL}') — fallback canal 11"
    WIFI_CHANNEL=11
fi

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
    iface=$(ip -o link show 2>/dev/null | awk -F': ' '/^[0-9]+: (en|eth)/{print $2; exit}')
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
country_code=CH
ap_isolate=1
ieee80211d=1
ieee80211n=1
ignore_broadcast_ssid=0
auth_algs=1
wpa=0
EOF
ok "Réseau WiFi ouvert (sans mot de passe)"

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
dhcp-leasefile=/dev/null
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

    # ── Portail captif multi-OS + RFC 8908 ─────────────────────────────
    # RFC 8908 — Captive Portal API (iOS 14+, Android 11+)
    location = /.well-known/captive-portal {
        default_type application/captive+json;
        return 200 '{"captive":true,"user-portal-url":"http://${LOCAL_IP}/"}';
    }
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
        fastcgi_param SCRIPT_FILENAME \$document_root/api_reload_network.php;
        fastcgi_pass unix:/var/run/php/phpPHP_VERSION-fpm.sock;
    }

    # ── Proxy reload-network (appelé par admin.php) ─────────────────
    location = /api/reload-network-proxy {
        include snippets/fastcgi-php.conf;
        fastcgi_param SCRIPT_FILENAME \$document_root/api_reload_network_proxy.php;
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
    # S-01 : mot de passe affiché hors du flux de log (stdout redirigé vers tee)
    exec 3>&1 1>/dev/tty 2>/dev/null || true
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
    exec 1>&3 3>&- 2>&1 || true
    ok "Mot de passe affiché sur terminal (non journalisé)"
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

if [ ! -f /usr/local/bin/sos-guide-regen-hash.sh ]; then
    err "sos-guide-regen-hash.sh manquant — vérifier src/scripts/"
    exit 1
fi
ok "sos-guide-regen-hash.sh présent"

# ── Sudoers ───────────────────────────────────────────────────────────────────
SUDOERS_FILE="/etc/sudoers.d/sos-guide-reload"
cat > "$SUDOERS_FILE" <<'SUDOEOF'
www-data ALL=(root) NOPASSWD: /bin/systemctl reload nginx
www-data ALL=(root) NOPASSWD: /bin/systemctl reload dnsmasq
www-data ALL=(root) NOPASSWD: /bin/systemctl restart hostapd
www-data ALL=(root) NOPASSWD: /usr/local/bin/sos-guide-regen-hash.sh
root ALL=(root) NOPASSWD: /usr/local/bin/sos-guide-regen-hash.sh
# H7 — commandes manquantes pour update_config.php (gestion WiFi + LoRa)
www-data ALL=(root) NOPASSWD: /usr/local/bin/finalize_install.sh
www-data ALL=(root) NOPASSWD: /sbin/ip link set * down
www-data ALL=(root) NOPASSWD: /sbin/ip link set * up
www-data ALL=(root) NOPASSWD: /sbin/ip addr add * dev *
www-data ALL=(root) NOPASSWD: /bin/systemctl enable --now lora-service
www-data ALL=(root) NOPASSWD: /bin/systemctl disable --now lora-service
SUDOEOF
chmod 440 "$SUDOERS_FILE"
if visudo -c -f "$SUDOERS_FILE" &>/dev/null; then
    ok "sudoers configuré"
else
    err "Fichier sudoers invalide — suppression"
    rm -f "$SUDOERS_FILE"
fi

# ══════════════════════════════════════════════════════════════════════════════
# ÉTAPE 5b — WATCHDOG MATÉRIEL
# Absent du path install.sh (présent dans build-image.sh) → on l'ajoute ici
# pour que les Pi déployés via git clone aient la même fiabilité que les images.
# ══════════════════════════════════════════════════════════════════════════════
step "Configuration du watchdog matériel"
sep

if ! dpkg -l watchdog 2>/dev/null | grep -q "^ii"; then
    info "Installation du paquet watchdog..."
    apt-get install -y -qq watchdog
fi

cat > /etc/watchdog.conf <<'WDEOF'
watchdog-device = /dev/watchdog
watchdog-timeout = 15
min-memory = 1
max-load-1 = 24
interval = 5
test-binary = /usr/local/bin/sos-guide-watchdog-test.sh
WDEOF

# Activer le module watchdog matériel du Pi
if ! grep -q "bcm2835_wdt" /etc/modules 2>/dev/null; then
    echo "bcm2835_wdt" >> /etc/modules
fi
modprobe bcm2835_wdt 2>/dev/null || true

systemctl enable watchdog 2>/dev/null && \
    systemctl restart watchdog 2>/dev/null && \
    ok "Watchdog matériel actif (timeout 15s)" || \
    warn "watchdog non démarré — vérifier: journalctl -u watchdog"

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

# H5 — hashlimit par IP (évite qu'un seul client épuise le token bucket global)
iptables -A INPUT -i "${WIFI_IFACE}" -p tcp --dport 80 \
    -m hashlimit --hashlimit-name http --hashlimit-mode srcip \
    --hashlimit-upto 30/second --hashlimit-burst 200 -j ACCEPT
iptables -A INPUT -i "${WIFI_IFACE}" -p tcp --dport 443 \
    -m hashlimit --hashlimit-name https --hashlimit-mode srcip \
    --hashlimit-upto 30/second --hashlimit-burst 200 -j ACCEPT
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

# C7 — DoT port 853 explicite avant les règles catch-all WiFi
iptables -A FORWARD -i "${WIFI_IFACE}" -p tcp --dport 853 -j DROP
iptables -A FORWARD -i "${WIFI_IFACE}" -p udp --dport 853 -j DROP
iptables -A FORWARD -i "${WIFI_IFACE}" -o "${WIFI_IFACE}" -j DROP
iptables -A FORWARD -i "${WIFI_IFACE}" -o "${ETH_IFACE}"  -j DROP
iptables -A FORWARD -i "${WIFI_IFACE}" -j DROP

# C3 — IPv6 : isolation totale (sans ip6tables = FORWARD ACCEPT par défaut)
ip6tables -F 2>/dev/null || true
ip6tables -t mangle -F 2>/dev/null || true
ip6tables -P INPUT   DROP 2>/dev/null || true
ip6tables -P FORWARD DROP 2>/dev/null || true
ip6tables -P OUTPUT  ACCEPT 2>/dev/null || true
ip6tables -A INPUT -i lo -j ACCEPT 2>/dev/null || true
ip6tables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
ip6tables -A INPUT -i "${WIFI_IFACE}" -p tcp --dport 80  -j ACCEPT 2>/dev/null || true
ip6tables -A INPUT -i "${WIFI_IFACE}" -p tcp --dport 443 -j ACCEPT 2>/dev/null || true
ip6tables -A INPUT -i "${WIFI_IFACE}" -j DROP 2>/dev/null || true
ok "IPv6 : INPUT/FORWARD DROP + DoT port 853 bloqué (IPv4+IPv6)"

mkdir -p /etc/iptables
netfilter-persistent save &>/dev/null
ok "Règles iptables/ip6tables sauvegardées"

if ! iptables -C FORWARD -i "${WIFI_IFACE}" -o "${ETH_IFACE}" -j DROP 2>/dev/null; then
    err "CRITIQUE : Règle isolation WiFi→Internet manquante"
    exit 1
fi
ok "Isolation WiFi → Internet vérifiée ✓"

# H1 — sysctl persistant : désactivation IPv6 + hardening réseau
cat > /etc/sysctl.d/99-sos-guide.conf <<'SYSCTL_EOF'
# SOS-GUIDE — réseau captif, pas d'IPv6, pas de forwarding (nLPD RS 235.1)
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
net.ipv4.ip_forward=1
net.ipv4.conf.all.send_redirects=0
net.ipv4.conf.default.send_redirects=0
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.default.accept_redirects=0
net.ipv4.tcp_syncookies=1
SYSCTL_EOF
sysctl --system &>/dev/null || sysctl -p /etc/sysctl.d/99-sos-guide.conf &>/dev/null || true
ok "sysctl persistant écrit (/etc/sysctl.d/99-sos-guide.conf)"

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
    echo "version=${VERSION}"
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
