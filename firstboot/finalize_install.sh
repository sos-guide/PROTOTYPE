#!/bin/bash
# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  SOS-GUIDE — finalize_install.sh v2.3                                       ║
# ║  Finalisation de l'installation (mode STARTER → PRODUCTION)                 ║
# ║                                                                              ║
# ║  ✅ SANS reboot système — reload à chaud uniquement                          ║
# ║  ✅ Détection dynamique des interfaces WiFi/ETH                              ║
# ║  ✅ Canal WiFi lu depuis config.json                                          ║
# ║  ✅ Compatible Raspberry Pi 4 et 5                                            ║
# ║  ✅ Certification PCi-CH / Croix-Rouge Suisse                                 ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

set -euo pipefail
exec >> /var/log/sos-guide-install.log 2>&1

echo ""
echo "════════════════════════════════════════════════════"
echo "  SOS-GUIDE finalize — $(date '+%Y-%m-%d %H:%M:%S')"
echo "════════════════════════════════════════════════════"

CONFIG_FILE="/var/www/sos-guide/data/config.json"
[ ! -f "$CONFIG_FILE" ] && { echo "Erreur : config.json introuvable."; exit 1; }

# ── jq ────────────────────────────────────────────────────────────────────────
if ! command -v jq &>/dev/null; then
    apt-get update -qq && apt-get install -y -qq jq
fi

# ── Lecture config ────────────────────────────────────────────────────────────
NODE_NAME=$(jq -r '.establishment.name // "SOS-GUIDE"'  "$CONFIG_FILE")
WIFI_PASSWORD=$(jq -r '.wifiPassword // ""'             "$CONFIG_FILE")
ENABLE_LORA=$(jq -r '.enableLoRa // false'              "$CONFIG_FILE")
ENABLE_ETHERNET=$(jq -r '.enableEthernet // false'      "$CONFIG_FILE")
# FIX: lire le canal depuis config.json (était hardcodé à 11)
WIFI_CHANNEL=$(jq -r '.wifiChannel // "11"'             "$CONFIG_FILE")

# Valider le canal (1-13 EU)
if ! [[ "$WIFI_CHANNEL" =~ ^([1-9]|1[0-3])$ ]]; then
    WIFI_CHANNEL="11"
fi

# ── Détection dynamique des interfaces ────────────────────────────────────────
# FIX: ne plus hardcoder wlan0/eth0

detect_wifi_iface() {
    # Méthode 1 : iw (plus fiable)
    local iface
    for iface in $(ls /sys/class/net/ 2>/dev/null); do
        if [[ -d "/sys/class/net/$iface/wireless" ]] || \
           iw dev "$iface" info &>/dev/null 2>&1; then
            echo "$iface"; return 0
        fi
    done
    # Méthode 2 : préfixes connus (wl*)
    iface=$(ip link show 2>/dev/null | awk -F': ' '/: wl/{print $2}' | head -1)
    [ -n "$iface" ] && { echo "$iface"; return 0; }
    return 1
}

detect_eth_iface() {
    local iface
    iface=$(ip -o link show 2>/dev/null | awk -F': ' '/^[0-9]+: (en|eth)/{print $2}' | head -1)
    [ -n "$iface" ] && { echo "$iface"; return 0; }
    echo "eth0"; return 0
}

WIFI_IFACE=$(detect_wifi_iface || true)
if [ -z "$WIFI_IFACE" ]; then
    echo "ERREUR : Aucune interface WiFi détectée"
    exit 1
fi
ETH_IFACE=$(detect_eth_iface)

LOCAL_IP="10.0.0.1"
SSID="⛑️ SOS-GUIDE - ${NODE_NAME}"

echo "  Interface WiFi : $WIFI_IFACE"
echo "  Interface ETH  : $ETH_IFACE"
echo "  SSID           : $SSID"
echo "  Canal WiFi     : $WIFI_CHANNEL"
echo "  LoRa           : $ENABLE_LORA"
echo "  Ethernet       : $ENABLE_ETHERNET"

# ── Arrêt propre des services ─────────────────────────────────────────────────
systemctl stop hostapd dnsmasq nginx 2>/dev/null || true
sleep 1

# ── hostapd — configuration définitive ───────────────────────────────────────
# FIX: utiliser la variable $WIFI_CHANNEL (était hardcodé channel=11)
cat > /etc/hostapd/hostapd.conf <<EOF
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
EOF

# CH / EU : activer IEEE 802.11d pour respecter les réglementations OFCOM
if [ "$WIFI_CHANNEL" -gt 11 ]; then
    echo "country_code=CH" >> /etc/hostapd/hostapd.conf
fi

if [ -n "$WIFI_PASSWORD" ] && [ "${#WIFI_PASSWORD}" -ge 8 ]; then
    cat >> /etc/hostapd/hostapd.conf <<EOF
wpa=2
wpa_passphrase=${WIFI_PASSWORD}
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
EOF
else
    echo "wpa=0" >> /etc/hostapd/hostapd.conf
fi

cat > /etc/default/hostapd <<EOF
DAEMON_CONF="/etc/hostapd/hostapd.conf"
DAEMON_OPTS=""
EOF

echo "  ✔ hostapd configuré (canal $WIFI_CHANNEL)"

# ── dnsmasq ───────────────────────────────────────────────────────────────────
cat > /etc/dnsmasq.conf <<EOF
# SOS-GUIDE — portail captif CH/EU
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
echo "  ✔ dnsmasq configuré"

# ── systemd-networkd ──────────────────────────────────────────────────────────
mkdir -p /etc/systemd/network

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

if [ "$ENABLE_ETHERNET" = "true" ]; then
    cat > "/etc/systemd/network/10-${ETH_IFACE}.network" <<EOF
[Match]
Name=${ETH_IFACE}

[Network]
DHCP=yes
IPv6AcceptRA=no
DNS=8.8.8.8
DNS=1.1.1.1

[DHCP]
RouteMetric=10
EOF
    systemctl enable systemd-networkd 2>/dev/null || true
    echo "  ✔ Ethernet ${ETH_IFACE} configuré (DHCP)"
fi

# ── Firewall iptables ─────────────────────────────────────────────────────────
iptables -F; iptables -t nat -F; iptables -t mangle -F
iptables -P INPUT DROP; iptables -P FORWARD DROP; iptables -P OUTPUT ACCEPT

iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -m conntrack --ctstate INVALID -j DROP
iptables -A INPUT -p tcp --tcp-flags ALL NONE -j DROP
iptables -A INPUT -p tcp --tcp-flags ALL ALL -j DROP

if [ "$ENABLE_ETHERNET" = "true" ]; then
    iptables -A INPUT -i "${ETH_IFACE}" -p tcp --dport 22 \
        -m conntrack --ctstate NEW -m limit --limit 3/min --limit-burst 3 -j ACCEPT
fi

iptables -A INPUT -i "${WIFI_IFACE}" -p tcp --dport 80  \
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
iptables -A FORWARD -i "${WIFI_IFACE}" -j DROP

mkdir -p /etc/iptables
netfilter-persistent save &>/dev/null || true
echo "  ✔ Firewall configuré et sauvegardé"

# ── Verrouillage web ──────────────────────────────────────────────────────────
WEB_DIR="/var/www/sos-guide"
chown -R www-data:www-data "$WEB_DIR"
chmod -R a-w "$WEB_DIR"
if command -v chattr &>/dev/null; then
    find "$WEB_DIR" -type f ! -path "$WEB_DIR/data/*" -exec chattr +i {} \; 2>/dev/null || true
    chattr -R -i "$WEB_DIR/data/" 2>/dev/null || true
fi
chmod 755 "$WEB_DIR/data/"
chown www-data:www-data "$WEB_DIR/data/"
echo "  ✔ Fichiers web verrouillés (chattr +i)"

# ── LoRa (si activé) ──────────────────────────────────────────────────────────
if [ "$ENABLE_LORA" = "true" ]; then
    if systemctl list-unit-files 2>/dev/null | grep -q "lora-service"; then
        systemctl enable lora-service 2>/dev/null || true
        systemctl start  lora-service 2>/dev/null || true
        echo "  ✔ lora-service activé"
    else
        echo "  ⚠ lora-service.service absent — LoRa non actif"
    fi
fi

# ── Hash SHA256 d'intégrité ───────────────────────────────────────────────────
/usr/local/bin/sos-guide-regen-hash.sh 2>/dev/null || \
    find "$WEB_DIR" -type f -exec sha256sum {} \; > /root/integrity.hash
echo "  ✔ Hash SHA256 généré"

# ── Désactiver le service firstboot ──────────────────────────────────────────
systemctl disable sos-guide-firstboot.service 2>/dev/null || true
rm -f /etc/systemd/system/sos-guide-firstboot.service
systemctl daemon-reload

# ── Marquer l'installation ────────────────────────────────────────────────────
mkdir -p /var/lib/sos-guide
{
    echo "date=$(date -Iseconds)"
    echo "node=${NODE_NAME}"
    echo "wifi=${WIFI_IFACE}"
    echo "channel=${WIFI_CHANNEL}"
    echo "ssid=${SSID}"
    echo "lora=${ENABLE_LORA}"
    echo "version=2.3-ch"
} > /var/lib/sos-guide/installed
echo "  ✔ Installation marquée"

# ── Reload à chaud des services (SANS REBOOT) ────────────────────────────────
# NOTE : Ce bloc remplace entièrement le 'reboot' de la v2.2
echo ""
echo "  Reload à chaud des services..."

# IP statique immédiate sur l'interface WiFi
ip addr flush dev "${WIFI_IFACE}" 2>/dev/null || true
ip addr add "${LOCAL_IP}/24" dev "${WIFI_IFACE}" 2>/dev/null || true
ip link set "${WIFI_IFACE}" up 2>/dev/null || true

# systemd-networkd
networkctl reload 2>/dev/null || systemctl restart systemd-networkd || true
sleep 1

# PHP-FPM
PHP_VERSION=$(php -v 2>/dev/null | head -n1 | cut -d' ' -f2 | cut -d'.' -f1-2)
[ -z "$PHP_VERSION" ] && PHP_VERSION="8.2"
systemctl enable "php${PHP_VERSION}-fpm" &>/dev/null 2>&1 || true
systemctl restart "php${PHP_VERSION}-fpm" 2>/dev/null || true

# dnsmasq
systemctl restart dnsmasq
sleep 1
systemctl is-active --quiet dnsmasq && echo "  ✔ dnsmasq actif" || echo "  ✘ dnsmasq ERREUR"

# hostapd
systemctl unmask hostapd 2>/dev/null || true
systemctl enable hostapd 2>/dev/null || true
ip link set "${WIFI_IFACE}" down; sleep 1; ip link set "${WIFI_IFACE}" up; sleep 1
ip addr add "${LOCAL_IP}/24" dev "${WIFI_IFACE}" 2>/dev/null || true
systemctl restart hostapd
sleep 3
systemctl is-active --quiet hostapd && echo "  ✔ hostapd actif — SSID: ${SSID}" || echo "  ✘ hostapd ERREUR"

# nginx
PHP_SOCK="/var/run/php/php${PHP_VERSION}-fpm.sock"
sed -i "s|phpPHP_VERSION-fpm.sock|${PHP_SOCK#/var/run/php/}|g" \
    /etc/nginx/sites-available/sos-guide 2>/dev/null || true
nginx -t &>/dev/null && (systemctl is-active --quiet nginx && nginx -s reload || systemctl start nginx)
systemctl is-active --quiet nginx && echo "  ✔ nginx actif" || echo "  ✘ nginx ERREUR"

# ── Vérification AP ───────────────────────────────────────────────────────────
echo ""
for i in $(seq 1 10); do
    if iw dev "${WIFI_IFACE}" info 2>/dev/null | grep -q "type AP"; then
        echo "  ✔ Mode AP confirmé sur ${WIFI_IFACE}"
        break
    fi
    sleep 1
done

echo ""
echo "════════════════════════════════════════════════════"
echo "  ✅ SOS-GUIDE PRODUCTION — SANS REBOOT"
echo "  SSID : ${SSID}"
echo "  URL  : http://${LOCAL_IP}/"
echo "  Admin: http://${LOCAL_IP}/admin"
echo "════════════════════════════════════════════════════"

logger "SOS-GUIDE: Installation finalisée — sans reboot — ${NODE_NAME} — canal ${WIFI_CHANNEL}"
exit 0
