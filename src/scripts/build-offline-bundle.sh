#!/bin/bash
# SOS-GUIDE — Génération du bundle de dépendances offline
#
# À exécuter sur un Raspberry Pi Debian arm64 AVEC accès internet.
# Télécharge tous les paquets .deb requis par install.sh (+ dépendances
# transitives) et crée offline-deps-<arch>-debian<ver>.tar.gz à la racine du
# projet. Ce bundle permet de lancer install.sh sans réseau.
#
# Usage : sudo bash src/scripts/build-offline-bundle.sh

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}✔${NC}  $1"; }
warn() { echo -e "  ${YELLOW}⚠${NC}  $1"; }
err()  { echo -e "  ${RED}✘${NC}  $1" >&2; }
info() { echo -e "  ${CYAN}ℹ${NC}  $1"; }
step() { echo -e "\n  ${BOLD}▶${NC}  ${BOLD}$1${NC}"; }

[ "$(id -u)" -eq 0 ] || { err "Root requis"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Remonte vers la racine du projet (src/scripts/ → ../..)
if [ -f "${SCRIPT_DIR}/../../install.sh" ]; then
    REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
else
    REPO_DIR="${PWD}"  # Fallback : répertoire courant si le script est copié ailleurs
fi
ARCH=$(dpkg --print-architecture)
DEBIAN_VER=$(. /etc/os-release && echo "${VERSION_ID:-unknown}")
BUNDLE_NAME="offline-deps-${ARCH}-debian${DEBIAN_VER}.tar.gz"
BUNDLE_PATH="${REPO_DIR}/${BUNDLE_NAME}"

echo ""
echo "════════════════════════════════════════════════════"
echo "  SOS-GUIDE — Build offline bundle"
echo "  Arch    : ${ARCH}"
echo "  Debian  : ${DEBIAN_VER}"
echo "  Sortie  : ${BUNDLE_NAME}"
echo "════════════════════════════════════════════════════"

# ── Liste des paquets cibles ──────────────────────────────────────────────────
TARGET_PKGS=(
    nginx
    hostapd
    dnsmasq
    netfilter-persistent
    iptables-persistent
    jq
    watchdog
    apache2-utils
)

# PHP-FPM : utilise la version déjà installée, sinon 8.4
PHP_PKG=$(dpkg -l 'php*-fpm' 2>/dev/null | awk '/^ii/{print $2; exit}')
[ -z "$PHP_PKG" ] && PHP_PKG="php8.4-fpm"
TARGET_PKGS+=("$PHP_PKG")

step "Mise à jour des listes apt"
apt-get update -qq
ok "Listes à jour"

step "Résolution des dépendances transitives"
info "Paquets cibles : ${TARGET_PKGS[*]}"

# Récupère récursivement tous les paquets requis (sans recommandations)
ALL_PKGS=$(apt-cache depends --recurse \
    --no-recommends --no-suggests \
    --no-conflicts  --no-breaks \
    --no-replaces   --no-enhances \
    "${TARGET_PKGS[@]}" 2>/dev/null \
    | awk '/^[a-zA-Z0-9]/{print $1} /Depends:/{print $NF}' \
    | grep -v '^<' | sort -u)

# Ajoute les paquets cibles eux-mêmes (apt-cache depends ne les répète pas)
ALL_PKGS=$(printf "%s\n" "${TARGET_PKGS[@]}" $ALL_PKGS | sort -u)

PKG_COUNT=$(echo "$ALL_PKGS" | wc -w)
ok "${PKG_COUNT} paquets à télécharger (cibles + dépendances)"

step "Téléchargement des paquets"
DEBS_TMP=$(mktemp -d)
trap 'rm -rf "$DEBS_TMP"' EXIT

mkdir -p "${DEBS_TMP}/debs"
cd "${DEBS_TMP}/debs"

DOWNLOADED=0
SKIPPED=0
for pkg in $ALL_PKGS; do
    if apt-get download "$pkg" 2>/dev/null; then
        DOWNLOADED=$((DOWNLOADED + 1))
    else
        SKIPPED=$((SKIPPED + 1))
    fi
done

DEB_COUNT=$(ls "${DEBS_TMP}/debs/"*.deb 2>/dev/null | wc -l)
if [ "$DEB_COUNT" -eq 0 ]; then
    err "Aucun paquet téléchargé — vérifier la connexion internet"
    exit 1
fi
ok "${DEB_COUNT} fichiers .deb téléchargés (${SKIPPED} ignorés — déjà à jour)"

step "Création du bundle"
cd "$REPO_DIR"
tar -czf "$BUNDLE_PATH" -C "$DEBS_TMP" debs/

BUNDLE_SIZE=$(du -sh "$BUNDLE_PATH" | cut -f1)
ok "Bundle : ${BUNDLE_PATH}"
ok "Taille : ${BUNDLE_SIZE}"

echo ""
echo -e "  ${CYAN}Utilisation :${NC}"
echo -e "  ${CYAN}  1. Copier ${BUNDLE_NAME} à la racine du projet${NC}"
echo -e "  ${CYAN}  2. sudo bash install.sh   (sans internet)${NC}"
echo ""
