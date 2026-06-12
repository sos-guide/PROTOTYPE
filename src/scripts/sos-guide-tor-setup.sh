#!/bin/bash
# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  SOS-GUIDE — sos-guide-tor-setup.sh v2.5                                      ║
# ║  Service caché Tor : nœud de secours pour MISE À JOUR + IDENTIFICATION.       ║
# ║                                                                              ║
# ║  Modèle à trois canaux du nœud SOS-GUIDE :                                   ║
# ║    • WiFi (10.0.0.1) ........ page statique de survie (hors-ligne, public)   ║
# ║    • LoRa (868 MHz) ......... messages d'urgence chiffrés (mesh local)       ║
# ║    • Ethernet → Tor (.onion)  mises à jour de contenu + identification du    ║
# ║                               nœud, via un service caché (anonyme, signé).   ║
# ║                                                                              ║
# ║  Le .onion N'EXPOSE PAS le portail captif : seule la surface restreinte      ║
# ║  tor-node.php (identité + manifeste de mise à jour) y répond, sur            ║
# ║  127.0.0.1:9080. hostapd/dnsmasq ne sont jamais touchés.                     ║
# ║                                                                              ║
# ║  Usage : sudo bash sos-guide-tor-setup.sh [--disable]                        ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

HS_DIR="/var/lib/tor/sos-guide"
TORRC_DROPIN="/etc/tor/torrc.d/sos-guide.conf"
ONION_PUBLISH="/var/lib/sos-guide/onion_hostname"
TOR_VHOST_PORT=9080

[ "$(id -u)" -eq 0 ] || { echo "ERREUR: lancer en root (sudo)"; exit 1; }

# ── Désactivation ─────────────────────────────────────────────────────────────
if [ "${1:-}" = "--disable" ]; then
    rm -f "$TORRC_DROPIN" "$ONION_PUBLISH"
    systemctl restart tor 2>/dev/null || true
    echo "OK: service caché Tor désactivé"
    exit 0
fi

# ── Tor présent ? ─────────────────────────────────────────────────────────────
if ! command -v tor >/dev/null 2>&1; then
    echo "Tor absent — installation..."
    if ! apt-get install -y tor >/dev/null 2>&1; then
        echo "ERREUR: tor introuvable (réseau ?). Inclure tor dans le bundle hors-ligne." >&2
        exit 2
    fi
fi

# ── torrc : inclure le répertoire de drop-ins + déclarer le service caché ─────
mkdir -p /etc/tor/torrc.d
if ! grep -q '^%include /etc/tor/torrc.d' /etc/tor/torrc 2>/dev/null; then
    echo '%include /etc/tor/torrc.d/*.conf' >> /etc/tor/torrc
fi

cat > "$TORRC_DROPIN" <<EOF
# SOS-GUIDE — service caché « nœud de secours » (généré par sos-guide-tor-setup.sh)
HiddenServiceDir ${HS_DIR}/
HiddenServicePort 80 127.0.0.1:${TOR_VHOST_PORT}
# Surface restreinte : seul tor-node.php répond (cf. vhost nginx 127.0.0.1:${TOR_VHOST_PORT}).
EOF
chmod 644 "$TORRC_DROPIN"

# ── (Re)démarrage de Tor et attente de la génération de l'adresse .onion ─────
systemctl enable tor >/dev/null 2>&1 || true
systemctl restart tor

echo -n "Génération de l'adresse .onion"
for _ in $(seq 1 30); do
    if [ -s "${HS_DIR}/hostname" ]; then break; fi
    echo -n "."; sleep 1
done
echo

if [ ! -s "${HS_DIR}/hostname" ]; then
    echo "ERREUR: adresse .onion non générée — voir: journalctl -u tor" >&2
    exit 3
fi

ONION=$(cat "${HS_DIR}/hostname")

# Publier l'adresse pour l'interface admin (lisible par www-data en lecture seule).
mkdir -p "$(dirname "$ONION_PUBLISH")"
printf '%s\n' "$ONION" > "$ONION_PUBLISH"
chmod 644 "$ONION_PUBLISH"

echo ""
echo "  ┌────────────────────────────────────────────────────────────┐"
echo "  │  NŒUD DE SECOURS TOR ACTIF                                  │"
echo "  │  Canal : Ethernet → Tor (mises à jour + identification)    │"
echo "  │                                                            │"
echo "  │  Adresse .onion :                                          │"
echo "  │  ${ONION}"
echo "  │                                                            │"
echo "  │  Accessible via Tor Browser pour :                         │"
echo "  │   • vérifier l'identité/signature du nœud                  │"
echo "  │   • récupérer le manifeste de mise à jour                  │"
echo "  └────────────────────────────────────────────────────────────┘"
echo ""
echo "OK: service caché Tor configuré (HiddenServiceDir ${HS_DIR})"
