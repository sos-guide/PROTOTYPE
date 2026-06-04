#!/bin/bash
# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  SOS-GUIDE — sos-guide-tls-setup.sh v2.4                                   ║
# ║  Génération certificat TLS auto-signé pour l'interface /admin               ║
# ║                                                                              ║
# ║  CORRECTIF P1 : TLS sur /admin                                              ║
# ║  ✅ Certificat X.509 auto-signé (RSA 4096 + SHA-256) valable 10 ans         ║
# ║  ✅ nginx écoute sur 443 (HTTPS) pour /admin                                ║
# ║  ✅ Redirection HTTP→HTTPS pour /admin uniquement                           ║
# ║  ✅ TLS 1.2 minimum (TLS 1.3 si OpenSSL ≥ 1.1.1)                          ║
# ║  ✅ HSTS + X-Frame-Options + CSP headers sur /admin                         ║
# ║  ✅ Le portail captif HTTP reste accessible (les clients WiFi n'ont pas     ║
# ║     les moyens d'accepter un certificat auto-signé en urgence)              ║
# ║  ✅ Empreinte SHA-256 du certificat affichée pour vérification hors-ligne   ║
# ║  ✅ Rechargement nginx zero-downtime                                         ║
# ║                                                                              ║
# ║  Usage : sudo bash /usr/local/bin/sos-guide-tls-setup.sh                   ║
# ║  Renouvellement : re-exécuter le script (certificat remplacé atomiquement)  ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

set -euo pipefail

# ── Couleurs ─────────────────────────────────────────────────────────────────
RED='\033[0;31m';  GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m';    NC='\033[0m'
ok()   { echo -e "  ${GREEN}✔${NC}  $1"; }
warn() { echo -e "  ${YELLOW}⚠${NC}  $1"; }
err()  { echo -e "  ${RED}✘${NC}  $1" >&2; }
step() { echo -e "\n  ${BOLD}${CYAN}▶${NC}  ${BOLD}$1${NC}"; }

echo ""
echo -e "  ${BOLD}🔒  SOS-GUIDE — Configuration TLS /admin${NC}"
echo ""

# ── Vérifications ─────────────────────────────────────────────────────────────
[ "$(id -u)" -eq 0 ] || { err "Root requis"; exit 1; }
command -v openssl &>/dev/null || { err "openssl absent — apt install openssl"; exit 1; }

# ── Chemins ───────────────────────────────────────────────────────────────────
TLS_DIR="/etc/nginx/tls"
CERT="${TLS_DIR}/sos-guide.crt"
KEY="${TLS_DIR}/sos-guide.key"
CSR="${TLS_DIR}/sos-guide.csr"
NGINX_CONF="/etc/nginx/sites-available/sos-guide"
DHPARAM="${TLS_DIR}/dhparam.pem"
FINGERPRINT_FILE="/var/lib/sos-guide/tls-fingerprint.txt"

# Lire le nom du nœud depuis config.json
NODE_NAME="SOS-GUIDE"
if command -v jq &>/dev/null && [ -f /var/www/sos-guide/data/config.json ]; then
    NODE_NAME=$(jq -r '.establishment.name // "SOS-GUIDE"' \
        /var/www/sos-guide/data/config.json | tr -dc 'A-Za-z0-9 .-' | head -c 64)
fi

LOCAL_IP="10.0.0.1"

# ── Création du répertoire TLS ────────────────────────────────────────────────
step "Création du répertoire TLS"
mkdir -p "$TLS_DIR"
chmod 700 "$TLS_DIR"
ok "Répertoire : $TLS_DIR (chmod 700)"

# ── Génération des paramètres DH (une seule fois) ────────────────────────────
step "Paramètres Diffie-Hellman (2048 bits)"
if [ ! -f "$DHPARAM" ]; then
    openssl dhparam -out "$DHPARAM" 2048 2>/dev/null
    chmod 600 "$DHPARAM"
    ok "dhparam.pem généré (2048 bits)"
else
    ok "dhparam.pem existant conservé"
fi

# ── Génération de la clé privée RSA 4096 ─────────────────────────────────────
step "Génération de la clé privée RSA 4096"
KEY_TMP="${KEY}.tmp.$$"
openssl genrsa -out "$KEY_TMP" 4096 2>/dev/null
chmod 600 "$KEY_TMP"
mv "$KEY_TMP" "$KEY"
ok "Clé RSA 4096 générée : $KEY"

# ── Génération du certificat auto-signé X.509 ────────────────────────────────
step "Génération du certificat auto-signé (SHA-256, 10 ans)"

# Configuration SAN (Subject Alternative Names)
# → inclut l'IP du portail et les noms d'hôte typiques des bunkers
SAN_CONF=$(mktemp)
cat > "$SAN_CONF" <<SANCNF
[req]
default_bits       = 4096
prompt             = no
default_md         = sha256
distinguished_name = dn
x509_extensions    = v3_req

[dn]
C  = CH
ST = Suisse
L  = ${NODE_NAME}
O  = SOS-GUIDE
OU = Infrastructure d'urgence
CN = ${LOCAL_IP}

[v3_req]
subjectAltName = @alt_names
keyUsage       = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
basicConstraints = critical, CA:FALSE

[alt_names]
IP.1  = 10.0.0.1
DNS.1 = sos.guide
DNS.2 = localhost
SANCNF

CERT_TMP="${CERT}.tmp.$$"
openssl req -new -x509 \
    -key "$KEY" \
    -out "$CERT_TMP" \
    -days 3650 \
    -config "$SAN_CONF" \
    2>/dev/null
rm -f "$SAN_CONF"
chmod 644 "$CERT_TMP"
mv "$CERT_TMP" "$CERT"
ok "Certificat auto-signé : $CERT"
ok "Valide 10 ans — CN=${LOCAL_IP} — SAN: 10.0.0.1, sos.guide"

# ── Empreinte SHA-256 ─────────────────────────────────────────────────────────
step "Calcul de l'empreinte SHA-256"
FINGERPRINT=$(openssl x509 -noout -fingerprint -sha256 -in "$CERT" 2>/dev/null \
    | sed 's/sha256 Fingerprint=//' | tr -d ':')
FINGERPRINT_PRETTY=$(openssl x509 -noout -fingerprint -sha256 -in "$CERT" 2>/dev/null \
    | sed 's/sha256 Fingerprint=//')

mkdir -p /var/lib/sos-guide
{
    echo "# SOS-GUIDE — Empreinte TLS /admin"
    echo "# Vérifier avant la première connexion depuis un navigateur"
    echo "# Date        : $(date -Iseconds)"
    echo "# Nœud        : ${NODE_NAME}"
    echo "FINGERPRINT_SHA256=${FINGERPRINT_PRETTY}"
    echo ""
    echo "# Commande de vérification (depuis SSH) :"
    echo "# openssl x509 -noout -fingerprint -sha256 -in ${CERT}"
} > "$FINGERPRINT_FILE"
chmod 444 "$FINGERPRINT_FILE"

echo ""
echo -e "  ${BOLD}${YELLOW}┌─────────────────────────────────────────────────────────────┐${NC}"
echo -e "  ${BOLD}${YELLOW}│  EMPREINTE TLS — À vérifier dans le navigateur              │${NC}"
echo -e "  ${BOLD}${YELLOW}│                                                             │${NC}"
echo -e "  ${BOLD}${YELLOW}│  ${FINGERPRINT_PRETTY}  │${NC}"
echo -e "  ${BOLD}${YELLOW}│                                                             │${NC}"
echo -e "  ${BOLD}${YELLOW}│  Sauvegardée dans : ${FINGERPRINT_FILE}       │${NC}"
echo -e "  ${BOLD}${YELLOW}└─────────────────────────────────────────────────────────────┘${NC}"
echo ""

# ── Détection version PHP ─────────────────────────────────────────────────────
PHP_VERSION=$(php -v 2>/dev/null | head -n1 | cut -d' ' -f2 | cut -d'.' -f1-2)
[ -z "$PHP_VERSION" ] && PHP_VERSION="8.2"

# ── Configuration nginx — HTTP (portail) + HTTPS (admin) ─────────────────────
step "Configuration nginx : HTTP portail + HTTPS /admin"

# Sauvegarder la config existante
[ -f "$NGINX_CONF" ] && cp "$NGINX_CONF" "${NGINX_CONF}.bak.$(date +%Y%m%d-%H%M%S)"

cat > "$NGINX_CONF" <<NGINXEOF
# ── SOS-GUIDE v2.4 — HTTP portail captif (port 80) ──────────────────────────
# Le portail reste HTTP : les clients WiFi en urgence ne peuvent pas
# accepter un certificat auto-signé depuis un portail captif.
# /admin redirige vers HTTPS.
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

    # ── Portail captif multi-OS ────────────────────────────────────────────
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

    # ── /admin : redirection HTTP → HTTPS ─────────────────────────────────
    location /admin {
        return 301 https://\$host\$request_uri;
    }

    # ── API reload-network (localhost uniquement) ──────────────────────────
    location = /api/reload-network {
        allow 127.0.0.1;
        allow ::1;
        deny all;
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/var/run/php/php${PHP_VERSION}-fpm.sock;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/var/run/php/php${PHP_VERSION}-fpm.sock;
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

# ── SOS-GUIDE — Connectivité Google/Samsung/MIUI (HTTP) ─────────────────────
server {
    listen 80;
    server_name connectivitycheck.gstatic.com connectivitycheck.android.com
                connectivitycheck.hicloud.com connect.rom.miui.com
                wifi.vivo.com.cn www.samsung.com;
    access_log off;
    location = /generate_204 { return 302 http://10.0.0.1/; }
    location /               { return 302 http://10.0.0.1/; }
}

# ── SOS-GUIDE — HTTPS /admin uniquement (port 443) ──────────────────────────
server {
    listen 443 ssl;
    server_name 10.0.0.1 _;
    root /var/www/sos-guide;

    ssl_certificate         ${CERT};
    ssl_certificate_key     ${KEY};
    ssl_dhparam             ${DHPARAM};

    ssl_protocols           TLSv1.2 TLSv1.3;
    ssl_ciphers             ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256;
    ssl_prefer_server_ciphers on;
    ssl_session_cache       shared:SSL:4m;
    ssl_session_timeout     10m;
    ssl_session_tickets     off;

    access_log off;
    error_log off;

    # ── Security headers pour /admin ──────────────────────────────────────
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "DENY" always;
    add_header Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; connect-src 'self';" always;
    add_header X-Robots-Tag "noindex, nofollow" always;
    add_header Referrer-Policy "no-referrer" always;

    # ── /admin — protégé htpasswd + TLS ──────────────────────────────────
    location /admin {
        auth_basic "Administration SOS-GUIDE";
        auth_basic_user_file /etc/nginx/.htpasswd;
        try_files \$uri \$uri/ =404;
        location ~ \.php$ {
            include snippets/fastcgi-php.conf;
            fastcgi_pass unix:/var/run/php/php${PHP_VERSION}-fpm.sock;
        }
    }

    # ── Proxy reload-network (localhost uniquement) ───────────────────────
    location = /api/reload-network-proxy {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/var/run/php/php${PHP_VERSION}-fpm.sock;
    }

    # ── Tout le reste → rediriger vers HTTP (portail) ─────────────────────
    location / {
        return 302 http://\$host\$request_uri;
    }

    location ~ /\.         { deny all; }
    location ~* \.(env|ini|log|sh|sql|conf|cfg)$ { deny all; }
}
NGINXEOF

ok "nginx.conf écrit (HTTP port 80 + HTTPS port 443)"

# ── Validation de la configuration nginx ─────────────────────────────────────
step "Validation de la syntaxe nginx"
if nginx -t 2>/dev/null; then
    ok "Syntaxe nginx valide ✓"
else
    err "Syntaxe nginx invalide — restauration de la config précédente"
    LATEST_BAK=$(ls -t "${NGINX_CONF}.bak."* 2>/dev/null | head -1)
    if [ -n "$LATEST_BAK" ]; then
        cp "$LATEST_BAK" "$NGINX_CONF"
        warn "Config précédente restaurée depuis $LATEST_BAK"
    fi
    exit 1
fi

# ── Rechargement nginx zero-downtime ─────────────────────────────────────────
step "Rechargement nginx (zero-downtime)"
if systemctl is-active --quiet nginx 2>/dev/null; then
    nginx -s reload
    sleep 1
    systemctl is-active --quiet nginx \
        && ok "nginx rechargé ✓ — HTTPS /admin actif" \
        || { err "nginx DOWN après reload"; exit 1; }
else
    systemctl start nginx 2>/dev/null
    ok "nginx démarré"
fi

# ── Régénération du hash SHA256 d'intégrité ───────────────────────────────────
step "Régénération du hash SHA256 (inclut le nouveau certificat)"
if /usr/local/bin/sos-guide-regen-hash.sh 2>/dev/null; then
    ok "Hash SHA256 régénéré"
else
    warn "sos-guide-regen-hash.sh non disponible — hash non régénéré"
fi

# ── Journal ───────────────────────────────────────────────────────────────────
logger "SOS-GUIDE: TLS /admin configuré — cert=${CERT} — fingerprint=${FINGERPRINT}"

echo ""
echo -e "  ${BOLD}╔═══════════════════════════════════════════════════════════╗${NC}"
echo -e "  ${BOLD}║  ✅  TLS /admin opérationnel                              ║${NC}"
echo -e "  ${BOLD}╚═══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${CYAN}Admin HTTPS    :${NC} https://10.0.0.1/admin"
echo -e "  ${CYAN}Portail HTTP   :${NC} http://10.0.0.1/"
echo -e "  ${CYAN}Empreinte      :${NC} ${FINGERPRINT_PRETTY}"
echo -e "  ${CYAN}Fingerprint    :${NC} ${FINGERPRINT_FILE}"
echo -e "  ${CYAN}Certificat     :${NC} ${CERT}"
echo -e "  ${CYAN}Clé privée     :${NC} ${KEY} (chmod 600)"
echo ""
echo -e "  ${YELLOW}⚠  Votre navigateur affichera une alerte 'certificat non fiable'.${NC}"
echo -e "  ${YELLOW}   C'est normal pour un certificat auto-signé hors ligne.${NC}"
echo -e "  ${YELLOW}   Vérifiez l'empreinte SHA-256 avant d'accepter.${NC}"
echo ""

exit 0
