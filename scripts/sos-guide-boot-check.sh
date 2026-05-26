#!/bin/bash
# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  SOS-GUIDE — sos-guide-boot-check.sh v2.3                                  ║
# ║  Vérification d'intégrité et d'isolation réseau au démarrage                ║
# ║                                                                              ║
# ║  CORRECTIONS v2.3 :                                                          ║
# ║  ✅ Détection dynamique des interfaces (plus de wlan0/eth0 hardcodés)        ║
# ║  ✅ Vérification intégrité SHA256 avec rapport détaillé                      ║
# ║  ✅ Restauration automatique des règles iptables si compromises               ║
# ║  ✅ Journal structuré JSON pour PCi-CH                                        ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

set -euo pipefail

HASH_FILE="/root/integrity.hash"
AUDIT_LOG="/var/log/sos-guide-boot-check.log"
INSTALL_MARKER="/var/lib/sos-guide/installed"

# ── Logger JSON ───────────────────────────────────────────────────────────────
log_event() {
    local level="$1" msg="$2" extra="${3:-}"
    local entry
    entry=$(printf '{"ts":"%s","level":"%s","event":"%s"%s}\n' \
        "$(date -Iseconds)" "$level" "$msg" \
        "${extra:+,\"detail\":\"$extra\"}")
    echo "$entry" >> "$AUDIT_LOG" 2>/dev/null || true
    logger -t sos-guide-check "$level: $msg ${extra:+— $extra}"
}

# ── Détecter les interfaces dynamiquement ────────────────────────────────────
detect_wifi() {
    for iface in /sys/class/net/*; do
        iface=$(basename "$iface")
        if [[ -d "/sys/class/net/$iface/wireless" ]]; then
            echo "$iface"; return 0
        fi
    done
    # Fallback préfixe wl*
    ip link show 2>/dev/null | awk -F': ' '/: wl/{gsub(/@.*/,"",$2); print $2}' | head -1
}

detect_eth() {
    ip -o link show 2>/dev/null \
        | awk -F': ' '/^[0-9]+: (en|eth)/{gsub(/@.*/,"",$2); print $2}' \
        | head -1
}

WIFI_IFACE=$(detect_wifi || echo "")
ETH_IFACE=$(detect_eth  || echo "eth0")

# ── 1. Vérification intégrité SHA256 ─────────────────────────────────────────
if [ -f "$HASH_FILE" ]; then
    if ! sha256sum -c "$HASH_FILE" --quiet 2>/dev/null; then
        FAILED=$(sha256sum -c "$HASH_FILE" 2>/dev/null | grep "FAILED" | head -5 || true)
        log_event "CRITICAL" "INTEGRITE_COMPROMISE" "$FAILED"
        # En production bunker : poweroff immédiat
        if [ -f "$INSTALL_MARKER" ]; then
            log_event "CRITICAL" "SHUTDOWN_INTEGRITY" "Arrêt système de sécurité"
            sync
            poweroff --force
        fi
        exit 1
    else
        log_event "INFO" "INTEGRITE_OK" "$(wc -l < "$HASH_FILE") fichiers vérifiés"
    fi
else
    log_event "WARN" "HASH_FILE_ABSENT" "$HASH_FILE introuvable — première installation?"
fi

# ── 2. Vérification isolation iptables ───────────────────────────────────────
if [ -z "$WIFI_IFACE" ]; then
    log_event "WARN" "NO_WIFI_IFACE" "Interface WiFi non détectée"
else
    # Vérifier isolation WiFi → Internet
    if ! iptables -C FORWARD -i "${WIFI_IFACE}" -j DROP 2>/dev/null; then
        log_event "CRITICAL" "ISOLATION_COMPROMISE" "Règle isolation ${WIFI_IFACE}→Internet manquante"
        # Restauration d'urgence
        iptables -P FORWARD DROP
        iptables -A FORWARD -i "${WIFI_IFACE}" -o "${WIFI_IFACE}" -j DROP
        iptables -A FORWARD -i "${WIFI_IFACE}" -j DROP
        if [ -n "$ETH_IFACE" ]; then
            iptables -A FORWARD -i "${WIFI_IFACE}" -o "${ETH_IFACE}" -j DROP
        fi
        log_event "WARN" "ISOLATION_RESTORED" "Règles iptables restaurées en urgence"
    else
        log_event "INFO" "ISOLATION_OK" "${WIFI_IFACE} isolé d'Internet"
    fi
fi

# ── 3. Détecter NAT sortant parasite ─────────────────────────────────────────
MASQ=$(iptables -t nat -L POSTROUTING -n 2>/dev/null | grep -c "MASQUERADE\|SNAT" || true)
if [ "$MASQ" -gt 0 ]; then
    log_event "CRITICAL" "NAT_SORTANT_DETECTE" "MASQUERADE/SNAT supprimés ($MASQ règles)"
    iptables -t nat -F POSTROUTING
fi

# ── 4. Vérifier les services critiques ───────────────────────────────────────
for svc in hostapd dnsmasq nginx; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        log_event "INFO" "SERVICE_OK" "$svc actif"
    else
        log_event "WARN" "SERVICE_DOWN" "$svc arrêté — tentative de redémarrage"
        systemctl start "$svc" 2>/dev/null || \
            log_event "ERROR" "SERVICE_START_FAILED" "$svc impossible à démarrer"
    fi
done

# ── 5. Vérifier l'IP de l'AP ─────────────────────────────────────────────────
if [ -n "$WIFI_IFACE" ]; then
    if ! ip -4 addr show "${WIFI_IFACE}" 2>/dev/null | grep -q "10\.0\.0\.1"; then
        log_event "WARN" "AP_IP_ABSENT" "Réattribution 10.0.0.1 sur ${WIFI_IFACE}"
        ip addr add 10.0.0.1/24 dev "${WIFI_IFACE}" 2>/dev/null || true
    fi
fi

# ── 6. Vérifier IPv6 désactivé (conformité nLPD) ────────────────────────────
if ip -6 addr show 2>/dev/null | grep -q "scope global"; then
    log_event "WARN" "IPV6_ACTIF" "IPv6 global détecté — désactivation"
    sysctl -w net.ipv6.conf.all.disable_ipv6=1 &>/dev/null || true
fi

log_event "INFO" "BOOT_CHECK_OK" "Vérification terminée — $(date -Iseconds)"
exit 0
