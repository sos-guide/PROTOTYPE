# CLAUDE.md

Ce fichier fournit des indications à Claude Code (claude.ai/code) pour travailler avec le code de ce dépôt.

## Description du projet

SOS-GUIDE transforme un Raspberry Pi en point d'accès WiFi hors ligne diffusant des guides de survie multilingues, des contacts d'urgence locaux et un réseau mesh LoRa chiffré — sans Internet, sans infrastructure, sans écran. Cible : Raspberry Pi 4/5 sous Raspberry Pi OS Bookworm Lite.

## Commandes courantes

```bash
# ── Développement ──
docker compose up --build              # Stack locale : http://localhost:8080 (admin / dev-sos-guide)
bash src/scripts/dev-setup-pi.sh       # Configure le Pi de dev (192.168.1.133) — une seule fois
bash src/scripts/sync.sh               # Synchro temps réel src/ → Pi (à laisser tourner pendant le dev)
curl -X POST http://192.168.1.133/dev-switch   # Bascule STARTER ↔ PRODUCTION sur le Pi de dev

# ── Build & déploiement ──
bash src/scripts/build-image.sh                 # Image .img.gz RPi4, variante Suisse (~30–60 min)
bash src/scripts/build-image.sh --rpi5 --sign   # RPi5, signé GPG
sudo bash install.sh                            # Déployer + finaliser sur un Pi en marche (root)
bash src/scripts/build-offline-bundle.sh        # Régénérer offline-deps-*.tar.gz (sur Pi connecté)

# ── Tests & lint ──
sudo bash src/scripts/sos-guide-test.sh           # rapide (sur le Pi)
sudo bash src/scripts/sos-guide-test.sh --full    # + test de charge (nécessite ab)
sudo bash src/scripts/sos-guide-test.sh --report  # génère /tmp/*.json
shellcheck install.sh src/scripts/build-image.sh src/scripts/sos-guide-update.sh src/scripts/sos-guide-test.sh
python3 -m json.tool src/web/data/config.json
```

## Règles de documentation (obligatoire)

- **CHANGELOG.md** : chaque modification (code, config, doc) ajoute une entrée sous
  `[Non publié]` (format Keep a Changelog : Ajouté / Modifié / Corrigé / Supprimé).
- **README.md** et **CLAUDE.md** doivent rester synchrones avec le code : nouveau
  script, nouveau service, nouveau champ `config.json` ou nouvelle commande ⇒ mettre
  à jour la doc dans le même changement.

## Architecture

### Environnement de développement

Deux options, sans hostapd/dnsmasq/iptables (le réseau local reste utilisable) :

1. **Docker local** (`docker-compose.yml` + `docker/`) — port 8080, `src/` monté en
   lecture seule, `DEV_MODE=1`.
2. **Pi de dev** (`admin@192.168.1.133`) — nginx + php-fpm sur le port 80, fichiers
   dans `/var/www/sos-guide/`. `src/dev/dev-router.php` sert `starter-template.html`
   ou le portail selon `/tmp/sos-guide/dev-mode` ; `dev-switch.php` bascule le mode.
   Le runtime dev (token CSRF, rate-limit) vit dans `/tmp/sos-guide/`, pas dans
   `/run/sos-guide/`. `sync.sh` n'écrase jamais `config.json` du Pi. Ce Pi héberge
   aussi Kronos (ports 18080-18082) — ne pas y toucher. Attention : pas d'Ethernet
   sur ce Pi, ne jamais y lancer la vraie installation production (hostapd prendrait
   wlan0 et couperait l'accès réseau).

### Cycle de vie en deux phases

1. **STARTER** (premier démarrage) : `src/firstboot/firstboot.sh` s'exécute via `sos-guide-firstboot.service`. Il ouvre un AP WiFi ouvert (`10.0.0.1`), génère un token CSRF one-shot et sert `starter.html` (assistant de configuration).
2. **PRODUCTION** : l'admin valide l'assistant → `api_install.php` valide le CSRF + rate-limit → appelle `finalize_install.sh` (= `install.sh`) → réécrit les configs hostapd/dnsmasq/nginx et redémarre les services **sans reboot**.

### Stack de services (tous sur le Pi)

| Service | Rôle |
|---------|------|
| `hostapd` | AP WiFi — réseau ouvert, `ap_isolate=1`, pas de FORWARD vers Internet |
| `dnsmasq` | DHCP (`.100–.200`) + DNS captif (tous les domaines → `10.0.0.1`) |
| `nginx` + `php-fpm` | Sert `index.html` (portail captif), `/admin` (htpasswd), `/lora` (messagerie, ouverte) et les APIs PHP |
| `lora-service.py` | Mesh LoRa optionnel sur `127.0.0.1:8765` (SX1276 SPI, AES-256-GCM) |
| `sos-guide-health.timer` | Lance `sos-guide-boot-check.sh` toutes les 5 min — vérification SHA256 ; stoppe PHP-FPM si compromis (mode dégradé) |

### Fichiers clés sur le Pi à l'exécution

- `/var/www/sos-guide/data/config.json` — config centrale ; **jamais écrasée** lors des mises à jour de contenu ; sauvegardée en `.bak` avant chaque écriture
- `/root/integrity.hash` — manifeste SHA256 des fichiers web (hors `data/`)
- `/var/lib/sos-guide/installed` — présence = mode PRODUCTION (firstboot ignoré)
- `/etc/nginx/.htpasswd` — mot de passe admin (créer par l'admin une seule fois ; lisible dans `/var/lib/sos-guide/installed`)
- Tous les logs sont volatils (`tmpfs`) — effacés au reboot par conception (conformité nLPD)

### Invariants de sécurité

- `iptables FORWARD DROP` sur l'interface WiFi — vérifié par les tests et par `install.sh` (sort en erreur si absent)
- `chattr +i` sur tous les fichiers web sauf `data/` — `install.sh` déverrouille avant réécriture (`chattr -i`) pour assurer l'idempotence
- PHP-FPM tourne en `www-data` ; les sudoers ne lui accordent que les quatre commandes `systemctl` reload exactes
- Token CSRF : one-shot, stocké dans `/run/sos-guide/firstboot_token` (tmpfs, chmod 400), détruit après usage

### Fichiers de langue

29 fichiers JSON sous `src/web/data/` (ex. `fr.json`, `de.json`, `rm.json`). Le fichier romanche `rm.json` est obligatoire pour la certification fédérale suisse PCi-CH. `index.html` les charge côté client et superpose les numéros locaux de `config.json` aux numéros par défaut du lieux du raspberry pi exposé.

### Schéma config.json

Champs principaux : `establishment.name`, `establishment.country` (pays du lieu, saisi au starter), `establishment.address`, `wifiChannel` (1–13), `wifiPassword` (vide = réseau ouvert), `defaultLang` (langue par défaut du portail, choisie au starter), `enableLoRa`, `enableEthernet`, surcharges des numéros d'urgence (`localSamuNumber`, `localPoliceNumber`, `localPompiersNumber`, `localCrisisNumber`). Schéma complet dans README.md.

### Style des pages web

Le design de référence est celui de **sosguide.fr/demo.html**. Les tokens (sombre **et** clair) vivent dans **`src/web/lib/sos-theme.css`** — source unique, chargée par les 4 pages via `<link href="/lib/sos-theme.css">`. **Ne jamais redéfinir `:root` dans une page** ; toute nouvelle page charge ce fichier. Les 4 pages ont le toggle clair/sombre (`body.light-mode`, clé localStorage partagée `sos_guide_theme`). L'ancien portail v2.4 est archivé dans `index-v2.4-portail.html.bak` à la racine (non versionné).

### Accessibilité (WCAG 2.1 AA — niveau atteint, à maintenir)

Le portail est navigable au clavier : helper `a11yButton()` (role=button + tabindex + Enter/Espace) sur toutes les cartes générées, `aria-label` sur les boutons et numéros d'urgence, Échap ferme modales/drawer/outils. La CI vérifie la cohérence DOM via `node src/scripts/check-web-dom.mjs`.

Règles à respecter sur tout nouvel élément :
- **Contrastes** : tout texte doit faire ≥ 4.5:1 sur son fond. Les tokens de
  `sos-theme.css` sont calibrés AA — ne pas les éclaircir/assombrir. Texte blanc
  sur fond bleu ⇒ utiliser `--accent-strong` (jamais `--accent` en fond de bouton).
- **Formulaires** : chaque champ a un `<label for=>`/`id` (ou `aria-label` si pas
  de label visible).
- **Clavier** : tout élément cliquable non natif reçoit `role`, `tabindex="0"`,
  Enter/Espace (cf. `wireSwitch` dans starter.html) et un style `:focus-visible`.
- **Landmarks** : `<main>` unique par page, chaque `<nav>` a un `aria-label` ;
  skip-link `.skip-link` (classe fournie par sos-theme.css) sur les pages à barre.
- **Contenu rempli par JS** : laisser un texte de repli statique dans les `<h1>`
  et `<button>` (sinon le validateur et les lecteurs d'écran voient des vides).
- `prefers-reduced-motion` est géré globalement par sos-theme.css.
- Validation : `npx html-validate` (preset conformité + règles WCAG) doit rester
  à **0 erreur** sur les 4 pages.

### i18n

- **Portail** (`index.html`) : 29 fichiers JSON dans `src/web/data/` chargés côté client ; liste `LANGS` + `RTL_LANGS` dans index.html, liste `ALL_LANGS` dans sos-guide-test.sh — **les trois doivent rester synchrones avec data/**.
- **Starter** (`starter.html`) : sélection de langue via une **barre de navigation** (bouton planète 🌐) ouvrant une **modale à drapeaux** identique au portail (constante `LANGS`, 29 langues) — plus de menu déroulant dans la carte. L'UI du wizard est traduite nativement dans **les 29 langues** via le dictionnaire `I18N` embarqué (FR/EN/DE/IT/RM + es/pt/nl/pl/ru/uk/tr/el/sv/da/no/fi/cs/hu/ro/ar/he/fa/zh/ja/ko/hi/th/vi) ; `RTL_LANGS` (ar/he/fa) bascule `dir=rtl`. La langue choisie part en `defaultLang` dans `config.json` via api_install.php (whitelist des 29 codes). `defaultLang` est aussi modifiable dans /admin.
- **Types d'établissement** : la liste de référence est celle du starter (`erp,school,hospital,mairie,refuge,company,transport,other`) ; admin.php et update_config.php acceptent en plus les anciens types v2.4 — garder les trois listes synchrones.
- **Affiche de fin de config** : l'écran de succès du starter génère une affiche PNG (gabarit `src/web/img/flyer.png` 647×876 + QR WiFi via qrcode.min.js). Zones du gabarit : cadre QR (468,547)–(579,658), bandeaux texte y=724–800 et 819–876. Clés i18n `success.flyer` + objet `flyer{step1,step1b,step2,urlLine}` dans les 29 langues. Le SSID affiché suit la règle d'install.sh : `⛑️ SOS-GUIDE - ` + nom tronqué à 16 caractères.
- **Animations** : règle projet = le moins possible. Pas d'animations d'entrée décoratives ; seules les transitions de survol/focus et les pulsations *fonctionnelles* (alerte LoRa) sont autorisées.
- ⚠ Les traductions non latines / minoritaires du wizard et des fichiers `data/` (notamment `rm`, `ar`, `he`, `fa`, `hi`, `th`) doivent être relues par des locuteurs natifs avant tout dépôt de certification.
