#!/bin/bash
# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  SOS-GUIDE — sos-guide-regen-hash.sh v2.3                                   ║
# ║  Régénère le hash SHA256 d'intégrité après toute modification               ║
# ║                                                                              ║
# ║  Appelé par :                                                                ║
# ║    - finalize_install.sh  (installation initiale)                            ║
# ║    - update_config.php    (via sudo, après chaque save admin)                ║
# ║    - api_reload_network.php                                                  ║
# ║    - sos-guide-update.sh  (après mise à jour des JSON)                       ║
# ║    - sos-guide-health.service (vérification 5 min)                           ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

set -euo pipefail

WEB_DIR="/var/www/sos-guide"
HASH_FILE="/root/integrity.hash"
TEMP_HASH="${HASH_FILE}.tmp.$$"

# Vérifier que le répertoire web existe
if [ ! -d "$WEB_DIR" ]; then
    echo "ERREUR : $WEB_DIR introuvable" >&2
    exit 1
fi

# Hacher tous les fichiers web SAUF config.json (contenu variable par design)
find "$WEB_DIR" -type f \
    ! -name "config.json" \
    ! -name "*.tmp.*" \
    ! -name "*.log" \
    -exec sha256sum {} \; \
    > "$TEMP_HASH" 2>/dev/null

# Hacher config.json séparément (surveille les modifications non autorisées)
if [ -f "$WEB_DIR/data/config.json" ]; then
    sha256sum "$WEB_DIR/data/config.json" >> "$TEMP_HASH"
fi

# Hacher les configs nginx et systemd (détecte les attaques sur la config réseau)
for cfg in \
    /etc/nginx/sites-available/sos-guide \
    /etc/hostapd/hostapd.conf \
    /etc/dnsmasq.conf \
    /usr/local/bin/sos-guide-boot-check.sh \
    /usr/local/bin/sos-guide-regen-hash.sh; do
    [ -f "$cfg" ] && sha256sum "$cfg" >> "$TEMP_HASH" 2>/dev/null || true
done

# Remplacement atomique
mv "$TEMP_HASH" "$HASH_FILE"
chmod 400 "$HASH_FILE"
chown root:root "$HASH_FILE"

FILE_COUNT=$(wc -l < "$HASH_FILE")
TIMESTAMP=$(date -Iseconds)

logger "SOS-GUIDE: hash SHA256 régénéré — $FILE_COUNT fichiers — $TIMESTAMP"
echo "✔ Hash SHA256 régénéré : $FILE_COUNT fichiers surveillés ($TIMESTAMP)"
exit 0
