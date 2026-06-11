#!/bin/bash
set -e

WEB_DIR="/var/www/sos-guide"
RUNTIME_DIR="/run/sos-guide"
SRC_DIR="/app/src"

# ── Répertoires ───────────────────────────────────────────────────────────────
mkdir -p "$WEB_DIR/data" "$RUNTIME_DIR" /var/lib/sos-guide /var/log

# ── Fichiers web (portail principal) ─────────────────────────────────────────
cp -r "$SRC_DIR/web/." "$WEB_DIR/"

# ── Fichiers firstboot (wizard de configuration) ─────────────────────────────
cp "$SRC_DIR/firstboot/api_install.php" "$WEB_DIR/"
cp "$SRC_DIR/firstboot/qrcode.min.js"  "$WEB_DIR/" 2>/dev/null || true

# ── Injection du token CSRF dans starter.html ────────────────────────────────
DEV_TOKEN=$(openssl rand -hex 32)
echo "$DEV_TOKEN" > "$RUNTIME_DIR/firstboot_token"
chmod 400 "$RUNTIME_DIR/firstboot_token"

sed \
    -e "s|%%CSRF_TOKEN%%|${DEV_TOKEN}|g" \
    -e "s|%%WIFI_CHANNEL%%|11|g" \
    -e "s|%%STARTER_SSID%%|⛑️ SOS-GUIDE - DEV MODE|g" \
    "$SRC_DIR/firstboot/starter.html" > "$WEB_DIR/starter.html"

# ── config.json par défaut ────────────────────────────────────────────────────
CONFIG="$WEB_DIR/data/config.json"
[ -f "$CONFIG" ] || cp "$SRC_DIR/web/data/config.json" "$CONFIG"

# ── Compte admin dev (login: admin / pass: dev-sos-guide) ────────────────────
htpasswd -cb /etc/nginx/.htpasswd admin dev-sos-guide
chmod 640 /etc/nginx/.htpasswd

# ── Mock finalize_install.sh ──────────────────────────────────────────────────
# En dev, simule une installation réussie sans toucher au réseau/WiFi
cat > /usr/local/bin/finalize_install.sh << 'MOCK'
#!/bin/bash
# DEV MODE — simule la finalisation sans reconfigurer WiFi/iptables
mkdir -p /var/lib/sos-guide /var/www/sos-guide/data
echo "installed" > /var/lib/sos-guide/installed
chmod 400 /var/lib/sos-guide/installed
logger "SOS-GUIDE DEV: finalize_install.sh simulé"
exit 0
MOCK
chmod +x /usr/local/bin/finalize_install.sh

# ── Sudoers : www-data → finalize_install.sh (mock) ─────────────────────────
echo 'www-data ALL=(root) NOPASSWD: /usr/local/bin/finalize_install.sh' \
    > /etc/sudoers.d/sos-guide-dev
chmod 440 /etc/sudoers.d/sos-guide-dev

# ── Permissions ───────────────────────────────────────────────────────────────
chown -R www-data:www-data "$WEB_DIR" "$RUNTIME_DIR" /var/lib/sos-guide
chmod 755 "$RUNTIME_DIR"
touch /var/log/sos-guide-firstboot-audit.log
chown www-data:www-data /var/log/sos-guide-firstboot-audit.log

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║  SOS-GUIDE — DEV MODE (Docker)                      ║"
echo "╠══════════════════════════════════════════════════════╣"
echo "║  Starter (wizard) : http://localhost:8080/           ║"
echo "║  Portail          : http://localhost:8080/portal     ║"
echo "║  Admin            : http://localhost:8080/admin      ║"
echo "║                     login: admin / dev-sos-guide     ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

exec /usr/bin/supervisord -c /etc/supervisor/conf.d/supervisord.conf
