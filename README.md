# ⛑️ SOS-GUIDE v2.3

**Système de communication d'urgence hors ligne — Raspberry Pi · WiFi captif · LoRa mesh · Multi-langues**

[![Version](https://img.shields.io/badge/version-2.3-blue)](#)
[![Licence](https://img.shields.io/badge/licence-MIT-green)](#licence)
[![Conformité](https://img.shields.io/badge/conformité-nLPD%20RS%20235.1-purple)](#confidentialité)
[![Plateforme](https://img.shields.io/badge/plateforme-RPi%204%20%7C%205-red)](#matériel)

---

## 🎯 Objectif

SOS-GUIDE transforme un Raspberry Pi en **point d'accès WiFi autonome et hors ligne** qui diffuse
des guides de survie multilingues, des contacts d'urgence locaux et un réseau de messagerie chiffré
(LoRa mesh) — **sans Internet, sans infrastructure, sans reboot**.

Conçu pour : séismes, inondations, coupures de courant, cyberattaques, événements NRBC,
attentats, incidents en milieu isolé.

---

## 🗂️ Structure du dépôt

```
PROTOTYPE/
├── build-image.sh              ← Pipeline de génération de l'image .img.gz (pi-gen + Docker)
├── install.sh                  ← Finalisation manuelle (mode STARTER → PRODUCTION)
├── sos-guide-update.sh         ← Mise à jour automatique des contenus JSON via ETH
├── sos-guide-test.sh           ← Suite de tests d'intégration (rapport JSON)
├── PRIVACY.md                  ← Politique de confidentialité (nLPD RS 235.1 / RGPD)
│
├── firstboot/                  ← Exécutés au 1er démarrage (mode STARTER)
│   ├── firstboot.sh            ← Service systemd oneshot — configure le point d'accès STARTER
│   ├── finalize_install.sh     ← Transition STARTER → PRODUCTION après configuration
│   ├── api_install.php         ← API REST du formulaire firstboot (CSRF + rate-limit)
│   ├── starter.html            ← Page de configuration firstboot (formulaire + PIN)
│   ├── sos-guide-firstboot.service
│   ├── sos-guide-health.service
│   └── sos-guide-health.time   ←
│
├── scripts/
│   ├── lora-service.py         ← Service LoRa mesh (SX1276 SPI + RAK UART, AES-256-GCM)
│   ├── sos-guide-boot-check.sh ← Vérification SHA256 d'intégrité (lancé par le timer)
│   └── sos-guide-regen-hash.sh ← Régénération du fichier integrity.hash
│
├── systemd/
│   ├── sos-guide-firstboot.service
│   ├── sos-guide-update.service
│   ├── sos-guide-update.timer  ← Mise à jour automatique (si ETH connecté)
│   └── lora-service.service
│
└── web/                        ← Racine nginx /var/www/sos-guide/
    ├── index.html              ← Portail captif multilingue (29 langues)
    ├── admin.php               ← Interface d'administration (protégée htpasswd)
    ├── update_config.php       ← Écriture atomique de config.json
    ├── api_reload_network_proxy.php  ← Proxy CSRF-protégé → /api/reload-network
    └── lora-portal.php         ← Interface messagerie LoRa
```

---

## 🔄 Cycle de vie d'un nœud

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│  [Image .img flashée]                                                       │
│         │                                                                   │
│         ▼                                                                   │
│  ┌─────────────┐   Connexion WiFi      ┌───────────────────────────────┐  │
│  │   STARTER   │ ──"⛑️ SOS-GUIDE-STARTER"──▶  http://10.0.0.1/         │  │
│  │  firstboot  │   PIN affiché HDMI    │  Formulaire de configuration  │  │
│  └─────────────┘                       │  (nom, contacts, WiFi, LoRa)  │  │
│         │                              └───────────────────────────────┘  │
│         │  POST /api/install (CSRF + PIN)                                  │
│         ▼                                                                   │
│  ┌─────────────┐                       ┌───────────────────────────────┐  │
│  │ PRODUCTION  │ ──"⛑️ SOS-GUIDE-Mairie"──▶  Portail captif (29 langues)│  │
│  │  en ligne   │   WPA2 (optionnel)    │  Guides · Contacts · LoRa     │  │
│  └─────────────┘                       └───────────────────────────────┘  │
│         │                                                                   │
│         │  http://10.0.0.1/admin  (htpasswd)                              │
│         ▼                                                                   │
│  Modification config → Reload à chaud (nginx + dnsmasq + hostapd, ~3s)   │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 🛠️ Matériel requis

| Composant | Minimum | Recommandé |
|-----------|---------|------------|
| Raspberry Pi | RPi 4 Model B (2 Go RAM) | RPi 5 (4 Go RAM) |
| Carte microSD | 8 Go Classe A1 | 32 Go Classe A2 |
| Alimentation | 5 V / 3 A USB-C | Batterie 20 000 mAh + câble |
| Module LoRa | SX1276 / RFM95W (SPI) | RAK3172 UART (plus stable) |
| Antenne LoRa | 868 MHz 2 dBi | 868 MHz 5 dBi (portée +50 %) |
| Câble Ethernet | — | Requis pour mises à jour JSON |

> **Sans module LoRa** : le système fonctionne en mode WiFi seul — LoRa est optionnel.

---

## 🏗️ Construire l'image `.img`

### Prérequis

```bash
sudo apt install docker.io git gpg sha256sum
sudo usermod -aG docker $USER   # puis se reconnecter
```

### Génération

```bash
git clone https://github.com/sos-guide/PROTOTYPE.git
cd PROTOTYPE

# RPi 4 — variante Suisse (défaut)
bash build-image.sh

# RPi 5 — avec signature GPG
bash build-image.sh --rpi5 --sign

# Options disponibles
bash build-image.sh --help
```

L'image est générée dans `releases/` (~30–60 min) :

```
releases/
├── sos-guide-v2.3-ch-rpi4.img.gz      ← Image à flasher
├── sos-guide-v2.3-ch-rpi4.sha256      ← Empreinte d'intégrité
├── sos-guide-v2.3-ch-rpi4.asc         ← Signature GPG (si --sign)
└── sos-guide-v2.3-ch-rpi4-credentials.txt  ← ⚠️ MOT DE PASSE SSH pi (confidentiel)
```

### Flasher

```bash
# Raspberry Pi Imager (recommandé)
# → "Utiliser une image personnalisée" → sos-guide-v2.3-*.img.gz

# CLI
sudo dd if=<(gunzip -c sos-guide-v2.3-ch-rpi4.img.gz) \
    of=/dev/sdX bs=4M status=progress conv=fsync
```

---

## 🚀 Premier démarrage (mode STARTER)

1. **Insérer la microSD** dans le Raspberry Pi et alimenter.
2. **Connexion WiFi** : rejoindre le réseau `⛑️ SOS-GUIDE - STARTER`
3. **Ouvrir un navigateur** → `http://10.0.0.1/` (portail captif)
4. **Entrer le PIN à 6 chiffres** affiché sur l'écran HDMI connecté au Pi
5. **Remplir le formulaire** : nom du lieu, contacts d'urgence, canal WiFi, LoRa
6. **Valider** → Le Pi bascule en mode PRODUCTION sans reboot (~10 s)

> **Accès de secours via Ethernet** (si le WiFi ne s'affiche pas) :
> ```bash
> ssh pi@<IP-ETH>   # mot de passe dans releases/*-credentials.txt
> sudo bash /boot/firmware/firstboot/finalize_install.sh
> ```

---

## ⚙️ Installation manuelle (sans image)

Sur un Raspberry Pi OS Bookworm Lite existant :

```bash
# Copier les fichiers du dépôt sur le Pi
scp -r PROTOTYPE/ pi@<IP-PI>:/tmp/sos/

# Sur le Pi
ssh pi@<IP-PI>

# Créer la config initiale
sudo mkdir -p /var/www/sos-guide/data
sudo cp /tmp/sos/web/* /var/www/sos-guide/
sudo tee /var/www/sos-guide/data/config.json <<'JSON'
{
  "establishment": { "name": "Mon Lieu", "address": "", "lat": "", "lon": "" },
  "wifiChannel": 11,
  "wifiPassword": "",
  "enableLoRa": false,
  "enableEthernet": false
}
JSON

# Lancer la finalisation
sudo bash /tmp/sos/install.sh
```

Le mot de passe admin généré est affiché à l'écran et sauvegardé dans `/var/lib/sos-guide/installed`.

---

## 🔒 Administration (mode PRODUCTION)

| Accès | URL | Auth |
|-------|-----|------|
| Portail captif | `http://10.0.0.1/` | Aucune |
| Administration | `http://10.0.0.1/admin` | `admin` / mot de passe généré |
| SSH de secours | `ssh pi@<IP-ETH>` | Mot de passe dans `*-credentials.txt` |

### Reload à chaud (sans reboot)

Depuis `/admin`, bouton **"Reload services"** :
- `nginx -s reload` — zéro downtime
- `systemctl reload dnsmasq` — baux DHCP conservés
- `systemctl restart hostapd` — ~3 s d'interruption WiFi (uniquement si SSID/WPA changé)

Depuis SSH :
```bash
sudo systemctl reload nginx
sudo systemctl reload dnsmasq
sudo systemctl restart hostapd   # si WiFi modifié
```

---

## 📡 LoRa Mesh

| Paramètre | Valeur |
|-----------|--------|
| Fréquence | 868.1 MHz (EU868) |
| Chiffrement | AES-256-GCM |
| Portée typ. | 2–5 km (ville), 5–15 km (campagne) |
| Modules supportés | SX1276/SX1278 via SPI · RAK3172/RAK811 via UART |
| API locale | `http://127.0.0.1:8765/` |

Activation : cocher **"Activer LoRa"** dans `/admin` → Reload services.

---

## 🔄 Mise à jour des contenus

Si un câble Ethernet est connecté et que le nœud a accès à Internet :

```bash
# Vérifier si une mise à jour est disponible
sudo bash /usr/local/bin/sos-guide-update.sh check

# Installer manuellement
sudo bash /usr/local/bin/sos-guide-update.sh

# Automatique (timer systemd toutes les 6h)
sudo systemctl enable --now sos-guide-update.timer
```

Les fichiers PHP/HTML restent **verrouillés** (`chattr +i`). Seuls les JSON de langue sont mis à jour.
`config.json` n'est **jamais écrasé**.

---

## 🧪 Tests d'intégration

```bash
# Tests rapides
sudo bash sos-guide-test.sh

# Tests complets avec performance (ab)
sudo bash sos-guide-test.sh --full

# Rapport JSON exploitable en CI/CD
sudo bash sos-guide-test.sh --json /tmp/rapport.json
```

Les tests vérifient : services actifs · isolation réseau · hash SHA256 · portail captif ·
sécurité admin · fichiers de langue · LoRa · rate-limit · chattr.

---

## 🔒 Sécurité & Confidentialité

| Mécanisme | Détail |
|-----------|--------|
| Isolation réseau | `iptables FORWARD DROP` — aucun paquet WiFi ne sort |
| Isolation clients | `hostapd ap_isolate=1` — clients ne se voient pas |
| Intégrité fichiers | `chattr +i` + SHA256 toutes les 5 min |
| CSRF | Token de session one-shot (api_install.php + admin.php) |
| Rate-limit firstboot | 5 tentatives / 15 min par IP |
| PIN firstboot | 6 chiffres, affiché uniquement sur console HDMI physique |
| Admin web | HTTP Basic Auth (`/etc/nginx/.htpasswd`, généré automatiquement) |
| LoRa | AES-256-GCM, clé unique par déploiement |
| Logs | Mémoire volatile (tmpfs) — effacés au redémarrage |
| IPv6 | Désactivé globalement |
| Watchdog | Redémarrage matériel si plantage système |

> Ce système ne collecte **aucune donnée personnelle persistante**.
> Voir [PRIVACY.md](PRIVACY.md) — conforme **nLPD RS 235.1** et **RGPD**.

---

## 🌍 Langues supportées

29 langues disponibles via mise à jour JSON :
FR · EN · DE · IT · ES · PT · AR · ZH · JA · KO · RU · UK · PL · NL · SV · NO · DA · FI
· HU · RO · CS · SK · HR · BG · EL · TR · FA · HI · RM (Romanche)

---

## 📋 Variables de `config.json`

| Clé | Type | Description |
|-----|------|-------------|
| `establishment.name` | string | Nom du lieu / identifiant du nœud |
| `establishment.address` | string | Adresse complète |
| `establishment.lat` / `lon` | string | Coordonnées GPS |
| `establishment.type` | string | `erp`, `ecole`, `hopital`, `mairie`… |
| `establishment.localCrisisNumber` | string | Numéro cellule de crise locale |
| `wifiChannel` | int | Canal WiFi 1–13 (EU : 1, 6 ou 11) |
| `wifiPassword` | string | Mot de passe WPA2 (vide = réseau ouvert) |
| `enableLoRa` | bool | Activer le service lora-service.py |
| `enableEthernet` | bool | Activer l'interface ETH (mises à jour) |
| `reassurance.message` | string | Message affiché sur le portail |

---

## 🤝 Contribuer

```bash
git clone https://github.com/sos-guide/PROTOTYPE.git
cd PROTOTYPE
git checkout -b feature/ma-contribution
# ... modifications ...
git commit -m "feat: description claire"
git push origin feature/ma-contribution
# → Ouvrir une Pull Request
```

**Avant de soumettre :**
```bash
# Vérifier les scripts bash
shellcheck install.sh build-image.sh sos-guide-update.sh sos-guide-test.sh

# Valider les JSON
python3 -m json.tool web/data/config.json

# Lancer les tests
sudo bash sos-guide-test.sh
```

---

## 📄 Licence

MIT — voir [LICENSE](LICENSE)

Copyright © 2024–2026 Ludovic MARTIN · [contact@sos-guide.fr](mailto:contact@sos-guide.fr)

---

> **⚠️ Ce système est conçu pour fonctionner déconnecté d'Internet.**
> Il ne transmet aucune donnée vers l'extérieur et est protégé contre les accès non autorisés.
> Destiné à un usage humanitaire, de sécurité civile et de protection des populations.
