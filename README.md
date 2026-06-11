# ⛑️ SOS-GUIDE v2.5

**Système de communication d'urgence hors ligne — Raspberry Pi · WiFi captif · LoRa mesh · Multi-langues**

[![Version](https://img.shields.io/badge/version-2.5-blue)](#)
[![Licence](https://img.shields.io/badge/licence-EUPL--1.2-green)](#licence)
[![Conformité](https://img.shields.io/badge/conformité-nLPD%20RS%20235.1-purple)](#confidentialité)
[![Plateforme](https://img.shields.io/badge/plateforme-RPi%204%20%7C%205-red)](#matériel)

---

## 🎯 Objectif

SOS-GUIDE transforme un Raspberry Pi en **point d'accès WiFi autonome et hors ligne** qui diffuse
des guides de survie multilingues, des contacts d'urgence locaux et un réseau de messagerie chiffré
(LoRa mesh) — **sans Internet, sans infrastructure, sans reboot, sans écran HDMI**.

Conçu pour : séismes, inondations, coupures de courant, cyberattaques, événements NRBC,
attentats, incidents en milieu isolé, bunkers de protection civile.

---

## 🆕 Nouveautés v2.5

- **Installation 100 % hors ligne** — bundle de dépendances `offline-deps-*.tar.gz` (tous les `.deb` embarqués)
- **Environnement de développement** — Docker local + mode dev sur Pi avec synchro temps réel (voir [Développement](#-développement))
- **Cartes hors ligne** — tuiles OpenStreetMap pré-téléchargées autour du lieu configuré
- **Watchdog matériel** + retour usine (`sos-guide-reset-starter.sh`) + TLS optionnel
- **CI GitHub Actions** — shellcheck, validation JSON et lint PHP sur chaque push

> Historique complet des versions : [CHANGELOG.md](CHANGELOG.md)

---

## 🗂️ Structure du dépôt

```
SOS-GUIDE/
├── install.sh                  ← Déploiement + finalisation (STARTER → PRODUCTION)
├── LICENSE
├── VERSION
├── README.md
├── CHANGELOG.md                ← Historique des versions (Keep a Changelog)
├── PRIVACY.md                  ← Politique confidentialité (nLPD RS 235.1 / RGPD)
├── docker-compose.yml          ← Environnement de dev local (port 8080)
├── docker/                     ← Dockerfile + nginx/supervisord de dev
├── offline-deps-*.tar.gz       ← Bundle .deb pour installation sans Internet
│
├── .github/workflows/ci.yml    ← CI : shellcheck · JSON · lint PHP
│
└── src/
    ├── firstboot/              ← Exécutés au 1er démarrage (mode STARTER)
    │   ├── firstboot.sh        ← Génère réseau STARTER ouvert + QR code (sans PIN HDMI)
    │   ├── finalize_install.sh ← Transition STARTER → PRODUCTION sans reboot
    │   ├── api_install.php     ← API REST firstboot (CSRF + rate-limit)
    │   ├── starter.html        ← Page config firstboot avec QR code WiFi
    │   ├── qrcode.min.js
    │   ├── sos-guide-health.service
    │   └── sos-guide-health.timer
    │
    ├── dev/                    ← Outils dev uniquement (jamais en production)
    │   ├── dev-router.php      ← Route STARTER ou PRODUCTION selon /tmp/sos-guide/dev-mode
    │   └── dev-switch.php      ← POST /dev-switch : bascule de mode depuis le navigateur
    │
    ├── scripts/
    │   ├── build-image.sh      ← Pipeline génération image .img.gz (pi-gen + Docker)
    │   ├── build-offline-bundle.sh  ← Génère offline-deps-*.tar.gz (sur Pi connecté)
    │   ├── dev-setup-pi.sh     ← Configure un Pi en mode dev (sans AP)
    │   ├── sync.sh             ← Synchro temps réel src/ → Pi (inotify / polling)
    │   ├── lora-service.py     ← Service LoRa mesh (SX1276 SPI, AES-256-GCM)
    │   ├── sos_keypair_gen.py  ← Génération clé AES-256 LoRa
    │   ├── sos-guide-boot-check.sh  ← Vérif SHA256 — mode dégradé
    │   ├── sos-guide-regen-hash.sh  ← Régénération integrity.hash
    │   ├── sos-guide-fetch-tiles.sh ← Téléchargement tuiles OSM hors ligne
    │   ├── sos-guide-reset-starter.sh ← Retour usine (mode STARTER)
    │   ├── sos-guide-test.sh        ← Suite tests d'intégration (rapport JSON)
    │   ├── sos-guide-tls-setup.sh   ← Configuration certificat TLS
    │   ├── sos-guide-update.sh      ← Mise à jour automatique contenus JSON via ETH
    │   └── sos-guide-watchdog-test.sh ← Sonde applicative watchdog matériel
    │
    ├── systemd/
    │   ├── lora-service.service
    │   ├── sos-guide-firstboot.service
    │   ├── sos-guide-update.service / .timer
    │   ├── sos-guide-health.service / .timer
    │   ├── sos-guide-logs.conf      ← Logs en tmpfs (volatils)
    │   └── {hostapd,dnsmasq,nginx}.service.d/sos-guide-restart.conf
    │
    └── web/                    ← Racine nginx /var/www/sos-guide/
        ├── index.html          ← Portail captif multilingue (29 langues)
        ├── admin.php           ← Interface admin
        ├── update_config.php   ← Écriture atomique + backup .bak
        ├── api_reload_network_proxy.php
        ├── lora-portal.php
        ├── lib/
        │   └── whitelist.php   ← Whitelist IP partagée (WiFi AP + ETH)
        └── data/
            ├── config.json
            └── *.json          ← Fichiers de langue (29 langues)
```

---

## 🔄 Cycle de vie d'un nœud

```
┌─────────────────────────────────────────────────────────────────────────┐
│                                                                         │
│  [Image .img flashée sur carte SD]                                      │
│         │                                                               │
│         ▼                                                               │
│  ┌─────────────┐   WiFi STARTER (ouvert)    ┌─────────────────────┐   │
│  │   STARTER   │ ── "⛑️ SOS-GUIDE - STARTER" ─▶ http://10.0.0.1/  │   │
│  │  firstboot  │   Réseau ouvert, sans mdp   │  Assistant config   │   │
│  │  (1er boot) │   Connexion via QR code     │  Nom · Contacts     │   │
│  └─────────────┘                             │  WiFi · LoRa        │   │
│         │                                    └─────────────────────┘   │
│         │  POST /api/install (CSRF — sans PIN)                         │
│         ▼                                                               │
│  ┌─────────────┐                             ┌─────────────────────┐   │
│  │ PRODUCTION  │ ── "⛑️ SOS-GUIDE - Mairie" ──▶ Portail captif     │   │
│  │  en ligne   │   WiFi configuré            │  29 langues · offline│  │
│  └─────────────┘                             └─────────────────────┘   │
│         │                                                               │
│         │  http://10.0.0.1/admin  (htpasswd)                          │
│         ▼                                                               │
│  Modification config → Reload chaud (nginx + dnsmasq + hostapd, ~3s)  │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 🛠️ Matériel requis

| Composant | Minimum | Recommandé |
|-----------|---------|------------|
| Raspberry Pi | RPi 4 Model B (2 Go RAM) | RPi 5 (4 Go RAM) |
| Carte microSD | 8 Go Classe A1 | 32 Go Classe A2 |
| Alimentation | 5 V / 3 A USB-C | Batterie 20 000 mAh |
| Module LoRa | SX1276 / RFM95W (SPI) | RAK3172 UART |
| Antenne LoRa | 868 MHz 2 dBi | 868 MHz 5 dBi |

> **Sans module LoRa** : le système fonctionne en mode WiFi seul — LoRa est optionnel.
> **Sans écran HDMI** : configuration 100% via WiFi depuis v2.4.

---

## 🏗️ Construire l'image `.img`

### Prérequis

```bash
sudo apt install docker.io git gpg sha256sum
sudo usermod -aG docker $USER   # puis se reconnecter
```

### Génération

```bash
git clone https://github.com/sos-guide/SOS-GUIDE.git
cd SOS-GUIDE

# RPi 4 — variante Suisse (défaut)
bash src/scripts/build-image.sh

# RPi 5 — avec signature GPG
bash src/scripts/build-image.sh --rpi5 --sign
```

L'image est générée dans `releases/` (~30–60 min) :

```
releases/
├── sos-guide-v2.5-ch-rpi4.img.gz        ← Image à flasher
├── sos-guide-v2.5-ch-rpi4.sha256        ← Empreinte SHA256
├── sos-guide-v2.5-ch-rpi4.asc           ← Signature GPG (si --sign)
└── sos-guide-v2.5-ch-rpi4-credentials.txt  ← ⚠️ Mot de passe SSH pi
```

### Flasher

```bash
# Raspberry Pi Imager (recommandé)
# → "Utiliser une image personnalisée" → sos-guide-v2.5-*.img.gz

# CLI
sudo dd if=<(gunzip -c sos-guide-v2.5-ch-rpi4.img.gz) \
    of=/dev/sdX bs=4M status=progress conv=fsync
```

---

## 🚀 Premier démarrage — 100% WiFi, sans écran HDMI

> **v2.4 : le PIN HDMI est supprimé.** Toute la configuration se fait via WiFi.

### Étapes

1. **Insérer la microSD** dans le Raspberry Pi et alimenter.

2. **Rejoindre le réseau WiFi** : `⛑️ SOS-GUIDE - STARTER`
   - Le réseau est **ouvert** — aucun mot de passe requis.

3. **Ouvrir un navigateur** → `http://10.0.0.1/`

4. **Remplir l'assistant** : nom du lieu, contacts d'urgence locaux, canal WiFi, LoRa.

5. **Valider** → Le Pi bascule en mode **PRODUCTION sans reboot** (~30 s).

### Accès de secours via Ethernet

Si le WiFi STARTER ne démarre pas (rare) :

```bash
# Connecter un câble Ethernet
# Trouver l'IP du Pi sur le réseau local (box, DHCP)
ssh pi@<IP-ETH>
# Mot de passe dans releases/*-credentials.txt

# Relancer manuellement
sudo bash /boot/firmware/firstboot/finalize_install.sh
```

---

## ⚙️ Installation manuelle (sans image)

Sur un Raspberry Pi OS Bookworm Lite existant :

```bash
# Copier le dépôt sur le Pi
scp -r SOS-GUIDE/ pi@<IP-PI>:/tmp/sos/

# Sur le Pi
ssh pi@<IP-PI>

# Créer la config initiale
sudo mkdir -p /var/www/sos-guide/data
sudo tee /var/www/sos-guide/data/config.json <<'JSON'
{
  "establishment": { "name": "Mon Lieu", "address": "" },
  "wifiChannel": 11,
  "wifiPassword": "",
  "enableLoRa": false,
  "enableEthernet": false,
  "installed": false
}
JSON

# Déployer les sources et finaliser (une seule commande)
sudo bash /tmp/sos/install.sh
```

`install.sh` détecte `src/` automatiquement et déploie les fichiers web,
les scripts et les unités systemd avant de configurer le système.

---

## 🔒 Administration (mode PRODUCTION)

| Accès | URL | Auth |
|-------|-----|------|
| Portail captif | `http://10.0.0.1/` | Aucune |
| Administration | `http://10.0.0.1/admin` | `admin` / mot de passe généré |
| SSH de secours | `ssh pi@<IP-ETH>` | Mot de passe dans `*-credentials.txt` |

### Reload à chaud (sans reboot)

Depuis `/admin`, boutons **"Reload services"** et **"Reload WiFi"** :

```
Reload services : nginx (zero-downtime) + dnsmasq (baux conservés)
Reload WiFi     : + hostapd restart (~3s d'interruption)
```

Depuis SSH :
```bash
sudo systemctl reload nginx
sudo systemctl reload dnsmasq
sudo systemctl restart hostapd   # uniquement si SSID/WPA/canal changé
```

### Numéros d'urgence locaux

Les numéros affichés sur le portail sont **prioritairement ceux de `config.json`**.
Si un champ est vide, le numéro par défaut de la langue sélectionnée est affiché.

Champs disponibles dans `/admin` → section **Contacts** :
- `localSamuNumber` — remplace le numéro ambulance de la langue
- `localPoliceNumber` — remplace le numéro police de la langue *(nouveau v2.4)*
- `localPompiersNumber` — remplace le numéro pompiers de la langue
- `localCrisisNumber` — numéro cellule de crise locale (affiché en plus)

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

Si un câble Ethernet est connecté et que `enableEthernet=true` :

```bash
# Vérifier si une mise à jour est disponible
sudo bash /usr/local/bin/sos-guide-update.sh check

# Installer manuellement
sudo bash /usr/local/bin/sos-guide-update.sh

# Automatique (timer toutes les 6h)
sudo systemctl enable --now sos-guide-update.timer
```

`config.json` n'est **jamais écrasé** lors des mises à jour de contenu.

---

## 🧪 Tests d'intégration

```bash
# Tests rapides
sudo bash src/scripts/sos-guide-test.sh

# Tests complets avec performance
sudo bash src/scripts/sos-guide-test.sh --full

# Avec rapport JSON
sudo bash src/scripts/sos-guide-test.sh --report
```

Les tests vérifient : services actifs · isolation réseau · hash SHA256 ·
portail captif · sécurité admin · 29 fichiers de langue · LoRa · réseau STARTER ouvert.

---

## 🔒 Sécurité & Confidentialité

| Mécanisme | Détail |
|-----------|--------|
| WiFi ouvert | Aucun mot de passe — accès immédiat pour les secouristes |
| Isolation réseau | `iptables FORWARD DROP` — aucun paquet WiFi ne sort |
| Isolation clients | `hostapd ap_isolate=1` — clients ne se voient pas |
| Intégrité fichiers | `chattr +i` + SHA256 toutes les 5 min |
| Mode dégradé | PHP-FPM stoppé si intégrité compromise — portail HTML accessible |
| CSRF | Token de session one-shot (api_install + admin) |
| Rate-limit firstboot | 5 tentatives / 15 min par IP |
| Admin web | HTTP Basic Auth (`/etc/nginx/.htpasswd`) |
| LoRa | AES-256-GCM, clé unique par déploiement |
| Logs | Mémoire volatile (tmpfs) — effacés au redémarrage |
| IPv6 | Désactivé globalement |
| Backup config | `.bak` automatique avant chaque écriture admin |

> Ce système ne collecte **aucune donnée personnelle persistante**.
> Voir [PRIVACY.md](PRIVACY.md) — conforme **nLPD RS 235.1** et **RGPD**.

---

## 🌍 Langues supportées (29)

FR · DE · IT · **RM** (Romanche) · EN · ES · PT · AR · ZH · JA · KO · RU · UK ·
PL · NL · SV · NO · DA · FI · HU · RO · CS · EL · TR · FA · HI · TH · VI · HE

> Le **Romanche (RM)** est requis pour la certification PCi-CH (procurement fédéral suisse).

---

## 📋 Variables de `config.json`

| Clé | Type | Description |
|-----|------|-------------|
| `establishment.name` | string | Nom du lieu / identifiant du nœud |
| `establishment.address` | string | Adresse complète |
| `establishment.lat` / `lon` | string | Coordonnées GPS |
| `establishment.type` | string | `erp`, `ecole`, `hopital`, `mairie`… |
| `establishment.localCrisisNumber` | string | Cellule de crise locale |
| `establishment.localSamuNumber` | string | Override numéro ambulance (portail) |
| `establishment.localPoliceNumber` | string | Override numéro police (portail) *(v2.4)* |
| `establishment.localPompiersNumber` | string | Override numéro pompiers (portail) |
| `establishment.localMeetingPoint` | string | Point de rassemblement |
| `establishment.localEvacuationPlan` | string | Plan d'évacuation |
| `defaultLang` | string | Langue par défaut du portail (code ISO parmi les 29, choisie au starter) |
| `wifiChannel` | int | Canal WiFi 1–13 (EU : 1, 6 ou 11) |
| `wifiPassword` | string | Mot de passe WPA2 (vide = réseau ouvert) |
| `enableLoRa` | bool | Activer lora-service.py |
| `enableEthernet` | bool | Activer ETH + accès admin ETH (v2.4) |
| `reassurance.message` | string | Message affiché sur le portail |

---

## 🧑‍💻 Développement

### En local (Docker)

```bash
docker compose up --build
# Starter (wizard)  : http://localhost:8080/
# Portail survivants : http://localhost:8080/portal
# Admin              : http://localhost:8080/admin  (admin / dev-sos-guide)
```

Les sources `src/` sont montées en lecture seule dans le conteneur — toute
modification est visible au rechargement de la page.

### Sur un Raspberry Pi de dev (sans AP WiFi)

Le mode dev fait tourner le portail sur le réseau local (port 80), **sans**
hostapd/dnsmasq/iptables — le Pi reste accessible normalement.

```bash
# 1. Configuration initiale du Pi (une seule fois)
bash src/scripts/dev-setup-pi.sh

# 2. Synchro temps réel src/ → Pi pendant le dev
bash src/scripts/sync.sh
```

- Accès : `http://<IP-du-Pi>/` — la page servie (STARTER ou PRODUCTION) dépend
  du mode courant, basculable depuis le navigateur : `curl -X POST http://<IP-du-Pi>/dev-switch`
- Le runtime dev vit dans `/tmp/sos-guide/` (token CSRF, mode, rate-limit) ;
  `config.json` du Pi n'est jamais écrasé par la synchro.

---

## 🤝 Contribuer

```bash
git clone https://github.com/sos-guide/SOS-GUIDE.git
cd SOS-GUIDE
git checkout -b feature/ma-contribution
# ... modifications ...
git commit -m "feat: description claire"
git push origin feature/ma-contribution
# → Ouvrir une Pull Request
```

**Avant de soumettre :**
```bash
shellcheck install.sh src/scripts/build-image.sh src/scripts/sos-guide-update.sh src/scripts/sos-guide-test.sh
python3 -m json.tool src/web/data/config.json
sudo bash src/scripts/sos-guide-test.sh
```

**Et consigner le changement dans [CHANGELOG.md](CHANGELOG.md)** (section `[Non publié]`) —
obligatoire pour toute PR. La CI (`.github/workflows/ci.yml`) rejoue ces vérifications.

---

## 📄 Licence

EUPL-1.2 — voir [LICENSE](LICENSE)

> La licence EUPL-1.2 est recommandée pour les projets open source en procurement public suisse (simap.ch).

Copyright © 2024–2026 Ludovic MARTIN · [contact@sos-guide.fr](mailto:contact@sos-guide.fr)

---

> **⚠️ Ce système est conçu pour fonctionner déconnecté d'Internet.**
> Il ne transmet aucune donnée vers l'extérieur.
> Destiné à un usage humanitaire, de sécurité civile et de protection des populations.
