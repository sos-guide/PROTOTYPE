#!/bin/bash
# finalize_install.sh v2.5 — Thin wrapper → /usr/local/bin/sos-guide-install.sh
#
# Appelé par api_install.php (chemin image).
# Délègue tout à sos-guide-install.sh qui est la source de vérité unique.
set -euo pipefail

INSTALL_BIN="/usr/local/bin/sos-guide-install.sh"

# Si absent (première exécution image), le copier depuis le boot path
if [ ! -f "$INSTALL_BIN" ]; then
    for bp in "/boot/firmware/firstboot" "/boot/firstboot"; do
        if [ -f "${bp}/sos-guide-install.sh" ]; then
            cp "${bp}/sos-guide-install.sh" "$INSTALL_BIN"
            chmod 755 "$INSTALL_BIN"
            break
        fi
    done
fi

if [ ! -f "$INSTALL_BIN" ]; then
    echo "ERREUR: sos-guide-install.sh introuvable dans /usr/local/bin/ ni dans /boot/*/firstboot/" >&2
    exit 1
fi

exec "$INSTALL_BIN" "$@"
