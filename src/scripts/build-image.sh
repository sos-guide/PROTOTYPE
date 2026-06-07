#!/bin/bash
# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  SOS-GUIDE — build-image.sh v2.4                                            ║
# ║  Pipeline de génération de l'image .img Raspberry Pi                        ║
# ║                                                                              ║
# ║  Prérequis : Docker · git · gpg · sha256sum                                 ║
# ║  Usage     : bash build-image.sh [--sign] [--rpi5] [--ch]                  ║
# ║  Sortie    : releases/sos-guide-v2.5-ch.img.gz + .sha256 + .asc            ║
# ║                                                                              ║
# ║  Conforme : Croix-Rouge Suisse · PCi-CH · nLPD RS 235.1                    ║
# ║                                                                              ║
# ║  CORRECTIONS v2.4 :                                                          ║
# ║  ✅ Suppression toute référence au PIN HDMI dans credentials.txt             ║
# ║  ✅ Note STARTER WiFi : mot de passe généré au 1er boot, lisible journalctl  ║
# ║  ✅ FIRST_USER_PASSWORD généré aléatoirement (build pi-gen)                  ║
# ║  ✅ sos-guide-health.time copié en .timer dans /etc/systemd/system/          ║
# ║  ✅ pyLoRa et flask ajoutés à pip (requis pour lora-service.py)              ║
# ║  ✅ SSH activé pour RPi4 et RPi5 (accès maintenance si WiFi échoue)          ║
# ║  ✅ Logs pi-gen conservés en cas d'échec                                     ║
# ║  ✅ build-docker.sh uniquement (pas de double docker build)                  ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

set -euo pipefail

# ── Configuration ──────────────────────────────────────────────────────────────
VERSION="2.5"
VARIANT="ch"
SIGN_GPG=false
TARGET_RPI="rpi4"
RELEASE_DIR="$(pwd)/releases"

for arg in "$@"; do
    case "$arg" in
        --sign) SIGN_GPG=true ;;
        --rpi5) TARGET_RPI="rpi5" ;;
        --ch)   VARIANT="ch" ;;
        --eu)   VARIANT="eu" ;;
        --help)
            echo "Usage: $0 [--sign] [--rpi5] [--ch|--eu]"
            echo "  --sign   Signer l'image avec GPG (clé SOS-GUIDE requise)"
            echo "  --rpi5   Cibler Raspberry Pi 5 (défaut: RPi 4)"
            echo "  --ch     Variante Suisse (défaut)"
            exit 0 ;;
    esac
done

IMAGE_NAME="sos-guide-v${VERSION}-${VARIANT}-${TARGET_RPI}"

# ── Couleurs ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}✔${NC}  $1"; }
warn() { echo -e "  ${YELLOW}⚠${NC}  $1"; }
err()  { echo -e "  ${RED}✘${NC}  $1" >&2; }
step() { echo -e "\n  ${BOLD}${CYAN}▶${NC}  ${BOLD}$1${NC}"; }

echo ""
echo -e "  ${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "  ${BOLD}║  SOS-GUIDE v${VERSION} — Build Image ${IMAGE_NAME}  ║${NC}"
echo -e "  ${BOLD}╚══════════════════════════════════════════════════════╝${NC}"
echo ""

# ── Vérification des prérequis ────────────────────────────────────────────────
step "Vérification des prérequis"
MISSING=()
for cmd in docker git sha256sum; do
    command -v "$cmd" &>/dev/null || MISSING+=("$cmd")
done
$SIGN_GPG && { command -v gpg &>/dev/null || MISSING+=("gpg"); }
if [ ${#MISSING[@]} -gt 0 ]; then
    err "Commandes manquantes : ${MISSING[*]}"
    echo "  Installation : sudo apt install ${MISSING[*]}"
    exit 1
fi
ok "Tous les outils disponibles"

# ── Clonage pi-gen ────────────────────────────────────────────────────────────
step "Initialisation pi-gen"
PIGEN_DIR="/tmp/pi-gen-sos-$$"
BUILD_LOG="${RELEASE_DIR}/build-$(date +%Y%m%d-%H%M%S).log"
mkdir -p "$RELEASE_DIR"

if [ ! -d "$PIGEN_DIR" ]; then
    git clone --depth=1 https://github.com/RPi-Distro/pi-gen.git "$PIGEN_DIR"
fi
ok "pi-gen cloné dans $PIGEN_DIR"

# ── Stage SOS-GUIDE ───────────────────────────────────────────────────────────
step "Création du stage SOS-GUIDE"

SOS_STAGE="${PIGEN_DIR}/stage-sos-guide"
mkdir -p "${SOS_STAGE}/00-sos-guide"/{files,rootfs/{boot/firmware/firstboot,etc/systemd/system,usr/local/bin,var/www/sos-guide/data,etc/sos-guide}}

# config.json initial (vide — complété au firstboot)
cat > "${SOS_STAGE}/00-sos-guide/rootfs/var/www/sos-guide/data/config.json" <<'JSONEOF'
{
  "establishment": {
    "name": "",
    "address": "",
    "lat": "",
    "lon": "",
    "type": "erp",
    "localCrisisNumber": "",
    "localRisk": "",
    "localSamuNumber": "",
    "localPoliceNumber": "",
    "localPompiersNumber": ""
  },
  "reassurance": {
    "message": ""
  },
  "wifiChannel": 11,
  "enableLoRa": false,
  "enableEthernet": false,
  "installed": false
}
JSONEOF

# Script de préinstallation
cat > "${SOS_STAGE}/00-sos-guide/00-run.sh" <<'RUNEOF'
#!/bin/bash
set -e

on_chroot apt-get update -qq
on_chroot apt-get install -y --no-install-recommends \
    hostapd dnsmasq nginx php8.2-fpm php8.2-cli \
    python3-pip python3-flask \
    iptables netfilter-persistent iptables-persistent \
    jq curl wget git \
    iw wireless-tools rfkill \
    watchdog \
    attr \
    bc \
    apache2-utils \
    2>/dev/null

# v2.5 : dépendances Python pour lora-service.py + sos_keypair_gen.py
on_chroot pip3 install --break-system-packages \
    cryptography meshtastic pyLoRa RPi.GPIO spidev pyserial flask pubsub 2>/dev/null || \
on_chroot pip3 install --break-system-packages cryptography pyserial flask 2>/dev/null || true

# Désactiver les services configurés par firstboot
on_chroot systemctl disable hostapd dnsmasq nginx 2>/dev/null || true

# Activer le service firstboot (s'exécute une seule fois au 1er démarrage)
on_chroot systemctl enable sos-guide-firstboot.service

# Activer le timer healthcheck
on_chroot systemctl enable sos-guide-health.timer

# Masquer NetworkManager si présent (évite les conflits WiFi)
on_chroot systemctl mask NetworkManager 2>/dev/null || true

# Désactiver IPv6 globalement (conformité nLPD)
cat >> /etc/sysctl.conf <<SYSEOF
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
SYSEOF

# Watchdog matériel
cat > /etc/watchdog.conf <<WDEOF
watchdog-device = /dev/watchdog
watchdog-timeout = 15
min-memory = 1
max-load-1 = 24
interval = 5
WDEOF
on_chroot systemctl enable watchdog 2>/dev/null || true

# Fichier VERSION dans l'image
echo "2.5" > "${SOS_STAGE}/00-sos-guide/rootfs/etc/sos-guide-version"
chmod 444 "${SOS_STAGE}/00-sos-guide/rootfs/etc/sos-guide-version"

RUNEOF
chmod +x "${SOS_STAGE}/00-sos-guide/00-run.sh"

# Skip stages inutiles
for s in stage3 stage4 stage5; do
    touch "${PIGEN_DIR}/${s}/SKIP" 2>/dev/null || true
done
touch "${PIGEN_DIR}/stage2/SKIP_IMAGES" 2>/dev/null || true

ok "Stage SOS-GUIDE créé"

# ── Copie des fichiers source ──────────────────────────────────────────────────
step "Copie des fichiers SOS-GUIDE"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC_ROOT="${REPO_ROOT}/src"

# firstboot — dans /boot/firmware/firstboot
for f in firstboot.sh finalize_install.sh starter.html api_install.php; do
    src="${SRC_ROOT}/firstboot/${f}"
    if [ -f "$src" ]; then
        cp "$src" "${SOS_STAGE}/00-sos-guide/rootfs/boot/firmware/firstboot/${f}"
        ok "Copié : firstboot/$f"
    else
        warn "Manquant : firstboot/$f"
    fi
done

# Scripts système
for f in sos-guide-boot-check.sh sos-guide-regen-hash.sh sos-guide-fetch-tiles.sh lora-service.py sos-guide-update.sh sos_keypair_gen.py; do
    src="${SRC_ROOT}/scripts/${f}"
    [ -f "$src" ] || src="${SRC_ROOT}/${f}"
    if [ -f "$src" ]; then
        cp "$src" "${SOS_STAGE}/00-sos-guide/rootfs/usr/local/bin/${f}"
        chmod +x "${SOS_STAGE}/00-sos-guide/rootfs/usr/local/bin/${f}"
        ok "Copié : scripts/$f"
    else
        warn "Manquant : $f (optionnel)"
    fi
done

# Systemd units depuis systemd/
for f in sos-guide-firstboot.service lora-service.service \
         sos-guide-update.timer sos-guide-update.service; do
    src="${SRC_ROOT}/systemd/${f}"
    if [ -f "$src" ]; then
        cp "$src" "${SOS_STAGE}/00-sos-guide/rootfs/etc/systemd/system/${f}"
        ok "Copié : systemd/$f"
    else
        warn "Manquant (systemd) : $f"
    fi
done

# health.service et health.timer depuis firstboot/
for src_f in sos-guide-health.service sos-guide-health.timer; do
    src="${SRC_ROOT}/firstboot/${src_f}"
    if [ -f "$src" ]; then
        cp "$src" "${SOS_STAGE}/00-sos-guide/rootfs/etc/systemd/system/${src_f}"
        ok "Copié : firstboot/${src_f}"
    else
        warn "Manquant (firstboot) : ${src_f}"
    fi
done

# Web
if [ -d "${SRC_ROOT}/web" ]; then
    cp -r "${SRC_ROOT}/web/." "${SOS_STAGE}/00-sos-guide/rootfs/var/www/sos-guide/"
    ok "Web assets copiés"
fi

# ── config.txt pi-gen ─────────────────────────────────────────────────────────
step "Configuration pi-gen"

# Génération mot de passe pi aléatoire (SSH de secours)
FIRST_USER_PASS=$(openssl rand -base64 18 | tr -dc 'a-zA-Z0-9' | head -c 18)

cat > "${PIGEN_DIR}/config" <<PICONF
IMG_NAME="${IMAGE_NAME}"
RELEASE=bookworm
DEPLOY_COMPRESSION=gz
COMPRESSION_LEVEL=6
LOCALE_DEFAULT=fr_CH.UTF-8
TARGET_HOSTNAME=sos-guide
KEYBOARD_LAYOUT=fr
TIMEZONE_DEFAULT=Europe/Zurich
FIRST_USER_NAME=pi
FIRST_USER_PASSWORD=${FIRST_USER_PASS}
DISABLE_FIRST_BOOT_USER_RENAME=1
ENABLE_SSH=1
STAGE_LIST="stage0 stage1 stage2 ${SOS_STAGE}"
PICONF

# ── v2.4 : credentials.txt — sans PIN, avec note STARTER WiFi ─────────────────
# Le PIN HDMI est supprimé. Le mot de passe WPA2 STARTER est généré
# dynamiquement au 1er démarrage par firstboot.sh.
{
    echo "# SOS-GUIDE v${VERSION} — Credentials"
    echo "# ⚠️  CONFIDENTIEL — Ne pas partager"
    echo ""
    echo "IMAGE=${IMAGE_NAME}"
    echo "DATE=$(date -Iseconds)"
    echo ""
    echo "# ── Accès SSH de secours (si WiFi ne démarre pas) ──────────────────"
    echo "SSH_USER=pi"
    echo "SSH_PASSWORD=${FIRST_USER_PASS}"
    echo "SSH_NOTE=Changer ce mot de passe immédiatement après la première connexion"
    echo ""
    echo "# ── Accès WiFi STARTER (premier démarrage) ─────────────────────────"
    echo "# v2.4 : Le mot de passe WPA2 STARTER est généré ALÉATOIREMENT"
    echo "# au premier démarrage du Pi par firstboot.sh."
    echo "# Il est différent à chaque démarrage STARTER."
    echo "#"
    echo "# Pour le lire APRÈS le premier boot :"
    echo "#   Via SSH ETH : journalctl -u sos-guide-firstboot | grep WPA2"
    echo "#   Via fichier  : sudo cat /run/sos-guide/starter_wifi_password"
    echo "#"
    echo "# Le QR code de connexion WiFi est affiché sur http://10.0.0.1/"
    echo "# dès que vous êtes connecté au réseau STARTER."
    echo "STARTER_SSID=⛑️ SOS-GUIDE - STARTER"
    echo "STARTER_WIFI_NOTE=Mot de passe généré au boot — voir journalctl ou QR code"
    echo ""
    echo "# ── Accès administration (après configuration) ──────────────────────"
    echo "ADMIN_URL=http://10.0.0.1/admin"
    echo "ADMIN_USER=admin"
    echo "ADMIN_PASSWORD_NOTE=Généré à l'installation — voir /var/lib/sos-guide/installed"
} > "${RELEASE_DIR}/${IMAGE_NAME}-credentials.txt"
chmod 600 "${RELEASE_DIR}/${IMAGE_NAME}-credentials.txt"
ok "credentials.txt généré (sans PIN, avec note STARTER WiFi)"

# Adaptation RPi5
if [ "$TARGET_RPI" = "rpi5" ]; then
    cat >> "${SOS_STAGE}/00-sos-guide/00-run.sh" <<'RPi5EOF'

# Configuration RPi5 : activer SPI et UART pour LoRa
on_chroot raspi-config nonint do_spi 0      2>/dev/null || true
on_chroot raspi-config nonint do_serial_hw 0 2>/dev/null || true
RPi5EOF
fi

ok "pi-gen configuré pour ${TARGET_RPI} · Locale CH · Timezone Zürich · SSH activé"

# ── Build Docker ──────────────────────────────────────────────────────────────
step "Build de l'image (Docker pi-gen) — peut prendre 30-60 minutes"

cd "$PIGEN_DIR"

./build-docker.sh 2>&1 | tee "$BUILD_LOG" \
    | grep -E "(INFO|ERROR|WARN|✔|✘|stage)" || true
BUILD_EXIT="${PIPESTATUS[0]}"

if [ "$BUILD_EXIT" -ne 0 ]; then
    err "Build pi-gen échoué (code $BUILD_EXIT)"
    err "Log complet : $BUILD_LOG"
    # Ne pas supprimer PIGEN_DIR en cas d'échec → permet le debug
    exit 1
fi

# ── Récupération et signature ─────────────────────────────────────────────────
step "Finalisation de l'image"

IMG_SRC=$(find "${PIGEN_DIR}/deploy" -name "${IMAGE_NAME}*.img.gz" 2>/dev/null | head -1)
if [ -z "$IMG_SRC" ]; then
    err "Image .img.gz introuvable dans ${PIGEN_DIR}/deploy/"
    ls "${PIGEN_DIR}/deploy/" 2>/dev/null || true
    exit 1
fi

IMG_DEST="${RELEASE_DIR}/${IMAGE_NAME}.img.gz"
cp "$IMG_SRC" "$IMG_DEST"
ok "Image copiée : $IMG_DEST"

# SHA256
sha256sum "$IMG_DEST" | tee "${IMG_DEST%.img.gz}.sha256"
ok "SHA256 calculé"

# Hash PRIVACY.md (nLPD §9)
if [ -f "${REPO_ROOT}/PRIVACY.md" ]; then
    PRIV_HASH=$(sha256sum "${REPO_ROOT}/PRIVACY.md" | awk '{print $1}')
    sed -i "s/à calculer lors du build/${PRIV_HASH}/" \
        "${REPO_ROOT}/PRIVACY.md" 2>/dev/null || true
    ok "Hash PRIVACY.md mis à jour"
fi

# Signature GPG (optionnelle — exigée pour PCi-CH)
if $SIGN_GPG; then
    if gpg --list-secret-keys "sos-guide@sos-guide.fr" &>/dev/null; then
        gpg --armor --detach-sign \
            --local-user "sos-guide@sos-guide.fr" \
            --output "${IMG_DEST%.img.gz}.asc" \
            "$IMG_DEST"
        ok "Image signée GPG"
    else
        warn "Clé GPG sos-guide@sos-guide.fr absente — signature ignorée"
    fi
fi

# ── Résumé ────────────────────────────────────────────────────────────────────
echo ""
echo -e "  ${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "  ${BOLD}║  ✅  SOS-GUIDE v${VERSION} — Image générée avec succès  ║${NC}"
echo -e "  ${BOLD}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${CYAN}Image      :${NC} ${IMG_DEST}"
echo -e "  ${CYAN}SHA256     :${NC} ${IMG_DEST%.img.gz}.sha256"
echo -e "  ${CYAN}Credentials:${NC} ${RELEASE_DIR}/${IMAGE_NAME}-credentials.txt  ⚠️  CONFIDENTIEL"
$SIGN_GPG && echo -e "  ${CYAN}GPG sig    :${NC} ${IMG_DEST%.img.gz}.asc"
echo ""
echo -e "  ${YELLOW}Pour flasher :${NC}"
echo -e "  Raspberry Pi Imager → «Image personnalisée» → ${IMAGE_NAME}.img.gz"
echo -e "  CLI : rpi-imager --cli ${IMAGE_NAME}.img.gz /dev/sdX"
echo ""
echo -e "  ${YELLOW}Premier démarrage — 100%% WiFi, sans écran HDMI :${NC}"
echo -e "  1. Connectez-vous au WiFi : ${BOLD}⛑️ SOS-GUIDE - STARTER${NC}"
echo -e "     Mot de passe : lisible via QR code sur http://10.0.0.1/"
echo -e "     ou : journalctl -u sos-guide-firstboot | grep WPA2"
echo -e "  2. Ouvrez : ${BOLD}http://10.0.0.1/${NC}"
echo -e "  3. Suivez l'assistant de configuration (nom du lieu, contacts, LoRa)"
echo -e "  4. Validez → bascule en PRODUCTION sans reboot (~30s)"
echo ""
echo -e "  ${YELLOW}Accès SSH de secours (si WiFi ne démarre pas) :${NC}"
echo -e "  ssh pi@<IP-ETH>  — mot de passe dans ${IMAGE_NAME}-credentials.txt"
echo ""

# Nettoyage (uniquement si build réussi)
rm -rf "$PIGEN_DIR"
ok "Répertoire temporaire nettoyé"

exit 0

