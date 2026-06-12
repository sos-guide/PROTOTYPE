#!/bin/bash
# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  SOS-GUIDE — sos-guide-set-credentials.sh v2.5                                ║
# ║  Change un mot de passe : admin du portail (htpasswd) OU compte Linux du Pi.  ║
# ║                                                                              ║
# ║  Appelé par api_admin_action.php via sudo. Le mot de passe N'EST JAMAIS      ║
# ║  passé en argument (visible dans `ps`) : il est lu sur STDIN.                ║
# ║                                                                              ║
# ║  Usage : printf '%s\n' "$NEWPASS" | sudo sos-guide-set-credentials.sh <cible> ║
# ║          <cible> = admin | system                                            ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

HTPASSWD_FILE="/etc/nginx/.htpasswd"
TARGET="${1:-}"

# Lire le nouveau mot de passe depuis STDIN (première ligne, sans le \n final).
IFS= read -r NEWPASS || true

# ── Validations communes ──────────────────────────────────────────────────────
if [ -z "$NEWPASS" ]; then
    echo "ERREUR: mot de passe vide" >&2
    exit 2
fi
if [ "${#NEWPASS}" -lt 8 ]; then
    echo "ERREUR: mot de passe trop court (8 caractères minimum)" >&2
    exit 2
fi
if [ "${#NEWPASS}" -gt 128 ]; then
    echo "ERREUR: mot de passe trop long (128 caractères maximum)" >&2
    exit 2
fi

case "$TARGET" in
    admin)
        # Mot de passe de l'interface /admin (auth basic nginx, utilisateur "admin").
        if command -v htpasswd >/dev/null 2>&1; then
            htpasswd -b "$HTPASSWD_FILE" admin "$NEWPASS" >/dev/null 2>&1
        else
            HASHED=$(openssl passwd -apr1 "$NEWPASS")
            printf 'admin:%s\n' "$HASHED" > "$HTPASSWD_FILE"
        fi
        chmod 640 "$HTPASSWD_FILE"
        chown root:www-data "$HTPASSWD_FILE"
        echo "OK: mot de passe admin du portail mis à jour"
        ;;
    system)
        # Mot de passe du compte Linux principal (utilisateur de login, uid 1000).
        OSUSER=$(getent passwd 1000 | cut -d: -f1)
        if [ -z "$OSUSER" ]; then
            echo "ERREUR: aucun compte uid 1000 trouvé" >&2
            exit 3
        fi
        printf '%s:%s\n' "$OSUSER" "$NEWPASS" | chpasswd
        echo "OK: mot de passe du compte système '$OSUSER' mis à jour"
        ;;
    *)
        echo "ERREUR: cible inconnue '$TARGET' (attendu: admin | system)" >&2
        exit 1
        ;;
esac
