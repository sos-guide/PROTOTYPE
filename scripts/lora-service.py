#!/usr/bin/env python3
"""
╔══════════════════════════════════════════════════════════════════════════════╗
║  SOS-GUIDE — lora-service.py                                               ║
║  Service mesh LoRa pour communication d'urgence hors ligne                  ║
║                                                                              ║
║  Matériel supporté : SX1276 / SX1278 (RFM95W) via SPI                      ║
║                      RAK3172 / RAK811 via UART (mode AT)                    ║
║                                                                              ║
║  Protocole :                                                                 ║
║    - Chiffrement  : AES-256-GCM (nonce aléatoire 96 bits, tag 128 bits)     ║
║    - Clé          : dérivée via PBKDF2-HMAC-SHA256 depuis /etc/lora.key     ║
║    - Mesh         : store-and-forward, TTL=5 sauts, déduplication UUID      ║
║    - API REST     : http://127.0.0.1:8765 (portail captif → PHP → LoRa)     ║
║    - Fréquence    : 868.1 MHz (EU868, conforme ETSI EN 300 220)             ║
║    - Puissance    : 14 dBm max (légal EU sans licence)                      ║
║                                                                              ║
║  Version : 2.2 — Avril 2026                                                 ║
╚══════════════════════════════════════════════════════════════════════════════╝

Dépendances système :
    pip3 install pyLoRa RPi.GPIO spidev flask cryptography

Installation :
    sudo cp lora-service.py /usr/local/bin/
    sudo cp lora-service.service /etc/systemd/system/
    sudo systemctl enable --now lora-service
"""

from __future__ import annotations

import json
import logging
import os
import secrets
import struct
import sys
import threading
import time
import uuid
from collections import deque
from datetime import datetime, timezone
from typing import Optional

# ── Vérification des dépendances ─────────────────────────────────────────────
try:
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    from cryptography.hazmat.primitives.kdf.pbkdf2 import PBKDF2HMAC
    from cryptography.hazmat.primitives import hashes
    from cryptography.exceptions import InvalidTag
    CRYPTO_OK = True
except ImportError:
    CRYPTO_OK = False

try:
    from flask import Flask, request, jsonify
    FLASK_OK = True
except ImportError:
    FLASK_OK = False

# LoRa hardware (optionnel — fallback simulation si absent)
LORA_HW_OK = False
try:
    import RPi.GPIO as GPIO           # type: ignore
    import spidev                     # type: ignore
    LORA_HW_OK = True
except ImportError:
    pass

# ── Logging ───────────────────────────────────────────────────────────────────
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [%(levelname)s] lora-service: %(message)s',
    handlers=[
        logging.StreamHandler(sys.stdout),
        logging.FileHandler('/var/log/sos-guide-lora.log'),
    ],
)
log = logging.getLogger('lora')

# ══════════════════════════════════════════════════════════════════════════════
# CONFIGURATION
# ══════════════════════════════════════════════════════════════════════════════
CONFIG_FILE    = '/var/www/sos-guide/data/config.json'
KEY_FILE       = '/etc/sos-guide/lora.key'        # Secret partagé réseau
NODE_ID_FILE   = '/etc/sos-guide/node_id'
API_HOST       = '127.0.0.1'
API_PORT       = 8765
MAX_STORE      = 500        # Messages en RAM max
TTL_DEFAULT    = 5          # Sauts maximum
DEDUP_WINDOW   = 3600       # Secondes pour déduplication
FREQ_HZ        = 868_100_000  # 868.1 MHz (EU868 channel 0)
TX_POWER_DBM   = 14           # 14 dBm = légal EU sans licence
BANDWIDTH      = 125_000      # 125 kHz
SPREADING_FACTOR = 7          # SF7 = vitesse max, portée ~2km

# Registres SX1276
REG_FIFO            = 0x00
REG_OP_MODE         = 0x01
REG_FRF_MSB         = 0x06
REG_FRF_MID         = 0x07
REG_FRF_LSB         = 0x08
REG_PA_CONFIG       = 0x09
REG_LNA             = 0x0C
REG_FIFO_ADDR_PTR   = 0x0D
REG_FIFO_TX_BASE    = 0x0E
REG_FIFO_RX_BASE    = 0x0F
REG_FIFO_RX_CURRENT = 0x10
REG_IRQ_FLAGS       = 0x12
REG_RX_NB_BYTES     = 0x13
REG_PKT_SNR_VALUE   = 0x19
REG_PKT_RSSI_VALUE  = 0x1A
REG_MODEM_CONFIG1   = 0x1D
REG_MODEM_CONFIG2   = 0x1E
REG_PREAMBLE_MSB    = 0x20
REG_PREAMBLE_LSB    = 0x21
REG_PAYLOAD_LENGTH  = 0x22
REG_MODEM_CONFIG3   = 0x26
REG_SYNC_WORD       = 0x39
REG_DIO_MAPPING1    = 0x40
REG_VERSION         = 0x42
REG_PA_DAC          = 0x4D

MODE_SLEEP      = 0x00
MODE_STDBY      = 0x01
MODE_TX         = 0x03
MODE_RX_CONT    = 0x05
MODE_LORA       = 0x80
PA_BOOST        = 0x80
IRQ_RX_DONE     = 0x40
IRQ_TX_DONE     = 0x08
IRQ_CRC_ERROR   = 0x20

SPI_BUS = 0
SPI_CS  = 0
PIN_RST = 22   # GPIO22 = Pin 15
PIN_DIO0= 4    # GPIO4  = Pin 7

# ══════════════════════════════════════════════════════════════════════════════
# GESTION DE LA CLÉ AES-256
# ══════════════════════════════════════════════════════════════════════════════
def ensure_key_file() -> None:
    """Génère ou charge la clé AES-256 depuis /etc/sos-guide/lora.key"""
    os.makedirs(os.path.dirname(KEY_FILE), exist_ok=True)
    if not os.path.exists(KEY_FILE):
        # Générer un mot de passe réseau aléatoire (64 hex = 32 bytes)
        key_material = secrets.token_hex(32)
        with open(KEY_FILE, 'w') as f:
            f.write(key_material)
        os.chmod(KEY_FILE, 0o400)
        log.info("Nouvelle clé réseau LoRa générée : %s", KEY_FILE)
    os.chmod(KEY_FILE, 0o400)


def derive_aes_key() -> bytes:
    """Dérive une clé AES-256 depuis le fichier de secret partagé via PBKDF2."""
    with open(KEY_FILE, 'r') as f:
        password = f.read().strip().encode()
    # Salt fixe et public : différencie le réseau SOS-GUIDE des autres
    salt = b'SOS-GUIDE-LORA-MESH-v2-EU868'
    kdf = PBKDF2HMAC(
        algorithm=hashes.SHA256(),
        length=32,
        salt=salt,
        iterations=100_000,
    )
    return kdf.derive(password)


def get_node_id() -> str:
    """Retourne l'identifiant unique de ce nœud (UUID v4 stable)."""
    os.makedirs(os.path.dirname(NODE_ID_FILE), exist_ok=True)
    if os.path.exists(NODE_ID_FILE):
        with open(NODE_ID_FILE) as f:
            nid = f.read().strip()
        if len(nid) == 8:
            return nid
    nid = secrets.token_hex(4)  # 8 hex = identifiant court pour les payloads
    with open(NODE_ID_FILE, 'w') as f:
        f.write(nid)
    return nid


# ══════════════════════════════════════════════════════════════════════════════
# CHIFFREMENT AES-256-GCM
# ══════════════════════════════════════════════════════════════════════════════
class LoRaCrypto:
    """
    Chiffrement/déchiffrement AES-256-GCM pour les trames LoRa.

    Format d'une trame chiffrée :
        [nonce 12 bytes][ciphertext + tag 16 bytes]

    Format du plaintext (JSON encodé UTF-8, max ~180 bytes) :
        {
            "id":   "a1b2c3d4",      # UUID trame (8 hex)
            "src":  "a1b2c3d4",      # ID nœud source (8 hex)
            "ttl":  5,               # Sauts restants
            "ts":   1714000000,      # Timestamp UNIX
            "type": "msg",           # msg | alert | ack | heartbeat
            "body": "Texte..."       # Max 128 chars
        }
    """

    def __init__(self, key: bytes) -> None:
        self._aesgcm = AESGCM(key)

    def encrypt(self, payload: dict) -> bytes:
        plaintext = json.dumps(payload, ensure_ascii=False, separators=(',', ':')).encode()
        nonce     = secrets.token_bytes(12)
        ct        = self._aesgcm.encrypt(nonce, plaintext, None)
        return nonce + ct  # 12 + len(ct) bytes

    def decrypt(self, frame: bytes) -> Optional[dict]:
        if len(frame) < 13:
            return None
        nonce = frame[:12]
        ct    = frame[12:]
        try:
            plaintext = self._aesgcm.decrypt(nonce, ct, None)
            return json.loads(plaintext.decode())
        except (InvalidTag, json.JSONDecodeError, UnicodeDecodeError):
            return None


# ══════════════════════════════════════════════════════════════════════════════
# PILOTE SX1276 (SPI)
# ══════════════════════════════════════════════════════════════════════════════
class SX1276:
    """
    Pilote minimal pour module LoRa SX1276 / RFM95W via SPI.
    Fréquence EU868, BW 125 kHz, SF7, CR 4/5.
    """

    def __init__(self) -> None:
        self._spi  = None
        self._ready = False
        if not LORA_HW_OK:
            log.warning("RPi.GPIO/spidev non disponibles — mode simulation activé")
            return
        self._init_hw()

    def _init_hw(self) -> None:
        try:
            GPIO.setwarnings(False)
            GPIO.setmode(GPIO.BCM)
            GPIO.setup(PIN_RST,  GPIO.OUT)
            GPIO.setup(PIN_DIO0, GPIO.IN,  pull_up_down=GPIO.PUD_DOWN)

            # Reset matériel
            GPIO.output(PIN_RST, GPIO.LOW)
            time.sleep(0.01)
            GPIO.output(PIN_RST, GPIO.HIGH)
            time.sleep(0.01)

            self._spi = spidev.SpiDev()
            self._spi.open(SPI_BUS, SPI_CS)
            self._spi.max_speed_hz = 5_000_000
            self._spi.mode = 0b00

            version = self._read(REG_VERSION)
            if version not in (0x12, 0x22):
                log.error("SX1276 : version inconnue 0x%02X (attendu 0x12)", version)
                return

            self._configure()
            self._ready = True
            log.info("SX1276 initialisé — version 0x%02X — %.1f MHz SF%d BW%d",
                     version, FREQ_HZ / 1e6, SPREADING_FACTOR, BANDWIDTH // 1000)
        except Exception as e:
            log.error("SX1276 init échoué : %s", e)

    def _write(self, reg: int, val: int) -> None:
        self._spi.xfer2([reg | 0x80, val])

    def _read(self, reg: int) -> int:
        return self._spi.xfer2([reg & 0x7F, 0])[1]

    def _write_buf(self, reg: int, data: bytes) -> None:
        self._spi.xfer2([reg | 0x80] + list(data))

    def _read_buf(self, reg: int, length: int) -> bytes:
        return bytes(self._spi.xfer2([reg & 0x7F] + [0] * length)[1:])

    def _configure(self) -> None:
        # Mode sleep LoRa
        self._write(REG_OP_MODE, MODE_SLEEP | MODE_LORA)
        time.sleep(0.01)

        # Fréquence
        frf = int((FREQ_HZ * (1 << 19)) / 32_000_000)
        self._write(REG_FRF_MSB, (frf >> 16) & 0xFF)
        self._write(REG_FRF_MID, (frf >>  8) & 0xFF)
        self._write(REG_FRF_LSB,  frf        & 0xFF)

        # Puissance TX via PA_BOOST
        if TX_POWER_DBM > 17:
            self._write(REG_PA_DAC, 0x87)
            self._write(REG_PA_CONFIG, PA_BOOST | (min(TX_POWER_DBM, 20) - 2))
        else:
            self._write(REG_PA_DAC, 0x84)
            self._write(REG_PA_CONFIG, PA_BOOST | (min(TX_POWER_DBM, 17) - 2))

        # Gain LNA automatique
        self._write(REG_LNA, 0x23)

        # Modem config : BW=125kHz CR=4/5
        bw_idx = {7800: 0, 10400: 1, 15600: 2, 20800: 3,
                  31250: 4, 41700: 5, 62500: 6, 125000: 7,
                  250000: 8, 500000: 9}.get(BANDWIDTH, 7)
        self._write(REG_MODEM_CONFIG1, (bw_idx << 4) | (1 << 1) | 0)
        self._write(REG_MODEM_CONFIG2, (SPREADING_FACTOR << 4) | (1 << 2))
        self._write(REG_MODEM_CONFIG3, 0x04)

        # Préambule = 8 symboles
        self._write(REG_PREAMBLE_MSB, 0x00)
        self._write(REG_PREAMBLE_LSB, 0x08)

        # Sync word SOS-GUIDE (0x39 = custom, distingue notre réseau)
        self._write(REG_SYNC_WORD, 0x39)

        # FIFO
        self._write(REG_FIFO_TX_BASE, 0x00)
        self._write(REG_FIFO_RX_BASE, 0x00)

        # Mode veille
        self._write(REG_OP_MODE, MODE_STDBY | MODE_LORA)

    def send(self, data: bytes) -> bool:
        if not self._ready:
            return False
        if len(data) > 255:
            log.warning("Trame trop longue (%d bytes > 255)", len(data))
            return False
        self._write(REG_OP_MODE, MODE_STDBY | MODE_LORA)
        self._write(REG_FIFO_ADDR_PTR, 0x00)
        self._write_buf(REG_FIFO, data)
        self._write(REG_PAYLOAD_LENGTH, len(data))
        self._write(REG_OP_MODE, MODE_TX | MODE_LORA)

        # Attente TX done (timeout 5s)
        for _ in range(50):
            time.sleep(0.1)
            if self._read(REG_IRQ_FLAGS) & IRQ_TX_DONE:
                self._write(REG_IRQ_FLAGS, IRQ_TX_DONE)
                self._write(REG_OP_MODE, MODE_STDBY | MODE_LORA)
                return True
        log.error("TX timeout")
        return False

    def receive_once(self) -> Optional[bytes]:
        """Tente de recevoir un paquet (non bloquant, timeout 200ms)."""
        if not self._ready:
            return None
        self._write(REG_OP_MODE, MODE_RX_CONT | MODE_LORA)
        for _ in range(20):
            time.sleep(0.01)
            flags = self._read(REG_IRQ_FLAGS)
            if flags & IRQ_RX_DONE:
                self._write(REG_IRQ_FLAGS, 0xFF)
                if flags & IRQ_CRC_ERROR:
                    log.debug("CRC error sur paquet reçu")
                    return None
                nb    = self._read(REG_RX_NB_BYTES)
                start = self._read(REG_FIFO_RX_CURRENT)
                self._write(REG_FIFO_ADDR_PTR, start)
                data = self._read_buf(REG_FIFO, nb)
                rssi = self._read(REG_PKT_RSSI_VALUE) - 157
                snr  = struct.unpack('b', bytes([self._read(REG_PKT_SNR_VALUE)]))[0] / 4
                log.debug("RX %d bytes RSSI=%d SNR=%.1f", nb, rssi, snr)
                return bytes(data)
        self._write(REG_OP_MODE, MODE_STDBY | MODE_LORA)
        return None

    def cleanup(self) -> None:
        if self._spi:
            self._write(REG_OP_MODE, MODE_SLEEP | MODE_LORA)
            self._spi.close()
        if LORA_HW_OK:
            GPIO.cleanup()


# ══════════════════════════════════════════════════════════════════════════════
# MESH STORE-AND-FORWARD
# ══════════════════════════════════════════════════════════════════════════════
class LoRaMesh:
    """
    Gestionnaire de messages mesh.
    Déduplication par message_id + TTL décrémenté à chaque relais.
    """

    def __init__(self, crypto: LoRaCrypto, radio: SX1276, node_id: str) -> None:
        self._crypto    = crypto
        self._radio     = radio
        self._node_id   = node_id
        self._seen: dict[str, float] = {}     # msg_id → timestamp
        self._store: deque = deque(maxlen=MAX_STORE)
        self._lock      = threading.Lock()
        self._tx_queue: deque = deque(maxlen=100)

    def _purge_seen(self) -> None:
        now = time.time()
        expired = [k for k, ts in self._seen.items() if now - ts > DEDUP_WINDOW]
        for k in expired:
            del self._seen[k]

    def send_message(self, body: str, msg_type: str = 'msg') -> dict:
        """Envoie un nouveau message sur le réseau mesh."""
        if len(body.encode()) > 200:
            body = body[:200]
        payload = {
            'id':   secrets.token_hex(4),
            'src':  self._node_id,
            'ttl':  TTL_DEFAULT,
            'ts':   int(time.time()),
            'type': msg_type,
            'body': body,
        }
        frame = self._crypto.encrypt(payload)
        ok = self._radio.send(frame)
        if ok:
            with self._lock:
                self._seen[payload['id']] = time.time()
                self._store.appendleft({**payload, 'local': True, 'relayed': False})
            log.info("TX [%s] type=%s body=%r", payload['id'], msg_type, body[:40])
        else:
            log.warning("TX échoué pour msg [%s]", payload['id'])
            # Stocker quand même pour affichage local
            with self._lock:
                self._store.appendleft({**payload, 'local': True, 'relayed': False, 'tx_failed': True})
        return {'success': ok, 'id': payload['id']}

    def receive_loop(self) -> None:
        """Boucle de réception (thread dédié)."""
        log.info("Boucle RX démarrée — écoute sur %.1f MHz", FREQ_HZ / 1e6)
        while True:
            try:
                raw = self._radio.receive_once()
                if raw is None:
                    time.sleep(0.05)
                    continue
                payload = self._crypto.decrypt(raw)
                if payload is None:
                    log.debug("Paquet reçu non déchiffrable (réseau différent ou corrompu)")
                    continue
                msg_id = payload.get('id', '')
                with self._lock:
                    self._purge_seen()
                    if msg_id in self._seen:
                        log.debug("Duplicate ignoré [%s]", msg_id)
                        continue
                    self._seen[msg_id] = time.time()
                    payload['received_at'] = int(time.time())
                    self._store.appendleft({**payload, 'local': False, 'relayed': False})
                log.info("RX [%s] src=%s type=%s body=%r",
                         msg_id, payload.get('src'), payload.get('type'),
                         str(payload.get('body', ''))[:40])

                # Relais mesh : décrémenter TTL et retransmettre
                ttl = int(payload.get('ttl', 0))
                if ttl > 1:
                    payload['ttl'] = ttl - 1
                    relay_frame = self._crypto.encrypt(payload)
                    # Délai aléatoire pour éviter les collisions (CSMA naïf)
                    delay = secrets.randbelow(500) / 1000.0
                    time.sleep(delay)
                    if self._radio.send(relay_frame):
                        with self._lock:
                            # Marquer comme relayé dans le store
                            for m in self._store:
                                if m.get('id') == msg_id:
                                    m['relayed'] = True
                                    break
                        log.info("RELAY [%s] TTL restant=%d", msg_id, payload['ttl'])

            except Exception as e:
                log.error("Erreur boucle RX : %s", e)
                time.sleep(1)

    def get_messages(self, since: int = 0, limit: int = 50) -> list:
        with self._lock:
            msgs = [m for m in self._store if m.get('ts', 0) >= since]
        return msgs[:limit]

    def get_stats(self) -> dict:
        with self._lock:
            total    = len(self._store)
            local    = sum(1 for m in self._store if m.get('local'))
            received = sum(1 for m in self._store if not m.get('local'))
            relayed  = sum(1 for m in self._store if m.get('relayed'))
        return {
            'node_id':    self._node_id,
            'freq_mhz':   FREQ_HZ / 1e6,
            'sf':         SPREADING_FACTOR,
            'bw_khz':     BANDWIDTH // 1000,
            'tx_power':   TX_POWER_DBM,
            'hw_ready':   self._radio._ready if self._radio else False,
            'total_msgs': total,
            'local_sent': local,
            'received':   received,
            'relayed':    relayed,
            'store_max':  MAX_STORE,
            'uptime':     int(time.time() - START_TIME),
        }


# ══════════════════════════════════════════════════════════════════════════════
# API REST (Flask — écoute sur 127.0.0.1:8765)
# Accessible uniquement depuis localhost (nginx proxy si nécessaire)
# ══════════════════════════════════════════════════════════════════════════════
def build_api(mesh: LoRaMesh) -> 'Flask':
    app = Flask('lora-service')
    app.config['JSON_ENSURE_ASCII'] = False

    @app.route('/health', methods=['GET'])
    def health():
        return jsonify({'status': 'ok', 'ts': int(time.time())}), 200

    @app.route('/stats', methods=['GET'])
    def stats():
        return jsonify(mesh.get_stats()), 200

    @app.route('/messages', methods=['GET'])
    def messages():
        since = int(request.args.get('since', 0))
        limit = min(int(request.args.get('limit', 50)), 200)
        msgs  = mesh.get_messages(since=since, limit=limit)
        return jsonify({'messages': msgs, 'count': len(msgs)}), 200

    @app.route('/send', methods=['POST'])
    def send():
        data = request.get_json(silent=True) or {}
        body = str(data.get('body', '')).strip()
        if not body:
            return jsonify({'success': False, 'error': 'body requis'}), 400
        if len(body) > 200:
            return jsonify({'success': False, 'error': 'body trop long (max 200)'}), 400
        msg_type = data.get('type', 'msg')
        if msg_type not in ('msg', 'alert', 'heartbeat'):
            msg_type = 'msg'
        result = mesh.send_message(body, msg_type)
        return jsonify(result), 200 if result['success'] else 503

    @app.route('/alert', methods=['POST'])
    def alert():
        """Shortcut pour envoyer une alerte prioritaire."""
        data = request.get_json(silent=True) or {}
        body = str(data.get('body', '🚨 ALERTE')).strip()
        result = mesh.send_message(body, 'alert')
        return jsonify(result), 200 if result['success'] else 503

    return app


# ══════════════════════════════════════════════════════════════════════════════
# HEARTBEAT (annonce périodique du nœud)
# ══════════════════════════════════════════════════════════════════════════════
def heartbeat_loop(mesh: LoRaMesh) -> None:
    """Diffuse une annonce de présence toutes les 5 minutes."""
    while True:
        time.sleep(300)
        try:
            config = {}
            if os.path.exists(CONFIG_FILE):
                with open(CONFIG_FILE) as f:
                    config = json.load(f)
            name = config.get('establishment', {}).get('name', 'SOS-GUIDE')
            mesh.send_message(f"HB:{name[:32]}", 'heartbeat')
        except Exception as e:
            log.debug("Heartbeat erreur : %s", e)


# ══════════════════════════════════════════════════════════════════════════════
# POINT D'ENTRÉE
# ══════════════════════════════════════════════════════════════════════════════
START_TIME = time.time()


def main() -> None:
    log.info("SOS-GUIDE lora-service v2.2 — démarrage")

    if not CRYPTO_OK:
        log.critical("cryptography non installé : pip3 install cryptography")
        sys.exit(1)
    if not FLASK_OK:
        log.critical("Flask non installé : pip3 install flask")
        sys.exit(1)

    # Clé AES-256
    ensure_key_file()
    aes_key = derive_aes_key()
    crypto  = LoRaCrypto(aes_key)
    node_id = get_node_id()
    log.info("Node ID : %s", node_id)

    # Radio
    radio = SX1276()
    if not radio._ready:
        log.warning("Hardware LoRa non disponible — mode simulation (messages locaux uniquement)")

    # Mesh
    mesh = LoRaMesh(crypto, radio, node_id)

    # Thread RX
    rx_thread = threading.Thread(target=mesh.receive_loop, daemon=True, name='lora-rx')
    rx_thread.start()

    # Thread heartbeat
    hb_thread = threading.Thread(target=heartbeat_loop, args=(mesh,), daemon=True, name='lora-hb')
    hb_thread.start()

    # API REST
    app = build_api(mesh)
    log.info("API REST démarrée sur http://%s:%d", API_HOST, API_PORT)
    try:
        app.run(host=API_HOST, port=API_PORT, debug=False, threaded=True)
    except KeyboardInterrupt:
        log.info("Arrêt demandé")
    finally:
        radio.cleanup()


if __name__ == '__main__':
    main()
