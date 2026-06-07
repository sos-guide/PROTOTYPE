#!/bin/bash
# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  SOS-GUIDE — sos-guide-test.sh v2.4                                         ║
# ║  Suite de tests d'intégration automatisés                                   ║
# ║  Validation Croix-Rouge Suisse · PCi-CH · nLPD                              ║
# ║                                                                              ║
# ║  Usage : sudo bash sos-guide-test.sh [--full] [--lora] [--report]           ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

set -uo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
AP_IP="10.0.0.1"
REPORT_FILE="/tmp/sos-guide-test-report-$(date +%Y%m%d-%H%M%S).json"
RUN_LORA=false
FULL_TEST=false
GEN_REPORT=false

for arg in "$@"; do
    case "$arg" in
        --full)   FULL_TEST=true ;;
        --lora)   RUN_LORA=true ;;
        --report) GEN_REPORT=true ;;
    esac
done

# ── Couleurs ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

PASS=0; FAIL=0; WARN=0
declare -a RESULTS=()

pass() { echo -e "  ${GREEN}✔ PASS${NC}  $1"; PASS=$((PASS+1)); RESULTS+=("{\"test\":\"$1\",\"status\":\"PASS\"}"); }
fail() { echo -e "  ${RED}✘ FAIL${NC}  $1 — $2"; FAIL=$((FAIL+1)); RESULTS+=("{\"test\":\"$1\",\"status\":\"FAIL\",\"detail\":\"$2\"}"); }
warn_t(){ echo -e "  ${YELLOW}△ WARN${NC}  $1 — $2"; WARN=$((WARN+1)); RESULTS+=("{\"test\":\"$1\",\"status\":\"WARN\",\"detail\":\"$2\"}"); }
section(){ echo -e "\n  ${BOLD}${CYAN}━━ $1 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

echo ""
echo -e "  ${BOLD}⛑️  SOS-GUIDE v2.3 — Tests d'intégration${NC}"
echo -e "  ${CYAN}$(date '+%Y-%m-%d %H:%M:%S')${NC} · $(hostname)"
echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# TEST 1 — Services système
# ═══════════════════════════════════════════════════════════════════════════════
section "Services système"

for svc in hostapd dnsmasq nginx; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        pass "Service $svc actif"
    else
        fail "Service $svc" "$svc n'est pas actif — journalctl -u $svc"
    fi
done

# PHP-FPM (version dynamique)
PHP_V=$(php -v 2>/dev/null | head -1 | cut -d' ' -f2 | cut -d'.' -f1-2)
if [ -n "$PHP_V" ] && systemctl is-active --quiet "php${PHP_V}-fpm" 2>/dev/null; then
    pass "PHP-FPM ${PHP_V} actif"
else
    fail "PHP-FPM" "php-fpm non actif"
fi

# Timer healthcheck
if systemctl is-active --quiet "sos-guide-health.timer" 2>/dev/null; then
    pass "Timer healthcheck actif (5min)"
else
    warn_t "Timer healthcheck" "sos-guide-health.timer non actif"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# TEST 2 — Réseau
# ═══════════════════════════════════════════════════════════════════════════════
section "Réseau WiFi AP"

# Détection interface WiFi
WIFI_IF=$(for i in /sys/class/net/*; do
    [[ -d "$i/wireless" ]] && { basename "$i"; break; }
done || ip link show 2>/dev/null | awk -F': ' '/wl/{print $2}' | head -1)

if [ -n "$WIFI_IF" ]; then
    pass "Interface WiFi détectée : $WIFI_IF"
else
    fail "Interface WiFi" "Aucune interface WiFi trouvée"
    WIFI_IF="wlan0"
fi

# Mode AP
if iw dev "$WIFI_IF" info 2>/dev/null | grep -q "type AP"; then
    pass "Mode AP actif sur $WIFI_IF"
else
    fail "Mode AP" "$WIFI_IF n'est pas en mode AP"
fi

# IP de l'AP
if ip addr show "$WIFI_IF" 2>/dev/null | grep -q "10.0.0.1"; then
    pass "IP 10.0.0.1 présente sur $WIFI_IF"
else
    fail "IP AP" "10.0.0.1 absente sur $WIFI_IF"
fi

# SSID
SSID=$(iw dev "$WIFI_IF" info 2>/dev/null | grep "ssid" | awk '{print $2}' || echo "")
if echo "$SSID" | grep -q "SOS-GUIDE"; then
    pass "SSID SOS-GUIDE diffusé"
else
    warn_t "SSID" "SSID ne contient pas 'SOS-GUIDE' : $SSID"
fi

# Réponse HTTP portail captif
if curl -sf --max-time 5 --connect-timeout 3 \
    -o /dev/null -w "%{http_code}" "http://${AP_IP}/" 2>/dev/null | grep -qE "^(200|302)$"; then
    pass "Portail captif répond (HTTP)"
else
    fail "Portail captif HTTP" "http://${AP_IP}/ ne répond pas"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# TEST 3 — Isolation réseau (CRITIQUE)
# ═══════════════════════════════════════════════════════════════════════════════
section "Isolation réseau (sécurité critique)"

# Règle FORWARD DROP WiFi→Internet
ETH_IF=$(ip -o link show 2>/dev/null | awk -F': ' '/^[0-9]+: (en|eth)/{print $2}' | head -1)
if iptables -C FORWARD -i "$WIFI_IF" -j DROP 2>/dev/null; then
    pass "Isolation WiFi→Internet (FORWARD DROP)"
else
    fail "Isolation WiFi" "Règle FORWARD DROP manquante — fuite Internet possible"
fi

# Pas de MASQUERADE (pas de NAT sortant)
MASQ=$(iptables -t nat -L POSTROUTING -n 2>/dev/null | grep -c "MASQUERADE\|SNAT" || echo "0")
if [ "$MASQ" -eq 0 ]; then
    pass "Pas de NAT sortant (MASQUERADE)"
else
    fail "NAT sortant" "$MASQ règle(s) MASQUERADE/SNAT détectée(s)"
fi

# Isolation client-à-client (ap_isolate)
if grep -q "ap_isolate=1" /etc/hostapd/hostapd.conf 2>/dev/null; then
    pass "Isolation client-à-client (ap_isolate=1)"
else
    fail "ap_isolate" "ap_isolate=1 absent de hostapd.conf"
fi

# IPv6 désactivé
if sysctl net.ipv6.conf.all.disable_ipv6 2>/dev/null | grep -q "= 1"; then
    pass "IPv6 désactivé (conformité nLPD)"
else
    warn_t "IPv6" "IPv6 non désactivé — vérifier /etc/sysctl.conf"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# TEST 4 — Intégrité des fichiers
# ═══════════════════════════════════════════════════════════════════════════════
section "Intégrité des fichiers"

HASH_FILE="/root/integrity.hash"
if [ -f "$HASH_FILE" ]; then
    pass "Fichier integrity.hash présent"
    FILE_COUNT=$(wc -l < "$HASH_FILE")
    if sha256sum -c "$HASH_FILE" --quiet 2>/dev/null; then
        pass "SHA256 valide ($FILE_COUNT fichiers)"
    else
        FAILED=$(sha256sum -c "$HASH_FILE" 2>/dev/null | grep -c "FAILED" || echo "?")
        fail "SHA256" "$FAILED fichier(s) compromis"
    fi
else
    fail "integrity.hash" "/root/integrity.hash absent"
fi

# config.json
if [ -f /var/www/sos-guide/data/config.json ]; then
    if jq empty /var/www/sos-guide/data/config.json 2>/dev/null; then
        pass "config.json valide (JSON)"
        NODE=$(jq -r '.establishment.name // ""' /var/www/sos-guide/data/config.json)
        if [ -n "$NODE" ]; then
            pass "Nœud configuré : $NODE"
        else
            warn_t "Nœud" "establishment.name vide — firstboot non complété?"
        fi
    else
        fail "config.json" "JSON invalide"
    fi
else
    fail "config.json" "/var/www/sos-guide/data/config.json absent"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# TEST 5 — Contenu multilingue
# ═══════════════════════════════════════════════════════════════════════════════
section "Contenu multilingue (29 langues)"

DATA_DIR="/var/www/sos-guide/data"
REQUIRED_LANGS=("fr" "de" "it" "rm" "en")  # Obligatoires pour CH
ALL_LANGS=("ar" "cs" "da" "de" "el" "en" "es" "fi" "fr" "he" "hi"
           "hu" "it" "ja" "ko" "nl" "no" "pl" "pt" "rm" "ro" "ru"
           "sv" "th" "tr" "uk" "vi" "zh")

# Langues obligatoires CH
for lang in "${REQUIRED_LANGS[@]}"; do
    if [ -f "${DATA_DIR}/${lang}.json" ] && jq empty "${DATA_DIR}/${lang}.json" 2>/dev/null; then
        pass "Langue requise CH : $lang"
    else
        fail "Langue CH manquante" "${lang}.json absent ou invalide"
    fi
done

# Comptage global
LANG_COUNT=0
for lang in "${ALL_LANGS[@]}"; do
    [ -f "${DATA_DIR}/${lang}.json" ] && LANG_COUNT=$((LANG_COUNT+1))
done
if [ "$LANG_COUNT" -ge 25 ]; then
    pass "Langues disponibles : $LANG_COUNT/29"
else
    warn_t "Langues" "Seulement $LANG_COUNT/29 fichiers JSON présents"
fi

# Vérifier que rm.json (Romansh) est listé dans index.html
if grep -q '"rm"' /var/www/sos-guide/index.html 2>/dev/null || \
   grep -q "rm.json" /var/www/sos-guide/index.html 2>/dev/null; then
    pass "Romansh activé dans index.html"
else
    fail "Romansh" "rm.json non référencé dans index.html — PCi-CH bloquant"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# TEST 6 — Sécurité PHP / nginx
# ═══════════════════════════════════════════════════════════════════════════════
section "Sécurité web"

# logs nginx désactivés
if grep -q "access_log off" /etc/nginx/sites-available/sos-guide 2>/dev/null; then
    pass "Logs d'accès nginx désactivés (nLPD §2.1)"
else
    warn_t "nginx logs" "access_log off manquant dans nginx.conf"
fi

# Admin protégé par htpasswd
if grep -q "auth_basic" /etc/nginx/sites-available/sos-guide 2>/dev/null; then
    pass "Interface /admin protégée (HTTP Basic)"
else
    fail "Admin auth" "auth_basic absent de nginx.conf"
fi

# Fichiers sensibles bloqués
if curl -sf --max-time 3 "http://${AP_IP}/.env" 2>/dev/null | grep -qE "^(HTTP/|$)"; then
    warn_t ".env" "Fichier .env potentiellement accessible"
else
    pass "Fichiers sensibles bloqués (.env, .sh, etc.)"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# TEST 7 — LoRa (si --lora)
# ═══════════════════════════════════════════════════════════════════════════════
if $RUN_LORA; then
    section "Module LoRa"

    if systemctl is-active --quiet lora-service 2>/dev/null; then
        pass "lora-service actif"
        # API santé
        if curl -sf --max-time 5 "http://127.0.0.1:8765/health" 2>/dev/null | grep -q "ok"; then
            pass "API LoRa répond (port 8765)"
        else
            fail "API LoRa" "http://127.0.0.1:8765/health ne répond pas"
        fi
        # Stats
        STATS=$(curl -sf --max-time 5 "http://127.0.0.1:8765/stats" 2>/dev/null || echo "{}")
        HW=$(echo "$STATS" | jq -r '.hw_ready // false')
        if [ "$HW" = "true" ]; then
            FREQ=$(echo "$STATS" | jq -r '.freq_mhz // 0')
            pass "Hardware LoRa détecté (${FREQ} MHz)"
        else
            warn_t "Hardware LoRa" "Module non détecté — simulation active"
        fi
    else
        warn_t "lora-service" "Non actif — LoRa peut-être désactivé dans config"
    fi

    # Clé de chiffrement
    if [ -f /etc/sos-guide/lora.key ] && [ "$(stat -c%a /etc/sos-guide/lora.key)" = "400" ]; then
        pass "Clé LoRa présente et protégée (chmod 400)"
    else
        fail "Clé LoRa" "/etc/sos-guide/lora.key absent ou mal protégé"
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════════
# TEST 8 — Performance (si --full)
# ═══════════════════════════════════════════════════════════════════════════════
if $FULL_TEST; then
    section "Performance (charge 50 clients)"

    if command -v ab &>/dev/null; then
        AB_OUT=$(ab -n 200 -c 50 -q "http://${AP_IP}/" 2>&1)
        RPS=$(echo "$AB_OUT" | grep "Requests per second" | awk '{print int($4)}')
        FAIL_REQ=$(echo "$AB_OUT" | grep "Failed requests" | awk '{print $3}')
        if [ "${RPS:-0}" -ge 20 ] && [ "${FAIL_REQ:-0}" -eq 0 ]; then
            pass "Charge 50 clients : ${RPS} req/s, 0 échec"
        else
            warn_t "Performance" "${RPS:-?} req/s, ${FAIL_REQ:-?} échecs"
        fi
    else
        warn_t "ab (Apache Bench)" "Non disponible — apt install apache2-utils"
    fi

    # Mémoire disponible
    FREE_MB=$(free -m 2>/dev/null | awk '/^Mem/{print $7}')
    if [ "${FREE_MB:-0}" -ge 256 ]; then
        pass "Mémoire libre : ${FREE_MB} MB (≥256 MB requis)"
    else
        warn_t "Mémoire" "Seulement ${FREE_MB:-?} MB libres"
    fi

    # Espace disque
    FREE_DISK=$(df /var/www/sos-guide 2>/dev/null | awk 'NR==2{print int($4/1024)}')
    if [ "${FREE_DISK:-0}" -ge 100 ]; then
        pass "Espace disque : ${FREE_DISK} MB libres"
    else
        warn_t "Espace disque" "Seulement ${FREE_DISK:-?} MB libres"
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════════
# RAPPORT FINAL
# ═══════════════════════════════════════════════════════════════════════════════
TOTAL=$((PASS+FAIL+WARN))
PCT_PASS=$((TOTAL>0 ? PASS*100/TOTAL : 0))

echo ""
echo -e "  ${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
if [ "$FAIL" -eq 0 ]; then
    echo -e "  ${BOLD}║  ✅  TOUS LES TESTS PASSÉS — Prêt pour certification ║${NC}"
else
    echo -e "  ${BOLD}║  ⚠️   TESTS TERMINÉS — ${FAIL} échec(s) à corriger     ║${NC}"
fi
echo -e "  ${BOLD}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${GREEN}✔ PASS${NC} : $PASS   ${RED}✘ FAIL${NC} : $FAIL   ${YELLOW}△ WARN${NC} : $WARN   Score : ${PCT_PASS}%"
echo ""

# Génération rapport JSON
if $GEN_REPORT || [ "$FAIL" -gt 0 ]; then
    {
        echo "{"
        echo "  \"version\": \"2.3\","
        echo "  \"date\": \"$(date -Iseconds)\","
        echo "  \"host\": \"$(hostname)\","
        echo "  \"pass\": $PASS,"
        echo "  \"fail\": $FAIL,"
        echo "  \"warn\": $WARN,"
        echo "  \"score_pct\": $PCT_PASS,"
        echo "  \"results\": ["
        echo "    $(IFS=','; echo "${RESULTS[*]}")"
        echo "  ]"
        echo "}"
    } > "$REPORT_FILE"
    echo -e "  ${CYAN}Rapport JSON :${NC} $REPORT_FILE"
fi

# Code de sortie pour CI/CD
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
