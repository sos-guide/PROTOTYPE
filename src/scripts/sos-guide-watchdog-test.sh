#!/bin/bash
# SOS-GUIDE — test applicatif pour le watchdog matériel
# Appelé toutes les 5 s par watchdog(8) via test-binary.
# Exit 0 = OK ; exit 1 = défaillance → watchdog compte vers le timeout (15 s).
set -euo pipefail

WIFI_IFACE=$(iw dev 2>/dev/null | awk '/Interface/{print $2; exit}')
LOCAL_IP="10.0.0.1"

# nginx répond sur le port 80 en moins de 3 s
if ! curl -sf --max-time 3 "http://${LOCAL_IP}/" -o /dev/null 2>/dev/null; then
    logger -t sos-guide-watchdog "FAIL: nginx ne répond pas sur ${LOCAL_IP}:80"
    exit 1
fi

# dnsmasq actif
if ! systemctl is-active --quiet dnsmasq 2>/dev/null; then
    logger -t sos-guide-watchdog "FAIL: dnsmasq inactif"
    exit 1
fi

# hostapd actif (AP WiFi indispensable)
if ! systemctl is-active --quiet hostapd 2>/dev/null; then
    logger -t sos-guide-watchdog "FAIL: hostapd inactif"
    exit 1
fi

# Interface WiFi toujours présente
if [ -n "$WIFI_IFACE" ] && ! ip link show "$WIFI_IFACE" up &>/dev/null; then
    logger -t sos-guide-watchdog "FAIL: interface $WIFI_IFACE absente ou DOWN"
    exit 1
fi

exit 0
