#!/bin/bash
# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  SOS-GUIDE — sos-guide-boot-check.sh v2.4                                  ║
# ║  Vérification d'intégrité et d'isolation réseau                             ║
# ║                                                                              ║
# ║  CORRECTIONS v2.4 :                                                          ║
# ║  ✅ Remplacement du poweroff --force par un MODE DÉGRADÉ                    ║
# ║     → PHP-FPM stoppé (plus d'écriture) mais portail HTML statique actif    ║
# ║     → Création de INTEGRITY_ALERT.flag (affiché sur le portail)             ║
# ║     → Les guides d'urgence restent accessibles même en cas d'anomalie       ║
# ║  ✅ Détection dynamique des interfaces (pas de wlan0/eth0 hardcodés)         ║
# ║  ✅ Vérification intégrité SHA256 avec rapport détaillé                      ║
# ║  ✅ Restauration automatique des règles iptables si compromises               ║
# ║  ✅ Journal structuré JSON pour PCi-CH                                        ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

set -euo pipefail

HASH_FILE="/root/integrity.hash"
AUDIT_LOG="/var/log/sos-guide-boot-check.log"
INSTALL_MARKER="/var/lib/sos-guide/installed"
ALERT_FLAG="/var/www/sos-guide/INTEGRITY_ALERT.flag"
WEB_DIR="/var/www/sos-guide"

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

# ── Détection dynamique des interfaces ───────────────────────────────────────
detect_wifi() {
    for iface in /sys/class/net/*; do
        iface=$(basename "$iface")
        if [[ -d "/sys/class/net/$iface/wireless" ]]; then
            echo "$iface"; return 0
        fi
    done
    # Fallback préfixe wl*
    ip link show 2>/dev/null \
        | awk -F': ' '/: wl/{gsub(/@.*/,"",$2); print $2}' \
        | head -1
}

detect_eth() {
    ip -o link show 2>/dev/null \
        | awk -F': ' '/^[0-9]+: (en|eth)/{gsub(/@.*/,"",$2); print $2}' \
        | head -1
}

detect_php_version() {
    php -v 2>/dev/null | head -n1 | cut -d' ' -f2 | cut -d'.' -f1-2
}

WIFI_IFACE=$(detect_wifi || true)
ETH_IFACE=$(detect_eth  || true)
ETH_IFACE=${ETH_IFACE:-eth0}
PHP_VERSION=$(detect_php_version || true)
PHP_VERSION=${PHP_VERSION:-8.2}

# ── v2.4 : Mode dégradé — remplace poweroff ───────────────────────────────────
# ANCIENNE LOGIQUE (v2.3) :
#   poweroff --force  ← tuait le nœud définitivement sur bit flip SD card
#
# NOUVELLE LOGIQUE (v2.4) :
#   1. Créer INTEGRITY_ALERT.flag  → portail affiche une bannière d'alerte
#   2. Stopper PHP-FPM             → plus d'écriture possible
#   3. nginx continue de servir le HTML/JSON statique → guides accessibles
#   4. Logger l'événement pour audit
#   5. Notifier via syslog
enter_degraded_mode() {
    local reason="$1"

    log_event "CRITICAL" "INTEGRITE_COMPROMISE" "$reason"

    # Créer le flag d'alerte visible par index.html (fetch INTEGRITY_ALERT.flag)
    mkdir -p "$WEB_DIR"
    printf '%s|%s\n' "$(date -Iseconds)" "$reason" > "$ALERT_FLAG"
    chmod 444 "$ALERT_FLAG"
    chown www-data:www-data "$ALERT_FLAG" 2>/dev/null || true

    # Stopper PHP-FPM pour bloquer toute écriture via l'admin
    # Le HTML statique (index.html) et les JSON restent servis par nginx
    if systemctl is-active --quiet "php${PHP_VERSION}-fpm" 2>/dev/null; then
        systemctl stop "php${PHP_VERSION}-fpm" 2>/dev/null || true
        log_event "WARN" "PHP_FPM_STOPPED" "php${PHP_VERSION}-fpm arrêté — portail en lecture seule"
    fi

    # Notifier via syslog (visible SSH/ETH)
    logger -p user.crit \
        "SOS-GUIDE: INTEGRITÉ COMPROMISE — portail en mode lecture seule — $reason"

    log_event "WARN" "DEGRADED_MODE_ACTIVE" \
        "Portail HTML accessible — PHP stoppé — Vérifier via SSH: sos-guide-regen-hash.sh"

    # NE PAS poweroff — les guides d'urgence restent accessibles
    # L'admin doit se connecter en SSH ou ETH pour corriger
}

# ── Fonction de suppression du mode dégradé (après correction) ────────────────
# Appelée si le hash est valide et qu'un ancien flag existe
clear_degraded_mode() {
    if [ -f "$ALERT_FLAG" ]; then
        rm -f "$ALERT_FLAG"
        log_event "INFO" "DEGRADED_MODE_CLEARED" "Alerte intégrité résolue"
        # Redémarrer PHP-FPM si nécessaire
        if ! systemctl is-active --quiet "php${PHP_VERSION}-fpm" 2>/dev/null; then
            systemctl start "php${PHP_VERSION}-fpm" 2>/dev/null || true
            log_event "INFO" "PHP_FPM_RESTARTED" "php${PHP_VERSION}-fpm redémarré"
        fi
    fi
}

# ── 1. Vérification intégrité SHA256 ─────────────────────────────────────────
if [ -f "$HASH_FILE" ]; then
    if ! sha256sum -c "$HASH_FILE" --quiet 2>/dev/null; then
        FAILED=$(sha256sum -c "$HASH_FILE" 2>/dev/null \
            | grep "FAILED" \
            | head -5 \
            | tr '\n' ';' \
            || true)

        # v2.4 : mode dégradé si installation finalisée
        # (avant l'installation, l'intégrité peut varier normalement)
        if [ -f "$INSTALL_MARKER" ]; then
            enter_degraded_mode "$FAILED"
            exit 1
        else
            log_event "WARN" "INTEGRITE_AVERTISSEMENT" \
                "Hash invalide avant installation finale — ignoré : $FAILED"
        fi
    else
        FILE_COUNT=$(wc -l < "$HASH_FILE" 2>/dev/null || echo "?")
        log_event "INFO" "INTEGRITE_OK" "$FILE_COUNT fichiers vérifiés"
        # Effacer le mode dégradé si tout est revenu à la normale
        clear_degraded_mode
    fi
else
    log_event "WARN" "HASH_FILE_ABSENT" \
        "$HASH_FILE introuvable — première installation ou régénération requise"
    # Pas de mode dégradé pour un hash absent (première install)
fi

# ── 2. Vérification isolation iptables ───────────────────────────────────────
if [ -z "$WIFI_IFACE" ]; then
    log_event "WARN" "NO_WIFI_IFACE" "Interface WiFi non détectée"
else
    # Vérifier la règle d'isolation WiFi → Internet
    if ! iptables -C FORWARD -i "${WIFI_IFACE}" -j DROP 2>/dev/null; then
        log_event "CRITICAL" "ISOLATION_COMPROMISE" \
            "Règle isolation ${WIFI_IFACE}→Internet manquante"

        # Restauration d'urgence des règles d'isolation
        iptables -P FORWARD DROP
        iptables -A FORWARD -i "${WIFI_IFACE}" -o "${WIFI_IFACE}" -j DROP
        iptables -A FORWARD -i "${WIFI_IFACE}" -j DROP
        if [ -n "$ETH_IFACE" ]; then
            iptables -A FORWARD -i "${WIFI_IFACE}" -o "${ETH_IFACE}" -j DROP
        fi
        log_event "WARN" "ISOLATION_RESTORED" \
            "Règles iptables restaurées en urgence sur ${WIFI_IFACE}"
    else
        log_event "INFO" "ISOLATION_OK" "${WIFI_IFACE} correctement isolé d'Internet"
    fi
fi

# ── 3. Détecter NAT sortant parasite ─────────────────────────────────────────
MASQ=$(iptables -t nat -L POSTROUTING -n 2>/dev/null \
    | grep -c "MASQUERADE\|SNAT" \
    || true)
if [ "${MASQ:-0}" -gt 0 ]; then
    log_event "CRITICAL" "NAT_SORTANT_DETECTE" \
        "MASQUERADE/SNAT détecté ($MASQ règle(s)) — suppression"
    iptables -t nat -F POSTROUTING
fi

# ── 4. Vérifier les services critiques ───────────────────────────────────────
# Note : ne pas vérifier PHP-FPM ici — il peut être volontairement stoppé
# en mode dégradé. Seuls nginx, hostapd et dnsmasq sont critiques.
for svc in nginx hostapd dnsmasq; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        log_event "INFO" "SERVICE_OK" "$svc actif"
    else
        log_event "WARN" "SERVICE_DOWN" \
            "$svc arrêté — tentative de redémarrage"
        systemctl start "$svc" 2>/dev/null || \
            log_event "ERROR" "SERVICE_START_FAILED" \
                "$svc impossible à démarrer"
    fi
done

# ── 5. Vérifier l'IP de l'AP ─────────────────────────────────────────────────
if [ -n "$WIFI_IFACE" ]; then
    if ! ip -4 addr show "${WIFI_IFACE}" 2>/dev/null | grep -q "10\.0\.0\.1"; then
        log_event "WARN" "AP_IP_ABSENT" \
            "10.0.0.1 manquante sur ${WIFI_IFACE} — réattribution"
        ip addr add 10.0.0.1/24 dev "${WIFI_IFACE}" 2>/dev/null || true
    fi
fi

# ── 6. Vérifier IPv6 désactivé (conformité nLPD) ────────────────────────────
if ip -6 addr show 2>/dev/null | grep -q "scope global"; then
    log_event "WARN" "IPV6_ACTIF" "IPv6 global détecté — désactivation"
    sysctl -w net.ipv6.conf.all.disable_ipv6=1    &>/dev/null || true
    sysctl -w net.ipv6.conf.default.disable_ipv6=1 &>/dev/null || true
fi

# ── 7. Vérifier que INTEGRITY_ALERT.flag n'est pas là sans raison ─────────────
# Si le hash est OK mais le flag existe encore (redémarrage après correction),
# clear_degraded_mode() l'a déjà supprimé. Ce bloc est un filet de sécurité.
if [ -f "$ALERT_FLAG" ] && [ -f "$HASH_FILE" ]; then
    if sha256sum -c "$HASH_FILE" --quiet 2>/dev/null; then
        clear_degraded_mode
        log_event "INFO" "STALE_ALERT_CLEARED" \
            "Flag INTEGRITY_ALERT.flag obsolète supprimé (hash valide)"
    fi
fi

log_event "INFO" "BOOT_CHECK_OK" \
    "Vérification v2.4 terminée — $(date -Iseconds)"

exit 0
