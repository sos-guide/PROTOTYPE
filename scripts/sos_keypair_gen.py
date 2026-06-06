#!/usr/bin/env python3
"""
╔══════════════════════════════════════════════════════════════════════════════╗
║  SOS-GUIDE — sos_keypair_gen.py                                            ║
║  Générateur de paire de clés Ed25519 — identité cryptographique du nœud   ║
║                                                                              ║
║  Appelé UNE SEULE FOIS par firstboot.sh au premier démarrage               ║
║  Idempotent : ne régénère pas si les clés existent déjà                    ║
║                                                                              ║
║  Version : 2.5 — Juin 2026                                                 ║
║  Auteur  : Ludovic MARTIN — contact@sos-guide.fr                           ║
║  Licence : EUPL-1.2                                                        ║
╚══════════════════════════════════════════════════════════════════════════════╝

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  ANALOGIE POUR COMPRENDRE CE QUE FAIT CE SCRIPT
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Imagine un tampon officiel de mairie :

  • Clé PRIVÉE = le tampon lui-même
    → Reste dans le tiroir fermé à clé (sur le Pi, protégé root)
    → Sert à "tamponner" (signer) les alertes que tu envoies
    → Si quelqu'un vole ce fichier, il peut usurper ton nœud !

  • Clé PUBLIQUE = le scan du tampon partagé avec toutes les mairies
    → Peut être donnée à n'importe qui
    → Sert à VÉRIFIER qu'une alerte a bien été tamponnée par TON Pi
    → Sans la clé privée, impossible de falsifier une nouvelle alerte

  • Signature = l'empreinte du tampon sur une alerte spécifique
    → Unique pour chaque alerte (contient le timestamp)
    → Impossible à réutiliser ou à copier sur une autre alerte

  Algorithme utilisé : Ed25519 (Edwards-curve Digital Signature Algorithm)
  → Standard moderne, rapide, sûr, utilisé par le gouvernement français (RGS)
  → 64 octets de signature, vérification en microseconde sur Raspberry Pi

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Fichiers créés par ce script :
  /etc/sos-guide/node_private_key.pem   ← PRIVÉ (root uniquement, chmod 400)
  /etc/sos-guide/node_public_key.pem    ← PUBLIC (lisible par lora-service)
  /etc/sos-guide/node_fingerprint.txt   ← Empreinte courte (affichée sur portail)
  /etc/sos-guide/trusted_nodes.json     ← Liste des nœuds de confiance du réseau

Usage :
  sudo python3 sos_keypair_gen.py [--force] [--node-id NOM]
  --force    : régénère même si les clés existent déjà (⚠ à utiliser avec soin)
  --node-id  : identifiant du nœud (ex: ecole-jean-jaures-paris-75011)

Dépendances :
  pip3 install --break-system-packages cryptography
"""

import argparse
import hashlib
import json
import os
import re
import stat
import sys
from datetime import datetime, timezone
from pathlib import Path

# ── Vérification des dépendances ──────────────────────────────────────────────
try:
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
    from cryptography.hazmat.primitives.serialization import (
        Encoding,
        NoEncryption,
        PublicFormat,
        PrivateFormat,
    )
except ImportError:
    print("ERREUR : bibliothèque 'cryptography' manquante.")
    print("Installer avec : pip3 install --break-system-packages cryptography")
    sys.exit(1)

# ── Chemins des fichiers ──────────────────────────────────────────────────────
ETC_DIR          = Path("/etc/sos-guide")
PRIVATE_KEY_FILE = ETC_DIR / "node_private_key.pem"
PUBLIC_KEY_FILE  = ETC_DIR / "node_public_key.pem"
FINGERPRINT_FILE = ETC_DIR / "node_fingerprint.txt"
TRUSTED_NODES    = ETC_DIR / "trusted_nodes.json"
CONFIG_FILE      = Path("/var/www/sos-guide/data/config.json")
NODE_ID_FILE     = ETC_DIR / "node_id"

# ── Fonctions utilitaires ─────────────────────────────────────────────────────

def check_root() -> None:
    """Ce script crée des fichiers protégés — il doit tourner en root."""
    if os.getuid() != 0:
        print("ERREUR : ce script doit être lancé en root (sudo).")
        sys.exit(1)


def secure_dir() -> None:
    """Crée /etc/sos-guide avec les bonnes permissions."""
    ETC_DIR.mkdir(parents=True, exist_ok=True)
    # Seul root peut lire ce dossier
    os.chmod(ETC_DIR, 0o700)
    os.chown(ETC_DIR, 0, 0)  # root:root
    print(f"  ✔ Répertoire sécurisé : {ETC_DIR}")


def generate_keypair() -> tuple[Ed25519PrivateKey, bytes, bytes]:
    """
    Génère une nouvelle paire de clés Ed25519.

    Retourne :
      private_key  : objet clé privée (ne quitte jamais la mémoire non chiffrée)
      priv_pem     : clé privée encodée PEM (à écrire sur disque, root seulement)
      pub_pem      : clé publique encodée PEM (partageable)
    """
    print("  Génération Ed25519...")

    # Le système d'exploitation fournit l'aléatoire cryptographique
    # (/dev/urandom sur Linux — entropie matérielle du Pi)
    private_key = Ed25519PrivateKey.generate()

    # Sérialisation clé privée au format PEM standard
    priv_pem = private_key.private_bytes(
        encoding=Encoding.PEM,
        format=PrivateFormat.PKCS8,
        encryption_algorithm=NoEncryption(),  # Pas de mot de passe — protégé par chmod 400
    )

    # Sérialisation clé publique au format PEM standard
    pub_pem = private_key.public_key().public_bytes(
        encoding=Encoding.PEM,
        format=PublicFormat.SubjectPublicKeyInfo,
    )

    return private_key, priv_pem, pub_pem


def compute_fingerprint(pub_pem: bytes) -> str:
    """
    Calcule une empreinte courte et lisible de la clé publique.

    Analogie : c'est comme le numéro de série gravé sur un équipement —
    permet de vérifier rapidement "est-ce bien le bon nœud ?" sans
    avoir à comparer les clés complètes.

    Format : XX:XX:XX:XX:XX:XX:XX:XX (8 groupes de 2 hex, lisible humain)
    """
    digest = hashlib.sha256(pub_pem).digest()
    # Prend les 8 premiers octets → 16 caractères hex → facile à vérifier visuellement
    return ":".join(f"{b:02X}" for b in digest[:8])


def sanitize_node_id(raw: str) -> str:
    """
    Nettoie un identifiant de nœud pour qu'il soit sûr dans un paquet LoRa.

    Règles :
      - Minuscules uniquement
      - Tirets autorisés, pas d'espaces ni de caractères spéciaux
      - Maximum 48 caractères (contrainte protocole LoRa)

    Exemple : "École Jean Jaurès Paris 75011" → "ecole-jean-jaures-paris-75011"
    """
    # Translittération basique des accents français
    replacements = {
        'é': 'e', 'è': 'e', 'ê': 'e', 'ë': 'e',
        'à': 'a', 'â': 'a', 'ä': 'a',
        'ù': 'u', 'û': 'u', 'ü': 'u',
        'î': 'i', 'ï': 'i',
        'ô': 'o', 'ö': 'o',
        'ç': 'c', 'œ': 'oe', 'æ': 'ae',
        ' ': '-', '_': '-',
    }
    result = raw.lower()
    for accent, replacement in replacements.items():
        result = result.replace(accent, replacement)
    # Supprime tout caractère non alphanumérique sauf le tiret
    result = re.sub(r'[^a-z0-9\-]', '', result)
    # Supprime les tirets multiples consécutifs
    result = re.sub(r'-+', '-', result).strip('-')
    # Limite à 48 caractères
    return result[:48] or "noeud-sos-guide"


def get_node_id_from_config() -> str:
    """
    Récupère le nom du nœud depuis config.json pour construire son identifiant.
    Si config.json n'existe pas encore, retourne un ID générique.
    """
    if CONFIG_FILE.exists():
        try:
            config = json.loads(CONFIG_FILE.read_text(encoding="utf-8"))
            name = config.get("establishment", {}).get("name", "")
            if name and name != "Lieu Non Défini":
                return sanitize_node_id(name)
        except (json.JSONDecodeError, KeyError):
            pass
    # Fallback : génère un ID basé sur l'heure pour qu'il soit unique
    ts = datetime.now(timezone.utc).strftime("%Y%m%d%H%M")
    return f"noeud-sos-guide-{ts}"


def write_private_key(priv_pem: bytes) -> None:
    """
    Écrit la clé privée avec les permissions les plus restrictives possibles.

    chmod 400 = seul root peut lire, personne ne peut écrire ni exécuter.
    C'est l'équivalent d'un coffre-fort numérique.
    """
    PRIVATE_KEY_FILE.write_bytes(priv_pem)
    os.chmod(PRIVATE_KEY_FILE, 0o400)   # -r-------- (root read-only)
    os.chown(PRIVATE_KEY_FILE, 0, 0)    # root:root
    print(f"  ✔ Clé privée : {PRIVATE_KEY_FILE} (chmod 400, root uniquement)")


def write_public_key(pub_pem: bytes) -> None:
    """
    Écrit la clé publique — peut être lue par le service lora-service.
    Elle est partagée avec les autres nœuds lors du déploiement.
    """
    PUBLIC_KEY_FILE.write_bytes(pub_pem)
    os.chmod(PUBLIC_KEY_FILE, 0o644)    # -rw-r--r-- (lisible par tous)
    os.chown(PUBLIC_KEY_FILE, 0, 0)
    print(f"  ✔ Clé publique : {PUBLIC_KEY_FILE} (partageable avec les autres nœuds)")


def write_fingerprint(fingerprint: str, node_id: str) -> None:
    """
    Écrit l'empreinte dans un fichier texte simple et dans config.json.
    L'empreinte sera affichée sur le portail captif pour identification visuelle.
    """
    FINGERPRINT_FILE.write_text(
        f"{fingerprint}\n",
        encoding="utf-8"
    )
    os.chmod(FINGERPRINT_FILE, 0o644)

    # Également stocker l'ID du nœud
    NODE_ID_FILE.write_text(f"{node_id}\n", encoding="utf-8")
    os.chmod(NODE_ID_FILE, 0o644)

    print(f"  ✔ Empreinte : {fingerprint}")
    print(f"  ✔ ID nœud   : {node_id}")

    # Injection dans config.json si il existe
    _update_config(fingerprint, node_id, PUBLIC_KEY_FILE.read_text(encoding="utf-8"))


def _update_config(fingerprint: str, node_id: str, pub_pem_str: str) -> None:
    """
    Met à jour config.json avec les informations cryptographiques du nœud.
    Ces informations apparaîtront dans l'interface admin et sur le portail.
    """
    if not CONFIG_FILE.exists():
        print(f"  ⚠ config.json absent — informations crypto non injectées")
        return

    try:
        config = json.loads(CONFIG_FILE.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        print(f"  ⚠ config.json invalide — impossible d'injecter les clés")
        return

    # Ajoute une section "lora" dans config.json
    config.setdefault("lora", {})
    config["lora"]["nodeId"]      = node_id
    config["lora"]["fingerprint"] = fingerprint
    config["lora"]["publicKey"]   = pub_pem_str  # Clé publique complète
    config["lora"]["keyDate"]     = datetime.now(timezone.utc).isoformat()

    # Écriture atomique (via fichier temporaire)
    tmp = CONFIG_FILE.with_suffix(".tmp")
    tmp.write_text(
        json.dumps(config, indent=2, ensure_ascii=False),
        encoding="utf-8"
    )
    tmp.replace(CONFIG_FILE)
    print(f"  ✔ config.json mis à jour avec les infos crypto LoRa")


def create_trusted_nodes_skeleton(node_id: str, fingerprint: str, pub_pem: bytes) -> None:
    """
    Crée le fichier trusted_nodes.json avec ce nœud comme premier membre.

    Ce fichier liste tous les nœuds autorisés à envoyer des alertes.
    Pour ajouter un nouveau nœud : copier sa clé publique dans ce fichier.

    Format :
    {
      "nodes": {
        "ecole-a-paris-75001": {        ← ID du nœud
          "name": "École A Paris",      ← Nom affiché
          "fingerprint": "AA:BB:...",   ← Pour vérification visuelle
          "public_key": "-----BEGIN..." ← Clé publique PEM complète
        }
      }
    }
    """
    if TRUSTED_NODES.exists():
        print(f"  ℹ trusted_nodes.json existe déjà — non modifié")
        return

    trusted = {
        "_comment": (
            "Fichier des nœuds SOS-GUIDE de confiance. "
            "Ajouter ici la clé publique de chaque nœud du réseau. "
            "Transférer via USB ou Ethernet lors du déploiement."
        ),
        "_version": "2.5",
        "nodes": {
            node_id: {
                "name":        node_id,  # L'admin peut renommer via admin.php
                "fingerprint": fingerprint,
                "public_key":  pub_pem.decode("utf-8"),
                "added_date":  datetime.now(timezone.utc).isoformat(),
                "is_self":     True,     # Ce nœud lui-même
            }
        }
    }

    TRUSTED_NODES.write_text(
        json.dumps(trusted, indent=2, ensure_ascii=False),
        encoding="utf-8"
    )
    os.chmod(TRUSTED_NODES, 0o644)
    print(f"  ✔ trusted_nodes.json créé : {TRUSTED_NODES}")


def verify_installation() -> bool:
    """
    Vérifie que les fichiers créés sont corrects et fonctionnels.
    Test concret : signe un message test et vérifie la signature.
    """
    print("\n  Test de vérification...")

    # Charger la clé privée depuis le disque
    priv_bytes = PRIVATE_KEY_FILE.read_bytes()
    from cryptography.hazmat.primitives.serialization import load_pem_private_key
    private_key = load_pem_private_key(priv_bytes, password=None)

    # Charger la clé publique depuis le disque
    pub_bytes = PUBLIC_KEY_FILE.read_bytes()
    from cryptography.hazmat.primitives.serialization import load_pem_public_key
    public_key = load_pem_public_key(pub_bytes)

    # Signer un message test
    test_message = b"SOS-GUIDE:test-signature:verification"
    signature = private_key.sign(test_message)

    # Vérifier avec la clé publique
    try:
        public_key.verify(signature, test_message)
        print("  ✔ Test cryptographique réussi : signe → vérifie OK")
        return True
    except Exception as e:
        print(f"  ✘ ERREUR test cryptographique : {e}")
        return False


# ── Programme principal ───────────────────────────────────────────────────────

def main() -> None:
    parser = argparse.ArgumentParser(
        description="SOS-GUIDE — Générateur de paire de clés Ed25519"
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="Régénère les clés même si elles existent déjà (⚠ attention)",
    )
    parser.add_argument(
        "--node-id",
        type=str,
        default="",
        help="Identifiant du nœud (ex: ecole-jean-jaures-paris-75011)",
    )
    args = parser.parse_args()

    print()
    print("══════════════════════════════════════════════════════════")
    print("  SOS-GUIDE — Génération identité cryptographique du nœud")
    print("══════════════════════════════════════════════════════════")

    # 1. Vérification root
    check_root()

    # 2. Vérification idempotence
    if PRIVATE_KEY_FILE.exists() and not args.force:
        existing_fp = FINGERPRINT_FILE.read_text().strip() if FINGERPRINT_FILE.exists() else "?"
        existing_id = NODE_ID_FILE.read_text().strip() if NODE_ID_FILE.exists() else "?"
        print(f"\n  ✔ Clés déjà présentes — aucune action.")
        print(f"  ID nœud   : {existing_id}")
        print(f"  Empreinte : {existing_fp}")
        print(f"\n  (Utiliser --force pour régénérer — invalide les nœuds voisins !)\n")
        sys.exit(0)

    # 3. Répertoire sécurisé
    print()
    secure_dir()

    # 4. Déterminer l'ID du nœud
    node_id = sanitize_node_id(args.node_id) if args.node_id else get_node_id_from_config()
    print(f"  ID nœud : {node_id}")

    # 5. Génération de la paire de clés
    private_key, priv_pem, pub_pem = generate_keypair()

    # 6. Calcul de l'empreinte
    fingerprint = compute_fingerprint(pub_pem)

    # 7. Écriture des fichiers
    print()
    write_private_key(priv_pem)
    write_public_key(pub_pem)
    write_fingerprint(fingerprint, node_id)
    create_trusted_nodes_skeleton(node_id, fingerprint, pub_pem)

    # 8. Vérification fonctionnelle
    ok = verify_installation()

    # 9. Résumé
    print()
    print("══════════════════════════════════════════════════════════")
    if ok:
        print("  ✔ SUCCÈS — Identité cryptographique du nœud créée")
    else:
        print("  ✘ ÉCHEC — Vérifier les erreurs ci-dessus")
    print()
    print(f"  ID nœud   : {node_id}")
    print(f"  Empreinte : {fingerprint}")
    print()
    print("  PROCHAINES ÉTAPES :")
    print(f"  1. Copier {PUBLIC_KEY_FILE} sur les autres nœuds du réseau")
    print(f"  2. Sur chaque nœud voisin, ajouter cette clé dans trusted_nodes.json")
    print(f"  3. Redémarrer lora-service : sudo systemctl restart lora-service")
    print("══════════════════════════════════════════════════════════")
    print()

    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
