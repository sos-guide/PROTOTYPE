# Changelog

Tous les changements notables de SOS-GUIDE sont consignés dans ce fichier.

Le format suit [Keep a Changelog](https://keepachangelog.com/fr/1.1.0/) et le projet
adhère au [versionnage sémantique](https://semver.org/lang/fr/) (`VERSION` à la racine).

> Règle de contribution : **toute modification du code, des configs ou de la doc doit
> ajouter une entrée sous `[Non publié]`** avant d'être soumise. Au moment d'une release,
> la section `[Non publié]` devient `[X.Y] - AAAA-MM-JJ`.

## [Non publié]

### Ajouté
- **Nœud de secours Tor (canal Ethernet → `.onion`)** : nouveau service caché Tor
  servant une **surface restreinte** d'identification du nœud et de manifeste de
  mise à jour, sans jamais exposer le portail captif. Script
  `src/scripts/sos-guide-tor-setup.sh` (génère le `HiddenService`, publie
  l'adresse dans `/var/lib/sos-guide/onion_hostname`), page
  `src/web/tor-node.php` (HTML + `?format=json` + `?manifest=1`) servie sur un
  vhost nginx dédié `127.0.0.1:9080`. Champ `enableTor` dans `config.json`,
  activable depuis `/admin`. Modèle à trois canaux désormais explicite :
  **WiFi = page statique de survie · LoRa = messages d'urgence · Ethernet/Tor =
  mises à jour + identification**.
- **`/admin` : interrupteur WiFi ON/OFF** (allumage/extinction de `hostapd` +
  `dnsmasq` en direct) et **gestion des mots de passe** : changement du mot de
  passe administrateur du portail (htpasswd) **et** du compte Linux du Pi (SSH),
  via la nouvelle carte « Sécurité & accès ». Backend `src/web/api_admin_action.php`
  (token CSRF à usage unique + whitelist IP + audit) et script root
  `src/scripts/sos-guide-set-credentials.sh` (mot de passe lu sur **STDIN**, jamais
  en argument visible dans `ps`). Route nginx `/api/admin-action` (auth_basic +
  CSRF) ajoutée dans `install.sh` et `dev-setup-pi.sh`.
- **Optimisations CSS « contexte d'urgence » (`lib/sos-theme.css`, 4 pages)** :
  cibles tactiles ≥ 44 px et `touch-action:manipulation` (suppression du délai de
  300 ms), `content-visibility:auto` sur les longues listes (first-paint plus
  rapide sur téléphone/Pi modeste), `overscroll-behavior` (numéros d'urgence
  toujours visibles en haut d'écran), prise en charge du **contraste élevé
  système** (`forced-colors`), **styles d'impression** (un survivant peut
  imprimer/PDF les numéros d'urgence, liens `tel:` rendus en clair), césure des
  longues traductions et `-webkit-text-size-adjust` (pas de zoom auto cassant le
  layout). `sudoers` étendu (start/stop hostapd+dnsmasq, scripts credentials/tor).
- **Affiche imprimable en fin de configuration** : l'écran de succès du starter
  propose « Télécharger l'affiche (PNG) » — gabarit `img/flyer.png` complété
  côté client (canvas) avec le nom du lieu, le pays/adresse, les instructions,
  le SSID et un **QR code WiFi** (connexion au réseau ouvert en un scan).
  Libellés traduits dans les 29 langues (`I18N.*.flyer`). Repli sur un fond
  généré si le gabarit est absent.

### Corrigé
- **`/lora` était inaccessible** : aucune route nginx (prod **et** dev) — le
  lien « Messagerie LoRa » du portail retombait silencieusement sur index.html.
  `location = /lora` ajouté dans `install.sh` et `dev-setup-pi.sh`
  (relancer `dev-setup-pi.sh` sur le Pi de dev pour l'appliquer).

### Modifié
- **CLAUDE.md restructuré et complété** : ajout de l'arborescence annotée du dépôt,
  du tableau des 14 scripts de `src/scripts/`, de la liste des APIs PHP
  (`whitelist.php` inclus), des invariants vérifiés par la CI (`ci.yml`) et des
  services `sos-guide-update.timer`/watchdog. Correction : `finalize_install.sh`
  est documenté comme thin wrapper (< 50 lignes) déléguant à `sos-guide-install.sh`,
  et non plus comme copie d'`install.sh`. Rappel ajouté : toute nouvelle route
  nginx doit être déclarée dans `install.sh` **et** `dev-setup-pi.sh`.
- **Animations réduites au minimum** : suppression des entrées décoratives du
  splash (floatIn/slideUp), du popIn des modales et de la pulsation du point
  « connecté » du starter. Conservés : transitions de survol/focus et la
  pulsation de la bannière d'alerte LoRa (signal fonctionnel).

### Corrigé (conformité WCAG 2.1 AA / W3C — audit affichage)
- **Contrastes AA mesurés et corrigés** dans `sos-theme.css` : `--sub` sombre
  6b7fa3→7d90b4 (5.5:1), `--muted` sombre 475569→7588a8 (5.0:1), `--muted` clair
  94a3b8→5d6b82 (5.4:1). Nouveaux tokens `--accent-strong`/`--accent-strong-h`
  (2563eb/1d4ed8) pour les fonds de boutons sous texte blanc (5.2:1) — appliqués
  aux `.btn-primary` (admin, starter), `.tool-button` et `.phone-badge` (portail).
- **Labels associés aux champs** (WCAG 1.3.1) : 14 `for=`/`id` dans admin.php,
  `aria-label` sur les toggles LoRa/Ethernet et le textarea LoRa, `for=` sur les
  8 labels des templates JS du starter.
- **Switches du starter accessibles au clavier** : `role="switch"`, `tabindex`,
  `aria-checked`, activation Entrée/Espace (helper `wireSwitch`). Styles
  `:focus-visible` complétés (starter) et ajoutés à admin + lora-portal.
- **`prefers-reduced-motion`** global dans `sos-theme.css` (WCAG 2.3.3) +
  classe `.skip-link` ; liens d'évitement ajoutés à admin et lora-portal.
- **index.html : 13 erreurs de validation corrigées** : `<nav>` nommés
  (`aria-label`), grille d'urgences en `<ul>/<li>` natifs (au lieu de
  `role=list/listitem`), `<main>` landmark, textes de repli statiques dans les
  titres et boutons remplis par le JS (h1, boutons outils, bouton Entrer).
- **Métadonnées complétées** : `color-scheme`, `theme-color`, description et
  favicon sur admin ; `color-scheme`, `theme-color`, description sur lora-portal ;
  `color-scheme` corrigé `dark`→`dark light` + description sur le starter.
- Résultat : **0 erreur** html-validate (preset conformité + règles WCAG) sur
  les 4 pages ; tous les ratios de contraste ≥ 4.5:1 (AA texte normal).

### Ajouté
- **Sélection de langue du starter refondue** : barre de navigation fixe (logo +
  bouton planète **🌐** + bascule thème) et **modale de langue à drapeaux** identique
  au portail (`index.html`). Le menu déroulant de langue dans la carte d'accueil est
  supprimé. Direction **RTL** appliquée automatiquement au wizard pour `ar`/`he`/`fa`.
- **Traductions du wizard pour les 29 langues** : l'interface du starter
  (`I18N`) était traduite nativement seulement en fr/en/de/it/rm et retombait sur
  l'anglais ; elle couvre désormais les **29 langues** (es, pt, nl, pl, ru, uk, tr,
  el, sv, da, no, fi, cs, hu, ro, ar, he, fa, zh, ja, ko, hi, th, vi ajoutées).
  ⚠ ar/he/fa/rm/hi/th à faire relire par des locuteurs natifs avant dépôt PCi-CH.
- **Champ « Pays » du lieu** : ajouté au starter (étape Identité + résumé), validé
  et stocké par `api_install.php` (`establishment.country`), éditable dans `/admin`
  (`update_config.php`) et affiché sur le portail sous le nom du lieu.
- `CHANGELOG.md` — ce fichier ; consignation obligatoire de tous les changements futurs.
- **Dépôt git initialisé** et relié à `https://github.com/sos-guide/SOS-GUIDE`.
- **`src/web/lib/sos-theme.css`** — source unique des tokens de design (sombre + clair),
  chargée par les 4 pages ; les blocs `:root` dupliqués sont supprimés.
- **Mode clair/sombre sur toutes les pages** : starter, admin et portail LoRa ont
  maintenant le toggle 🌙/☀️ (clé localStorage `sos_guide_theme` partagée avec le portail).
- **Traduction romanche (rm) du wizard starter** — 5 langues natives (fr/en/de/it/rm),
  ⚠ à faire relire par un locuteur natif avant dépôt PCi-CH (idem `fa.json`).
- **Accessibilité du portail** : rôles ARIA, `aria-label` sur tous les boutons et
  numéros d'urgence, navigation clavier (Enter/Espace) sur les cartes, fermeture
  des modales/drawer par Échap, styles `:focus-visible`.
- **Langue par défaut modifiable dans /admin** (sélecteur 29 langues, validée
  par `update_config.php` avec la même whitelist qu'`api_install.php`).
- **TLS auto-signé activé par défaut sur /admin** lors de l'installation
  (`install.sh` appelle `sos-guide-tls-setup.sh`, non bloquant ; le portail
  captif reste en HTTP par conception).
- **`src/scripts/check-web-dom.mjs`** — vérification CI de la syntaxe JS inline
  et de la résolution de tous les `getElementById` (étape ajoutée à `ci.yml`).

### Corrigé
- **Types d'établissement désynchronisés** : `admin.php`/`update_config.php`
  utilisaient l'ancienne liste v2.4 (`ecole`, `ehpad`…) — un lieu configuré
  « École » au starter (`school`) était silencieusement réécrit en `erp` à la
  première sauvegarde admin. Listes fusionnées (nouveaux types + anciens).
- `admin.php` cherchait `img/map_location.png` alors qu'`api_install.php` sauve
  `img/map_local.{png,webp,jpg}` — la carte uploadée au starter n'était jamais
  détectée par l'admin.
- `api_install.php` : les tirets cadratins (– —) du nom du lieu étaient avalés
  par la sanitisation.
- Mention « Certifié Croix-Rouge Suisse » retirée du starter (claim non prouvé) ;
  « Conforme PCi-CH » reformulé en « Conçu selon les exigences PCi-CH ».
- En-têtes PHP harmonisés en v2.5 (admin v2.4, lora-portal v2.3, etc.).
- Icône 🇫🇷 incongrue (« principes de secourisme ») remplacée par 🩹 dans les
  29 fichiers de langue et leurs liens de menu.
- CSS RTL : bordure de titre de section, cartes et drawer adaptés en `dir=rtl`.
- Test E2E starter→install validé sur le Pi de dev (token CSRF one-shot,
  config.json écrit avec `defaultLang`, types v2.5 acceptés).
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
