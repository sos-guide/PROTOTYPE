#!/bin/bash
# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  SOS-GUIDE — Mise à jour automatique du contenu JSON                       ║
# ║  Source : https://sos-guide.fr/prod/                                       ║
# ║  Auteur : Ludovic MARTIN — contact@sos-guide.fr                            ║
# ║                                                                             ║
# ║  CORRECTIONS v2.3 :                                                        ║
# ║  ✅ set -euo pipefail (était set -e — variables non déclarées ignorées)    ║
# ║  ✅ chattr +i : data/ exclu après mise à jour                              ║
# ║     (chattr -R +i WEB_DIR verrouillait config.json → admin bloqué)        ║
# ║  ✅ Rollback : re-verrouillage correct avant sortie en erreur              ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
#
# LOGIQUE :
#   1. Vérifie si internet est disponible via ETH (modem/téléphone)
#   2. Lit latest-version.txt sur le serveur
#   3. Compare avec la version locale installée
#   4. Si plus récente : télécharge l'archive + vérifie SHA256
#   5. Extrait uniquement les fichiers JSON dans /var/www/sos-guide/data/
#   6. Régénère le hash d'intégrité
#   7. Log le résultat
#
# SÉCURITÉ :
#   - Fonctionne UNIQUEMENT si ETH a internet (jamais depuis wlan0)
#   - Vérification SHA256 obligatoire avant toute installation
#   - Rollback automatique si l'extraction échoue
#   - config.json préservé (non écrasé, non verrouillé)
#
# USAGE :
#   Manuel : sudo bash /usr/local/bin/sos-guide-update.sh
#   Auto   : déclenché par le timer systemd (si ETH connecté)

# FIX v2.3 : set -euo pipefail — détecte variables non définies et erreurs pipes
set -euo pipefail

# ── Couleurs ─────────────────────────────────────────────────────────────────
RED='\033[0;31m';  GREEN='\033[0;32m';  YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m';  MAGENTA='\033[0;35m'
BOLD='\033[1m';    DIM='\033[2m';      NC='\033[0m'

ok()   { echo -e "  ${GREEN}✔${NC}  $1"; }
warn() { echo -e "  ${YELLOW}⚠${NC}  $1"; }
err()  { echo -e "  ${RED}✘${NC}  $1"; }
info() { echo -e "  ${CYAN}ℹ${NC}  $1"; }
step() { echo -e "  ${BLUE}→${NC}  $1"; }

# ── Configuration ─────────────────────────────────────────────────────────────
UPDATE_URL="https://sos-guide.fr/prod"
VERSION_FILE="${UPDATE_URL}/latest-version.txt"
WEB_DIR="/var/www/sos-guide"
DATA_DIR="${WEB_DIR}/data"
VERSION_LOCAL="/root/sos-guide-content-version.txt"
INTEGRITY_HASH="/root/integrity.hash"
TMP_DIR="/tmp/sos-update-$$"
LOG_FILE="/var/log/sos-guide-update.log"
CONNECT_TIMEOUT=10
MAX_TIME=120
MODE="${1:-manual}"   # manual | auto | check

# ── Fonctions utilitaires ─────────────────────────────────────────────────────

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "${LOG_FILE}" 2>/dev/null || true
}

cleanup() {
    rm -rf "${TMP_DIR}" 2>/dev/null || true
}
trap cleanup EXIT

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        err "Root requis : sudo bash $0"
        exit 1
    fi
}

# ── FIX v2.3 : Verrouillage ciblé — data/ toujours exclu ────────────────────
# Ancien code : chattr -R +i "${WEB_DIR}/"  ← verrouillait config.json
# Nouveau : verrouille uniquement les fichiers hors data/
lock_web_files() {
    if command -v chattr &>/dev/null; then
        # Verrouiller tout sauf data/
        find "${WEB_DIR}" -type f ! -path "${DATA_DIR}/*" \
            -exec chattr +i {} \; 2>/dev/null || true
        # data/ doit rester accessible en écriture pour l'admin
        chattr -R -i "${DATA_DIR}/" 2>/dev/null || true
        chmod 755 "${DATA_DIR}/"
        chown www-data:www-data "${DATA_DIR}/"
        ok "Verrouillage chattr +i appliqué (data/ exclu)"
    fi
    chmod -R a-w "${WEB_DIR}/"
    # Rendre data/ à nouveau accessible en écriture pour www-data
    chmod u+w "${DATA_DIR}/"
    find "${DATA_DIR}" -name "*.json" -exec chmod 644 {} \; 2>/dev/null || true
}

unlock_web_files() {
    if command -v chattr &>/dev/null; then
        find "${WEB_DIR}" -type f ! -path "${DATA_DIR}/*" \
            -exec chattr -i {} \; 2>/dev/null || true
    fi
    chmod -R u+w "${WEB_DIR}/"
}

# ── Vérifier la connectivité internet via ETH ─────────────────────────────────
check_internet() {
    step "Vérification connectivité internet (ETH)..."

    local eth_iface
    eth_iface=$(ip -o link show | awk -F': ' '/^[0-9]+: (en|eth)/{print $2; exit}' || true)
    if [ -z "${eth_iface}" ]; then
        warn "Aucune interface Ethernet détectée"
        return 1
    fi

    if ! ip -4 addr show "${eth_iface}" | grep -q "inet "; then
        warn "Interface ${eth_iface} sans adresse IP"
        return 1
    fi

    if curl -sf \
        --connect-timeout "${CONNECT_TIMEOUT}" \
        --max-time 15 \
        --interface "${eth_iface}" \
        -o /dev/null \
        "https://sos-guide.fr/prod/latest-version.txt" 2>/dev/null; then
        ok "Connexion internet disponible via ${eth_iface}"
        ETH_IFACE="${eth_iface}"
        return 0
    fi

    if ping -c1 -W3 -I "${eth_iface}" 1.1.1.1 &>/dev/null 2>&1; then
        ok "Internet disponible (ping) via ${eth_iface}"
        ETH_IFACE="${eth_iface}"
        return 0
    fi

    warn "Pas de connexion internet — mise à jour ignorée"
    log "SKIP: Pas de connexion internet"
    return 1
}

# ── Lire la version distante ──────────────────────────────────────────────────
fetch_remote_version() {
    REMOTE_VERSION=$(curl -sf \
        --connect-timeout "${CONNECT_TIMEOUT}" \
        --max-time 15 \
        "${VERSION_FILE}" 2>/dev/null | tr -d '[:space:]')

    if [ -z "${REMOTE_VERSION}" ]; then
        warn "Impossible de lire latest-version.txt"
        log "ERROR: Impossible de lire latest-version.txt"
        return 1
    fi
    ok "Version distante : ${BOLD}${REMOTE_VERSION}${NC}"
    return 0
}

# ── Lire la version locale ────────────────────────────────────────────────────
get_local_version() {
    if [ -f "${VERSION_LOCAL}" ]; then
        LOCAL_VERSION=$(tr -d '[:space:]' < "${VERSION_LOCAL}")
        info "Version locale  : ${LOCAL_VERSION}"
    else
        LOCAL_VERSION="none"
        info "Version locale  : aucune (première installation)"
    fi
}

# ── Télécharger et vérifier l'archive ─────────────────────────────────────────
download_and_verify() {
    local VERSION="$1"
    local ARCHIVE_NAME="sos-guide-content-${VERSION}.tar.gz"
    local CHECKSUM_NAME="sos-guide-content-${VERSION}.sha256"
    local ARCHIVE_URL="${UPDATE_URL}/${ARCHIVE_NAME}"
    local CHECKSUM_URL="${UPDATE_URL}/${CHECKSUM_NAME}"

    mkdir -p "${TMP_DIR}"

    step "Téléchargement du checksum SHA256..."
    if ! curl -sf \
        --connect-timeout "${CONNECT_TIMEOUT}" \
        --max-time 30 \
        -o "${TMP_DIR}/${CHECKSUM_NAME}" \
        "${CHECKSUM_URL}"; then
        err "Impossible de télécharger le checksum"
        log "ERROR: Échec téléchargement checksum ${CHECKSUM_URL}"
        return 1
    fi
    ok "Checksum téléchargé"

    step "Téléchargement de l'archive ${ARCHIVE_NAME}..."
    if ! curl -f \
        --connect-timeout "${CONNECT_TIMEOUT}" \
        --max-time "${MAX_TIME}" \
        --progress-bar \
        -o "${TMP_DIR}/${ARCHIVE_NAME}" \
        "${ARCHIVE_URL}" 2>&1; then
        err "Impossible de télécharger l'archive"
        log "ERROR: Échec téléchargement ${ARCHIVE_URL}"
        return 1
    fi
    echo ""
    ok "Archive téléchargée"

    step "Vérification SHA256..."
    local EXPECTED_HASH ACTUAL_HASH
    EXPECTED_HASH=$(awk '{print $1}' "${TMP_DIR}/${CHECKSUM_NAME}")
    ACTUAL_HASH=$(sha256sum "${TMP_DIR}/${ARCHIVE_NAME}" | awk '{print $1}')

    if [ "${EXPECTED_HASH}" != "${ACTUAL_HASH}" ]; then
        err "SHA256 invalide ! Archive corrompue ou attaque."
        err "  Attendu : ${EXPECTED_HASH}"
        err "  Obtenu  : ${ACTUAL_HASH}"
        log "SECURITY: SHA256 invalide pour ${ARCHIVE_NAME}"
        return 1
    fi
    ok "SHA256 vérifié ✓"

    ARCHIVE_PATH="${TMP_DIR}/${ARCHIVE_NAME}"
    return 0
}

# ── Vérifier le contenu de l'archive avant extraction ─────────────────────────
verify_archive_content() {
    local ARCHIVE="$1"
    step "Vérification du contenu de l'archive..."

    local BAD_FILES
    BAD_FILES=$(tar -tzf "${ARCHIVE}" 2>/dev/null \
        | grep -v '\.json$' \
        | grep -v '/$' \
        || true)

    if [ -n "${BAD_FILES}" ]; then
        warn "Fichiers non-JSON détectés dans l'archive :"
        echo "${BAD_FILES}" | head -5 | while read -r f; do warn "  ${f}"; done
        err "Archive rejetée : seuls les fichiers .json sont autorisés"
        log "SECURITY: Archive contient des fichiers non-JSON"
        return 1
    fi

    local FILE_COUNT
    FILE_COUNT=$(tar -tzf "${ARCHIVE}" 2>/dev/null | grep -c '\.json$' || true)
    ok "Archive valide : ${FILE_COUNT} fichier(s) JSON"
    return 0
}

# ── Installer le contenu ───────────────────────────────────────────────────────
install_content() {
    local ARCHIVE="$1"
    local VERSION="$2"

    # Sauvegarde de la version actuelle (hors config.json)
    if [ -d "${DATA_DIR}" ]; then
        step "Sauvegarde de la version actuelle..."
        # config.json exclu de la sauvegarde des langues (géré séparément)
        mkdir -p "${TMP_DIR}/data_backup"
        find "${DATA_DIR}" -name "*.json" ! -name "config.json" \
            -exec cp {} "${TMP_DIR}/data_backup/" \; 2>/dev/null || true
        ok "Sauvegarde créée dans ${TMP_DIR}/data_backup"
    fi

    # Déverrouillage ciblé (uniquement data/, pas les fichiers PHP/HTML)
    step "Déverrouillage du répertoire data/..."
    if command -v chattr &>/dev/null; then
        chattr -R -i "${DATA_DIR}/" 2>/dev/null || true
    fi
    chmod -R u+w "${DATA_DIR}/" 2>/dev/null || true

    # Extraction dans dossier temporaire
    step "Extraction de l'archive..."
    mkdir -p "${TMP_DIR}/extract"
    if ! tar -xzf "${ARCHIVE}" -C "${TMP_DIR}/extract" 2>/dev/null; then
        err "Échec extraction — rollback..."
        if [ -d "${TMP_DIR}/data_backup" ]; then
            cp "${TMP_DIR}/data_backup/"*.json "${DATA_DIR}/" 2>/dev/null || true
            warn "Rollback effectué — ancienne version restaurée"
        fi
        # FIX v2.3 : re-verrouillage correct avant sortie en erreur
        lock_web_files
        return 1
    fi
    ok "Extraction réussie"

    # Copie des JSON — config.json jamais écrasé
    step "Installation des fichiers JSON (config.json préservé)..."
    if [ -d "${TMP_DIR}/extract/data" ]; then
        find "${TMP_DIR}/extract/data" -name "*.json" ! -name "config.json" \
            -exec cp {} "${DATA_DIR}/" \;
    elif [ -d "${TMP_DIR}/extract/fr" ]; then
        find "${TMP_DIR}/extract" -name "*.json" ! -name "config.json" \
            -exec cp {} "${DATA_DIR}/" \;
    else
        find "${TMP_DIR}/extract" -name "*.json" ! -name "config.json" \
            -exec cp {} "${DATA_DIR}/" \;
    fi

    chown -R www-data:www-data "${DATA_DIR}"
    find "${DATA_DIR}" -name "*.json" -exec chmod 644 {} \;
    ok "Fichiers JSON installés dans ${DATA_DIR} (config.json intact)"

    # Sauvegarder la nouvelle version
    echo "${VERSION}" > "${VERSION_LOCAL}"
    ok "Version locale mise à jour : ${VERSION}"

    # FIX v2.3 : Reverrouillage ciblé (data/ exclu)
    step "Reverrouillage (data/ exclu)..."
    lock_web_files

    # Régénération du hash d'intégrité via le script dédié
    step "Régénération du hash SHA256 d'intégrité..."
    if /usr/local/bin/sos-guide-regen-hash.sh 2>/dev/null; then
        ok "Hash d'intégrité régénéré"
    else
        # Fallback manuel si le script n'est pas disponible
        find "${WEB_DIR}" -type f -exec sha256sum {} \; > "${INTEGRITY_HASH}" 2>/dev/null
        sha256sum /etc/nginx/sites-available/sos-guide \
            >> "${INTEGRITY_HASH}" 2>/dev/null || true
        ok "Hash d'intégrité régénéré (fallback)"
    fi

    return 0
}

# ══════════════════════════════════════════════════════════════════════════════
# PROGRAMME PRINCIPAL
# ══════════════════════════════════════════════════════════════════════════════

check_root

# Déclarer les variables globales utilisées dans les fonctions
REMOTE_VERSION=""
LOCAL_VERSION="none"
ARCHIVE_PATH=""
ETH_IFACE=""

# Mode "check only"
if [ "${MODE}" = "check" ]; then
    check_internet || exit 0
    fetch_remote_version || exit 0
    get_local_version
    if [ "${REMOTE_VERSION}" != "${LOCAL_VERSION}" ]; then
        echo -e "${YELLOW}Mise à jour disponible : ${LOCAL_VERSION} → ${REMOTE_VERSION}${NC}"
        echo -e "${CYAN}Lancer : sudo bash /usr/local/bin/sos-guide-update.sh${NC}"
        exit 2
    else
        echo -e "${GREEN}Contenu à jour : ${LOCAL_VERSION}${NC}"
        exit 0
    fi
fi

# Mode "auto" — log complet
if [ "${MODE}" = "auto" ]; then
    exec >> "${LOG_FILE}" 2>&1
    echo ""
    echo "═══════════════════════════════════════════════"
    echo "  SOS-GUIDE Update — $(date '+%Y-%m-%d %H:%M:%S')"
    echo "═══════════════════════════════════════════════"
fi

echo ""
echo -e "${BOLD}${CYAN}  ⛑️  SOS-GUIDE — Mise à jour du contenu${NC}"
echo -e "${DIM}  Source : ${UPDATE_URL}${NC}"
echo ""

check_internet || exit 0
fetch_remote_version || exit 1
get_local_version

if [ "${REMOTE_VERSION}" = "${LOCAL_VERSION}" ]; then
    ok "Contenu déjà à jour (${LOCAL_VERSION})"
    log "OK: Contenu à jour ${LOCAL_VERSION}"
    echo ""
    exit 0
fi

echo ""
echo -e "  ${BOLD}${MAGENTA}Mise à jour disponible :${NC}"
echo -e "  ${DIM}${LOCAL_VERSION}${NC} → ${BOLD}${GREEN}${REMOTE_VERSION}${NC}"
echo ""

if [ "${MODE}" = "manual" ]; then
    read -rp "  Installer la mise à jour ? (o/N) : " CONFIRM
    if [ "${CONFIRM}" != "o" ] && [ "${CONFIRM}" != "O" ]; then
        info "Mise à jour annulée"
        exit 0
    fi
fi

echo ""

download_and_verify "${REMOTE_VERSION}" || exit 1
verify_archive_content "${ARCHIVE_PATH}" || exit 1
install_content "${ARCHIVE_PATH}" "${REMOTE_VERSION}" || exit 1

echo ""
echo -e "  ${GREEN}${BOLD}✔  Mise à jour ${REMOTE_VERSION} installée avec succès !${NC}"
log "SUCCESS: Mise à jour ${LOCAL_VERSION} → ${REMOTE_VERSION}"

if [ "${MODE}" = "auto" ]; then
    logger "SOS-GUIDE: Contenu mis à jour ${LOCAL_VERSION} → ${REMOTE_VERSION}"
fi

echo ""
exit 0
