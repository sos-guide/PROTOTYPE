# Changelog

Tous les changements notables de SOS-GUIDE sont consignés dans ce fichier.

Le format suit [Keep a Changelog](https://keepachangelog.com/fr/1.1.0/) et le projet
adhère au [versionnage sémantique](https://semver.org/lang/fr/) (`VERSION` à la racine).

> Règle de contribution : **toute modification du code, des configs ou de la doc doit
> ajouter une entrée sous `[Non publié]`** avant d'être soumise. Au moment d'une release,
> la section `[Non publié]` devient `[X.Y] - AAAA-MM-JJ`.

## [Non publié]

### Ajouté
- `CHANGELOG.md` — ce fichier ; consignation obligatoire de tous les changements futurs.
- **`fa.json` (persan)** — la 29ᵉ langue annoncée partout était absente de `src/web/data/` ;
  le sélecteur du portail proposait فارسی mais retombait silencieusement sur le français.
- **Sélection de langue au starter** : menu déroulant des **29 langues avec
  drapeaux** (mêmes entrées que la modale du portail) sur l'écran d'accueil,
  détection automatique de la langue du navigateur. L'interface du wizard est
  traduite nativement en FR / EN / DE / IT et retombe sur l'anglais pour les
  autres langues. La langue choisie est envoyée comme `defaultLang`, stockée
  dans `config.json` et devient la langue par défaut du portail survivants
  (priorité : choix utilisateur en localStorage > `defaultLang` > fr).

### Modifié (design)
- **Portail entièrement redessiné sur le modèle de sosguide.fr/demo.html** :
  navbar fixe, menu drawer, **mode clair/sombre** (toggle 🌙/☀️ persistant),
  sélecteur de langue en modale avec drapeaux, cartes d'urgence en dégradés
  avec numéro fantôme, cartes du guide en dégradés, modales animées.
  Fonctionnalités du projet reportées dans le nouveau design : 29 langues
  (rm + fa ajoutés, la démo n'en avait que 27), RTL (ar/he/fa), `defaultLang`,
  surcharge des numéros locaux (`localSamuNumber`/`localPoliceNumber`/
  `localPompiersNumber` + carte « crise » `uc-local`), bannière + section LoRa,
  mode dégradé, CSP, image `img/map_local.{png,webp,jpg}`, échappement HTML des
  valeurs de config. Ancien portail conservé : `index-v2.4-portail.html.bak`.
- Tokens des autres pages alignés sur la démo : cartes `#0f1826`, survol
  `#162035`, radius `14px` (starter, admin, lora-portal).

### Corrigé
- **Style unifié sur les 4 pages web** : `starter.html` passait du clair/rouge au
  thème sombre commun (`#060a12`, accent bleu `#3b82f6`) ; `admin.php` (palette
  slate divergente) et `lora-portal.php` (radius) alignés sur `index.html`.
- `dev-switch.php` : la bascule production → starter plantait (HTTP 500) car le
  token CSRF précédent en `chmod 0400` ne pouvait pas être réécrit — suppression
  avant régénération.
- `index.html` : le portail pollait `data/lora_inbox.json` toutes les 10 s même
  avec LoRa désactivé → spam de 404 dans les logs nginx ; le poll est maintenant
  conditionné à `enableLoRa`.
- `sos-guide-test.sh` : `ALL_LANGS` ne comptait que 28 langues (fa manquant)
  alors que le test affichait « /29 ».

### Modifié
- `README.md` — section « Nouveautés » remplacée par un renvoi vers le changelog,
  structure du dépôt mise à jour (docker/, src/dev/, scripts manquants),
  nouvelle section « Développement », corrections de coquilles (emoji STARTER,
  numérotation des étapes du premier démarrage).
- `CLAUDE.md` — ajout du workflow de développement (Docker, mode dev Pi, sync
  temps réel) et de la règle de tenue du changelog.

## [2.5] - 2026-06-10

### Ajouté
- **Environnement de développement complet** :
  - `docker-compose.yml` + `docker/` — stack locale sur `http://localhost:8080`
    (starter `/`, portail `/portal`, admin `/admin`, login `admin`/`dev-sos-guide`).
  - `src/scripts/dev-setup-pi.sh` — configure un Pi en mode dev (nginx + php-fpm
    port 80, sans hostapd/dnsmasq/iptables, Kronos préservé).
  - `src/scripts/sync.sh` — synchro temps réel `src/` → Pi (inotify ou polling 2 s),
    `config.json` du Pi jamais écrasé.
  - `src/dev/dev-router.php` + `src/dev/dev-switch.php` — bascule
    STARTER ↔ PRODUCTION depuis le navigateur (`POST /dev-switch`),
    runtime dev dans `/tmp/sos-guide/`.
- **Bundle de dépendances offline** : `src/scripts/build-offline-bundle.sh` génère
  `offline-deps-<arch>-debian<ver>.tar.gz` (tous les `.deb` + dépendances
  transitives) — `install.sh` fonctionne désormais **sans accès Internet**.
- **Cartes hors ligne** : `src/scripts/sos-guide-fetch-tiles.sh` télécharge les
  tuiles OSM (bounding box depuis `config.json`) vers `/var/www/sos-guide/tiles/`.
- **Retour usine** : `src/scripts/sos-guide-reset-starter.sh [--force]` réinitialise
  le Pi en mode STARTER.
- **Watchdog matériel** : `src/scripts/sos-guide-watchdog-test.sh` — sonde
  applicative appelée toutes les 5 s par `watchdog(8)` (timeout 15 s).
- **TLS optionnel** : `src/scripts/sos-guide-tls-setup.sh`.
- **CI GitHub Actions** (`.github/workflows/ci.yml`) — shellcheck, validation JSON,
  lint PHP sur chaque push/PR.
- **Drop-ins systemd** `Restart=` pour hostapd, dnsmasq et nginx
  (`src/systemd/*/sos-guide-restart.conf`) + `sos-guide-logs.conf` (logs tmpfs).
- `PRIVACY.md` — politique de confidentialité (nLPD RS 235.1 / RGPD).

## [2.4]

### Ajouté
- QR code WiFi pour rejoindre le réseau STARTER en un scan.
- Champ `localPoliceNumber` (override police/gendarmerie locale).
- Accès admin via Ethernet (whitelist IP) si `enableEthernet=true`.
- Backup `.bak` automatique de `config.json` avant chaque écriture.

### Modifié
- Configuration **100 % via WiFi** : réseau STARTER ouvert, sans mot de passe.
- Les numéros d'urgence locaux de `config.json` remplacent les numéros par défaut
  de la langue sélectionnée.
- Mode dégradé : remplacement du `poweroff` par un mode lecture seule
  (portail HTML accessible, PHP-FPM stoppé).
- Détection Ethernet dynamique (suppression de `eth0` codé en dur, compatible RPi 4/5).
- Chargement gracieux du backup `.bak` si `config.json` est corrompu.

### Supprimé
- PIN HDMI — plus aucun écran physique requis pour la configuration.
