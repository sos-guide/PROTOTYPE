#!/usr/bin/env python3
"""
╔══════════════════════════════════════════════════════════════════════════════╗
║  SOS-GUIDE — lora-service.py v2.5                                          ║
║  Service mesh LoRa — émission/réception d'alertes signées Ed25519          ║
║                                                                              ║
║  Ce service fait 4 choses :                                                  ║
║    1. ÉCOUTE les alertes LoRa des nœuds voisins                             ║
║    2. VÉRIFIE la signature de chaque alerte reçue                           ║
║    3. AFFICHE les alertes valides sur le portail SOS-GUIDE                  ║
║    4. ÉMET des alertes signées quand l'admin appuie sur le bouton           ║
║                                                                              ║
║  Matériel supporté :                                                         ║
║    - LILYGO T-Beam V1.2 (ESP32+LoRa) via USB serial (Meshtastic)           ║
║    - SX1276/SX1278 (RFM95W) via SPI direct sur GPIO Pi                     ║
║                                                                              ║
║  Version : 2.5 — Juin 2026                                                  ║
║  Auteur  : Ludovic MARTIN — contact@sos-guide.fr                            ║
║  Licence : EUPL-1.2                                                         ║
╚══════════════════════════════════════════════════════════════════════════════╝

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  COMMENT ÇA MARCHE (analogie électricité)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Le T-Beam est branché en USB sur le Pi.
  Il se comporte comme une prise série (COM port).

  Ce service Python :
    - Parle au T-Beam comme tu parles à un variateur de vitesse
      via RS485 : commandes texte simples, réponses simples.
    - Signe les alertes avec la clé privée Ed25519 du Pi
      (comme apposer le tampon officiel avant d'envoyer un courrier)
    - Vérifie les alertes reçues avec les clés publiques des voisins
      (comme vérifier l'authenticité d'un tampon officiel reçu)

  L'API REST locale (port 8765) permet à admin.php d'envoyer
  des alertes via un simple appel HTTP — sans que PHP ne touche
  aux clés cryptographiques.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Dépendances :
  pip3 install --break-system-packages cryptography flask meshtastic pyserial

Structure des fichiers :
  /etc/sos-guide/node_private_key.pem    ← clé privée (générée par sos_keypair_gen.py)
  /etc/sos-guide/node_public_key.pem     ← clé publique
  /etc/sos-guide/node_id                 ← identifiant du nœud
  /etc/sos-guide/trusted_nodes.json      ← nœuds de confiance du réseau
  /var/www/sos-guide/data/lora_inbox.json ← alertes reçues (lues par le portail)
  /var/log/sos-guide-lora.log            ← journal des événements
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import logging
import logging.handlers
import os
import sys
import threading
import time
from collections import deque
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

# ── Vérification des dépendances ─────────────────────────────────────────────
# cryptography : signatures Ed25519
try:
    from cryptography.hazmat.primitives.asymmetric.ed25519 import (
        Ed25519PrivateKey,
        Ed25519PublicKey,
    )
    from cryptography.hazmat.primitives.serialization import (
        load_pem_private_key,
        load_pem_public_key,
    )
    from cryptography.exceptions import InvalidSignature
    CRYPTO_OK = True
except ImportError:
    CRYPTO_OK = False
    print("ERREUR : pip3 install --break-system-packages cryptography")

# flask : API REST locale pour admin.php
try:
    from flask import Flask, request, jsonify
    FLASK_OK = True
except ImportError:
    FLASK_OK = False
    print("AVERTISSEMENT : flask non installé — API REST désactivée")

# meshtastic : communication avec le T-Beam via USB
# (bibliothèque officielle du firmware Meshtastic)
try:
    import meshtastic
    import meshtastic.serial_interface
    from pubsub import pub as pubsub
    MESHTASTIC_OK = True
except ImportError:
    MESHTASTIC_OK = False
    # Normal si le T-Beam n'est pas encore branché ou Meshtastic pas installé

# ── Configuration ─────────────────────────────────────────────────────────────
ETC_DIR          = Path("/etc/sos-guide")
PRIVATE_KEY_FILE = ETC_DIR / "node_private_key.pem"
PUBLIC_KEY_FILE  = ETC_DIR / "node_public_key.pem"
NODE_ID_FILE     = ETC_DIR / "node_id"
TRUSTED_NODES    = ETC_DIR / "trusted_nodes.json"

WEB_DATA_DIR     = Path("/var/www/sos-guide/data")
INBOX_FILE       = WEB_DATA_DIR / "lora_inbox.json"  # Alertes reçues → portail

LOG_FILE         = Path("/var/log/sos-guide-lora.log")

API_HOST         = "127.0.0.1"   # Accessible uniquement en local (nginx → proxy)
API_PORT         = 8765

# Paramètres anti-rejeu et mesh
MAX_ALERT_AGE_SEC = 120   # Une alerte vieille de plus de 2 min est rejetée
MAX_HOP_COUNT     = 5     # Maximum 5 rebonds dans le mesh
INBOX_MAX_ITEMS   = 50    # Nombre max d'alertes dans lora_inbox.json
DEDUP_CACHE_SIZE  = 200   # Cache mémoire pour éviter les doublons

# Types d'alertes autorisés (validés par le protocole)
ALERT_TYPES = {
    "PPMS":      "⚠️ Plan Particulier de Mise en Sécurité",
    "ATTENTAT":  "🚨 Attentat / Menace armée",
    "NRBC":      "☢️ Risque Nucléaire / Radiologique / Biologique / Chimique",
    "INCENDIE":  "🔥 Incendie",
    "CRUE":      "🌊 Inondation / Crue",
    "SEISME":    "🌍 Séisme",
    "EVACUATION":"🏃 Évacuation immédiate",
    "FIN_ALERTE":"✅ Fin d'alerte — retour à la normale",
    "CUSTOM":    "📢 Message d'urgence",
}

# ── Logging ───────────────────────────────────────────────────────────────────
LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
_rotating = logging.handlers.RotatingFileHandler(
    LOG_FILE, maxBytes=5 * 1024 * 1024, backupCount=2
)
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[
        logging.StreamHandler(sys.stdout),
        _rotating,
    ],
)
log = logging.getLogger("lora-service")


# ══════════════════════════════════════════════════════════════════════════════
# CLASSE : Paquet d'alerte LoRa
# ══════════════════════════════════════════════════════════════════════════════

class AlertPacket:
    """
    Représente un paquet d'alerte circulant dans le réseau mesh.

    Format JSON sérialisé (envoyé via LoRa) :
    {
      "v":   1,                     ← version du protocole
      "nid": "ecole-a-paris-75001", ← identifiant du nœud source
      "typ": "PPMS",                ← type d'alerte
      "ts":  1748123456,            ← timestamp Unix (anti-rejeu)
      "msg": "Rester en classe",    ← message optionnel (max 80 chars)
      "hop": 0,                     ← nombre de rebonds (0 = source originale)
      "sig": "base64..."            ← signature Ed25519 (64 octets → ~88 chars base64)
    }

    Taille max totale : ~250 octets
    (LoRa SF7 125kHz peut transmettre 255 octets par paquet)
    """

    PROTOCOL_VERSION = 1

    def __init__(
        self,
        node_id:    str,
        alert_type: str,
        message:    str = "",
        timestamp:  Optional[int] = None,
        hop:        int = 0,
        signature:  Optional[str] = None,
    ):
        self.v      = self.PROTOCOL_VERSION
        self.nid    = node_id[:48]           # Limite 48 chars
        self.typ    = alert_type
        self.ts     = timestamp or int(time.time())
        self.msg    = message[:80]           # Limite 80 chars
        self.hop    = hop
        self.sig    = signature

    def payload_to_sign(self) -> bytes:
        """
        Construit la chaîne de bytes à signer/vérifier.

        IMPORTANT : l'ordre et le format doivent être IDENTIQUES
        à l'émission et à la réception. Un espace de différence = signature invalide.

        On signe v|nid|typ|ts|msg mais PAS hop ni sig
        (car hop change à chaque rebond — on garde la signature de l'original)
        """
        payload = f"{self.v}|{self.nid}|{self.typ}|{self.ts}|{self.msg}"
        return payload.encode("utf-8")

    def unique_id(self) -> str:
        """
        Identifiant unique pour la déduplication (éviter d'afficher 2 fois la même alerte).
        Basé sur le nœud source + timestamp → même alerte relayée par 2 voisins = 1 affichage.
        """
        return hashlib.sha256(f"{self.nid}:{self.ts}".encode()).hexdigest()[:16]

    def to_json(self) -> str:
        """Sérialise le paquet en JSON compact pour transmission LoRa."""
        data = {
            "v":   self.v,
            "nid": self.nid,
            "typ": self.typ,
            "ts":  self.ts,
            "hop": self.hop,
        }
        if self.msg:
            data["msg"] = self.msg
        if self.sig:
            data["sig"] = self.sig
        return json.dumps(data, separators=(",", ":"), ensure_ascii=False)

    @classmethod
    def from_json(cls, raw: str) -> "AlertPacket":
        """Désérialise un paquet JSON reçu. Lève ValueError si invalide."""
        try:
            d = json.loads(raw)
        except json.JSONDecodeError as e:
            raise ValueError(f"JSON invalide : {e}") from e

        # Vérifications des champs obligatoires
        for field in ("v", "nid", "typ", "ts"):
            if field not in d:
                raise ValueError(f"Champ obligatoire manquant : '{field}'")

        if d.get("v") != cls.PROTOCOL_VERSION:
            raise ValueError(f"Version protocole non supportée : {d.get('v')}")

        if d.get("typ") not in ALERT_TYPES:
            raise ValueError(f"Type d'alerte inconnu : {d.get('typ')}")

        return cls(
            node_id    = str(d["nid"]),
            alert_type = str(d["typ"]),
            message    = str(d.get("msg", "")),
            timestamp  = int(d["ts"]),
            hop        = int(d.get("hop", 0)),
            signature  = d.get("sig"),
        )


# ══════════════════════════════════════════════════════════════════════════════
# CLASSE : Gestionnaire de clés cryptographiques
# ══════════════════════════════════════════════════════════════════════════════

class KeyManager:
    """
    Gère les clés Ed25519 du nœud et la liste des nœuds de confiance.

    Analogie :
      Ce gestionnaire est comme le responsable de sécurité d'une entreprise :
      - Il garde le tampon officiel dans le coffre (clé privée)
      - Il maintient le registre des tampons connus (trusted_nodes.json)
      - Il signe les courriers sortants
      - Il vérifie l'authenticité des courriers entrants
    """

    def __init__(self) -> None:
        self.node_id:     str = "inconnu"
        self.private_key: Optional[Ed25519PrivateKey] = None
        self.public_key:  Optional[Ed25519PublicKey]  = None
        self.trusted:     dict = {}   # {node_id: Ed25519PublicKey}
        self._lock = threading.Lock()

    def load(self) -> bool:
        """
        Charge les clés depuis le disque.
        Retourne True si tout est OK, False sinon.
        """
        if not CRYPTO_OK:
            log.error("Bibliothèque 'cryptography' non installée")
            return False

        # ID du nœud
        if NODE_ID_FILE.exists():
            self.node_id = NODE_ID_FILE.read_text(encoding="utf-8").strip()
        else:
            log.warning("node_id absent — lancer sos_keypair_gen.py d'abord")
            return False

        # Clé privée
        if not PRIVATE_KEY_FILE.exists():
            log.error(f"Clé privée absente : {PRIVATE_KEY_FILE}")
            log.error("Lancer : sudo python3 sos_keypair_gen.py")
            return False

        try:
            priv_bytes = PRIVATE_KEY_FILE.read_bytes()
            self.private_key = load_pem_private_key(priv_bytes, password=None)
            self.public_key  = self.private_key.public_key()
            log.info(f"Clé privée chargée pour le nœud : {self.node_id}")
        except Exception as e:
            log.error(f"Impossible de charger la clé privée : {e}")
            return False

        # Nœuds de confiance
        self._load_trusted_nodes()
        return True

    def _load_trusted_nodes(self) -> None:
        """
        Charge trusted_nodes.json.
        Ce fichier contient les clés publiques des nœuds du réseau.
        Il peut être rechargé à chaud sans redémarrer le service.
        """
        if not TRUSTED_NODES.exists():
            log.warning(f"trusted_nodes.json absent : {TRUSTED_NODES}")
            log.warning("Seule la signature de ce nœud sera acceptée")
            return

        try:
            data = json.loads(TRUSTED_NODES.read_text(encoding="utf-8"))
            nodes = data.get("nodes", {})
            loaded = 0
            with self._lock:
                self.trusted = {}
                for nid, info in nodes.items():
                    pub_pem = info.get("public_key", "")
                    if not pub_pem:
                        log.warning(f"Nœud {nid} sans clé publique — ignoré")
                        continue
                    try:
                        pk = load_pem_public_key(pub_pem.encode("utf-8"))
                        self.trusted[nid] = pk
                        loaded += 1
                    except Exception as e:
                        log.warning(f"Clé invalide pour {nid} : {e}")
            log.info(f"{loaded} nœud(s) de confiance chargé(s)")
        except Exception as e:
            log.error(f"Erreur chargement trusted_nodes.json : {e}")

    def sign(self, packet: AlertPacket) -> str:
        """
        Signe un paquet avec la clé privée du nœud.
        Retourne la signature encodée en base64 (88 chars environ).
        """
        if not self.private_key:
            raise RuntimeError("Clé privée non chargée")
        payload  = packet.payload_to_sign()
        sig_bytes = self.private_key.sign(payload)
        return base64.b64encode(sig_bytes).decode("ascii")

    def verify(self, packet: AlertPacket) -> tuple[bool, str]:
        """
        Vérifie la signature d'un paquet reçu.

        Retourne :
          (True,  "")       si la signature est valide
          (False, "raison") si la signature est invalide
        """
        if not CRYPTO_OK:
            return False, "cryptography non installée"

        if not packet.sig:
            return False, "signature absente"

        # Chercher la clé publique du nœud source
        with self._lock:
            public_key = self.trusted.get(packet.nid)

        if public_key is None:
            return False, f"nœud '{packet.nid}' non connu dans trusted_nodes.json"

        try:
            sig_bytes = base64.b64decode(packet.sig)
        except Exception:
            return False, "signature base64 invalide"

        try:
            public_key.verify(sig_bytes, packet.payload_to_sign())
            return True, ""
        except InvalidSignature:
            return False, "signature Ed25519 invalide — alerte REJETÉE"
        except Exception as e:
            return False, f"erreur vérification : {e}"

    def reload_trusted_nodes(self) -> None:
        """Recharge trusted_nodes.json sans redémarrer le service."""
        self._load_trusted_nodes()


# ══════════════════════════════════════════════════════════════════════════════
# CLASSE : Boîte de réception des alertes (RAM + fichier JSON)
# ══════════════════════════════════════════════════════════════════════════════

class AlertInbox:
    """
    Stocke les alertes reçues et les rend disponibles pour le portail web.

    Les alertes sont gardées en RAM (liste) ET écrites dans lora_inbox.json
    que index.html lit via JavaScript toutes les 5 secondes.

    Aucune donnée personnelle n'est stockée. Les alertes sont perdues
    au redémarrage du service (RAM uniquement pour la déduplication).
    """

    def __init__(self) -> None:
        self._alerts: list = []         # Liste des alertes affichées
        self._seen:   deque = deque(maxlen=DEDUP_CACHE_SIZE)  # Cache anti-doublon
        self._lock = threading.Lock()

    def is_duplicate(self, packet: AlertPacket) -> bool:
        """Vérifie si cette alerte a déjà été reçue (anti-doublon mesh)."""
        uid = packet.unique_id()
        with self._lock:
            if uid in self._seen:
                return True
            self._seen.append(uid)
            return False

    def is_too_old(self, packet: AlertPacket) -> bool:
        """Rejette les alertes trop anciennes (protection anti-rejeu)."""
        age = int(time.time()) - packet.ts
        return age > MAX_ALERT_AGE_SEC

    def add(self, packet: AlertPacket, verified: bool) -> None:
        """
        Ajoute une alerte à la boîte de réception et met à jour le fichier JSON.
        Seules les alertes vérifiées ou locales sont ajoutées.
        """
        alert_data = {
            "id":         packet.unique_id(),
            "node_id":    packet.nid,
            "type":       packet.typ,
            "type_label": ALERT_TYPES.get(packet.typ, packet.typ),
            "message":    packet.msg,
            "timestamp":  packet.ts,
            "datetime":   datetime.fromtimestamp(
                              packet.ts, tz=timezone.utc
                          ).strftime("%H:%M UTC"),
            "hop":        packet.hop,
            "verified":   verified,
        }

        with self._lock:
            # Ajoute en tête de liste (plus récent en premier)
            self._alerts.insert(0, alert_data)
            # Garde seulement les N dernières alertes
            self._alerts = self._alerts[:INBOX_MAX_ITEMS]

        self._write_to_file()

        log.info(
            f"ALERTE {'✔' if verified else '⚠'} | "
            f"{packet.nid} | {packet.typ} | hop={packet.hop} | "
            f"{'vérifiée' if verified else 'NON VÉRIFIÉE'}"
        )

    def _write_to_file(self) -> None:
        """
        Écrit lora_inbox.json de manière atomique.
        index.html le lit toutes les 5 secondes pour afficher les alertes.
        Écriture atomique = on écrit d'abord dans un fichier .tmp
        puis on le renomme → jamais de fichier à moitié écrit.
        """
        WEB_DATA_DIR.mkdir(parents=True, exist_ok=True)
        tmp = INBOX_FILE.with_suffix(".tmp")
        try:
            with self._lock:
                data = {
                    "updated": int(time.time()),
                    "alerts":  list(self._alerts),
                }
            tmp.write_text(
                json.dumps(data, indent=2, ensure_ascii=False),
                encoding="utf-8"
            )
            tmp.replace(INBOX_FILE)
        except Exception as e:
            log.error(f"Erreur écriture lora_inbox.json : {e}")

    def get_alerts(self) -> list:
        """Retourne la liste des alertes (pour l'API REST)."""
        with self._lock:
            return list(self._alerts)


# ══════════════════════════════════════════════════════════════════════════════
# CLASSE : Interface LoRa (T-Beam via Meshtastic USB serial)
# ══════════════════════════════════════════════════════════════════════════════

class LoRaInterface:
    """
    Gère la communication avec le module T-Beam via USB.

    Le T-Beam tourne le firmware Meshtastic qui expose une API serial
    propre. Ce service Python lui envoie des messages texte et reçoit
    des messages des nœuds voisins via la bibliothèque meshtastic-python.

    Si le T-Beam n'est pas branché, le service fonctionne en mode
    "simulation" — utile pour développer et tester sans hardware.
    """

    # Port série — le Pi détecte le T-Beam comme /dev/ttyUSB0 ou /dev/ttyACM0
    SERIAL_PORTS = ["/dev/ttyUSB0", "/dev/ttyACM0", "/dev/ttyUSB1"]

    def __init__(self, on_receive_callback) -> None:
        """
        on_receive_callback : fonction appelée quand une alerte est reçue
                              Signature : callback(raw_json_string: str)
        """
        self._callback = on_receive_callback
        self._interface = None
        self._connected = False
        self._simulation_mode = False
        self._lock = threading.Lock()

    def connect(self) -> bool:
        """
        Tente de se connecter au T-Beam.
        Si aucun port n'est trouvé, active le mode simulation.
        """
        if not MESHTASTIC_OK:
            log.warning("meshtastic non installé — mode simulation activé")
            self._simulation_mode = True
            return False

        for port in self.SERIAL_PORTS:
            if not Path(port).exists():
                continue
            try:
                log.info(f"Connexion T-Beam sur {port}...")
                self._interface = meshtastic.serial_interface.SerialInterface(port)
                # S'abonne aux messages reçus par Meshtastic
                pubsub.subscribe(self._on_meshtastic_receive, "meshtastic.receive")
                self._connected = True
                log.info(f"T-Beam connecté sur {port} ✔")
                return True
            except Exception as e:
                log.warning(f"Port {port} : {e}")

        log.warning("T-Beam non trouvé — mode simulation activé")
        log.warning("Brancher le T-Beam en USB et relancer : sudo systemctl restart lora-service")
        self._simulation_mode = True
        return False

    def _on_meshtastic_receive(self, packet, interface) -> None:
        """
        Callback appelé par Meshtastic quand un message arrive du réseau LoRa.
        Extrait le texte du paquet Meshtastic et le passe au service principal.
        """
        try:
            # Les messages texte sont dans packet["decoded"]["text"]
            if "decoded" not in packet:
                return
            decoded = packet["decoded"]
            if decoded.get("portnum") != "TEXT_MESSAGE_APP":
                return
            raw_text = decoded.get("text", "")
            if not raw_text:
                return
            # Appel du callback principal
            self._callback(raw_text)
        except Exception as e:
            log.error(f"Erreur traitement paquet Meshtastic : {e}")

    def send(self, json_text: str) -> bool:
        """
        Envoie un message JSON texte via le T-Beam.
        En mode simulation, logue le message sans l'envoyer.
        """
        if self._simulation_mode:
            log.info(f"[SIMULATION] Émission LoRa : {json_text[:100]}...")
            return True

        if not self._connected or not self._interface:
            log.error("T-Beam non connecté — impossible d'envoyer")
            return False

        try:
            with self._lock:
                self._interface.sendText(json_text)
            log.info(f"Émission LoRa OK : {json_text[:60]}...")
            return True
        except Exception as e:
            log.error(f"Erreur émission LoRa : {e}")
            return False

    def is_connected(self) -> bool:
        return self._connected

    def is_simulation(self) -> bool:
        return self._simulation_mode

    def disconnect(self) -> None:
        if self._interface:
            try:
                self._interface.close()
            except Exception:
                pass
        self._connected = False


# ══════════════════════════════════════════════════════════════════════════════
# CLASSE : Service principal
# ══════════════════════════════════════════════════════════════════════════════

class LoRaService:
    """
    Orchestre tout : clés, réception, vérification, émission, API REST.
    """

    def __init__(self) -> None:
        self.key_manager = KeyManager()
        self.inbox       = AlertInbox()
        self.lora        = LoRaInterface(self._on_packet_received)
        self.app         = Flask("sos-guide-lora") if FLASK_OK else None
        self._running    = False

    def start(self) -> None:
        """Démarre tous les composants du service."""
        log.info("═══════════════════════════════════════════════")
        log.info("  SOS-GUIDE LoRa Service v2.5 — démarrage")
        log.info("═══════════════════════════════════════════════")

        # 1. Charger les clés cryptographiques
        if not self.key_manager.load():
            log.error("Impossible de charger les clés — arrêt")
            log.error("Lancer d'abord : sudo python3 sos_keypair_gen.py")
            sys.exit(1)

        log.info(f"Nœud : {self.key_manager.node_id}")

        # 2. Connecter le T-Beam
        connected = self.lora.connect()
        if connected:
            log.info("T-Beam LoRa connecté")
        else:
            log.warning("Mode simulation — alertes non transmises physiquement")

        # 3. Démarrer l'API REST dans un thread séparé
        if FLASK_OK:
            self._setup_api()
            api_thread = threading.Thread(
                target=self._run_api,
                daemon=True,
                name="lora-api",
            )
            api_thread.start()
            log.info(f"API REST démarrée sur http://{API_HOST}:{API_PORT}")

        self._running = True
        log.info("Service LoRa prêt ✔")

        # 4. Boucle principale (maintient le service en vie)
        try:
            while self._running:
                time.sleep(5)
        except KeyboardInterrupt:
            log.info("Arrêt demandé")
        finally:
            self.stop()

    def stop(self) -> None:
        self._running = False
        self.lora.disconnect()
        log.info("Service LoRa arrêté")

    def _on_packet_received(self, raw: str) -> None:
        """
        Traite un paquet JSON reçu depuis le réseau LoRa.
        Pipeline : désérialiser → anti-doublon → anti-rejeu → vérifier signature → afficher
        """
        log.debug(f"Paquet reçu : {raw[:100]}")

        # Étape 1 : Désérialiser le JSON
        try:
            packet = AlertPacket.from_json(raw)
        except ValueError as e:
            log.warning(f"Paquet invalide ignoré : {e}")
            return

        # Étape 2 : Anti-doublon (même alerte relayée par 2 voisins)
        if self.inbox.is_duplicate(packet):
            log.debug(f"Doublon ignoré : {packet.unique_id()}")
            return

        # Étape 3 : Anti-rejeu (alerte trop ancienne)
        if self.inbox.is_too_old(packet):
            age = int(time.time()) - packet.ts
            log.warning(f"Alerte trop ancienne ({age}s) ignorée : {packet.nid}")
            return

        # Étape 4 : Vérification de la signature Ed25519
        valid, reason = self.key_manager.verify(packet)
        if not valid:
            log.warning(f"Signature invalide — {reason}")
            # On n'affiche PAS les alertes non vérifiées par défaut
            # (comportement paramétrable dans une future version)
            return

        log.info(f"Alerte VALIDE reçue : {packet.nid} | {packet.typ} | hop={packet.hop}")

        # Étape 5 : Ajouter à la boîte de réception → portail mis à jour
        self.inbox.add(packet, verified=True)

        # Étape 6 : Relayage mesh (si TTL non dépassé)
        self._relay(packet)

    def _relay(self, packet: AlertPacket) -> None:
        """
        Relaye une alerte reçue vers les nœuds voisins (mesh store-and-forward).
        Incrémente le compteur de sauts. Arrête si TTL dépassé.
        """
        if packet.hop >= MAX_HOP_COUNT:
            log.debug(f"TTL épuisé ({packet.hop} sauts) — pas de relayage")
            return

        # Créer un nouveau paquet avec hop + 1
        # La signature ORIGINALE est conservée (on ne re-signe pas)
        relayed = AlertPacket(
            node_id    = packet.nid,    # Source originale (pas ce nœud)
            alert_type = packet.typ,
            message    = packet.msg,
            timestamp  = packet.ts,     # Timestamp original conservé
            hop        = packet.hop + 1,
            signature  = packet.sig,    # Signature originale conservée
        )
        self.lora.send(relayed.to_json())
        log.info(f"Relayage : {packet.nid} | hop {packet.hop} → {relayed.hop}")

    def emit_alert(self, alert_type: str, message: str = "") -> dict:
        """
        Émet une nouvelle alerte depuis CE nœud.
        Appelé par l'API REST quand l'admin clique sur le bouton d'alerte.

        C'est ici que la signature est créée.
        """
        if alert_type not in ALERT_TYPES:
            return {"success": False, "error": f"Type inconnu : {alert_type}"}

        # Créer le paquet
        packet = AlertPacket(
            node_id    = self.key_manager.node_id,
            alert_type = alert_type,
            message    = message[:80],
            hop        = 0,  # Ce nœud est la source originale
        )

        # Signer avec la clé privée de ce nœud
        try:
            packet.sig = self.key_manager.sign(packet)
        except Exception as e:
            log.error(f"Erreur signature : {e}")
            return {"success": False, "error": "Erreur signature"}

        # Envoyer via LoRa
        json_payload = packet.to_json()
        sent = self.lora.send(json_payload)

        # Ajouter dans la propre boîte de réception (afficher sur portail local)
        self.inbox.add(packet, verified=True)

        log.info(
            f"ALERTE ÉMISE | type={alert_type} | "
            f"taille={len(json_payload)}o | "
            f"sim={'oui' if self.lora.is_simulation() else 'non'}"
        )

        return {
            "success":     True,
            "alert_id":    packet.unique_id(),
            "node_id":     packet.nid,
            "type":        alert_type,
            "type_label":  ALERT_TYPES[alert_type],
            "timestamp":   packet.ts,
            "simulation":  self.lora.is_simulation(),
            "payload_size": len(json_payload),
        }

    # ── API REST Flask ────────────────────────────────────────────────────────

    def _setup_api(self) -> None:
        """
        Définit les routes de l'API REST locale.

        Accessible uniquement depuis localhost → admin.php fait un appel HTTP
        interne à http://127.0.0.1:8765/api/... sans exposer le port à l'extérieur.

        Routes :
          GET  /api/status       → état du service (connecté ?, simulation ?)
          GET  /api/alerts       → liste des alertes reçues
          POST /api/emit         → émettre une alerte (nécessite secret interne)
          POST /api/reload-keys  → recharger trusted_nodes.json sans redémarrer
        """
        app = self.app

        @app.route("/api/status")
        def api_status():
            return jsonify({
                "ok":          True,
                "node_id":     self.key_manager.node_id,
                "connected":   self.lora.is_connected(),
                "simulation":  self.lora.is_simulation(),
                "alert_count": len(self.inbox.get_alerts()),
                "trusted_nodes": len(self.key_manager.trusted),
                "version":     "2.5",
            })

        @app.route("/api/alerts")
        def api_alerts():
            return jsonify({
                "ok":     True,
                "alerts": self.inbox.get_alerts(),
            })

        @app.route("/api/emit", methods=["POST"])
        def api_emit():
            """
            Émet une alerte. Appelé par admin.php via HTTP interne.
            Vérifie un secret partagé stocké dans /etc/sos-guide/api_secret
            pour éviter qu'un utilisateur du portail n'émette des alertes.
            """
            # Vérification du secret API interne
            secret_file = ETC_DIR / "api_secret"
            if secret_file.exists():
                expected = secret_file.read_text(encoding="utf-8").strip()
                provided = request.headers.get("X-SOS-Secret", "")
                if provided != expected:
                    log.warning(f"Tentative d'émission sans secret valide : {request.remote_addr}")
                    return jsonify({"success": False, "error": "Non autorisé"}), 403

            data = request.get_json(silent=True) or {}
            alert_type = str(data.get("type", "")).upper()
            message    = str(data.get("message", ""))

            result = self.emit_alert(alert_type, message)
            return jsonify(result), 200 if result["success"] else 400

        @app.route("/api/reload-keys", methods=["POST"])
        def api_reload_keys():
            """Recharge trusted_nodes.json — utile après ajout d'un nouveau nœud."""
            self.key_manager.reload_trusted_nodes()
            return jsonify({
                "ok":           True,
                "trusted_count": len(self.key_manager.trusted),
            })

    def _run_api(self) -> None:
        """Lance le serveur Flask dans son thread. Erreurs silencieuses."""
        try:
            self.app.run(
                host=API_HOST,
                port=API_PORT,
                debug=False,
                use_reloader=False,
            )
        except Exception as e:
            log.error(f"API REST erreur : {e}")


# ══════════════════════════════════════════════════════════════════════════════
# POINT D'ENTRÉE
# ══════════════════════════════════════════════════════════════════════════════

def main() -> None:
    parser = argparse.ArgumentParser(description="SOS-GUIDE LoRa Service v2.5")
    parser.add_argument(
        "--test-emit",
        type=str,
        metavar="TYPE",
        help="Émet une alerte test et quitte (ex: --test-emit PPMS)",
    )
    parser.add_argument(
        "--test-sign",
        action="store_true",
        help="Teste la signature/vérification et quitte",
    )
    args = parser.parse_args()

    # Mode test signature (sans matériel)
    if args.test_sign:
        print("\nTest cryptographique Ed25519...")
        km = KeyManager()
        if not km.load():
            print("ÉCHEC : clés non trouvées — lancer sos_keypair_gen.py d'abord")
            sys.exit(1)
        # Créer un paquet test
        pkt = AlertPacket(km.node_id, "PPMS", "Test signature")
        pkt.sig = km.sign(pkt)
        ok, reason = km.verify(pkt)
        if ok:
            print(f"✔ Signature : OK")
            print(f"  Nœud      : {km.node_id}")
            print(f"  Payload   : {pkt.payload_to_sign()[:60]}...")
            print(f"  Signature : {pkt.sig[:40]}...")
        else:
            print(f"✘ ÉCHEC : {reason}")
        sys.exit(0 if ok else 1)

    # Mode test émission
    if args.test_emit:
        service = LoRaService()
        if not service.key_manager.load():
            sys.exit(1)
        service.lora.connect()
        result = service.emit_alert(args.test_emit.upper(), "Alerte test SOS-GUIDE")
        print(json.dumps(result, indent=2, ensure_ascii=False))
        sys.exit(0 if result.get("success") else 1)

    # Mode service normal
    service = LoRaService()
    service.start()


if __name__ == "__main__":
    main()
