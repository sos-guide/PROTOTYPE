# Politique de confidentialité — SOS-GUIDE v2.4

**Conformité :** Loi fédérale suisse sur la protection des données (nLPD, RS 235.1)  
**Conformité :** Règlement général sur la protection des données (RGPD, UE 2016/679)  
**Applicable à :** Toute installation du système SOS-GUIDE sur un Raspberry Pi  
**Dernière mise à jour :** Avril 2026

---

## 1. Responsable du traitement

Le responsable du traitement est l'entité qui déploie ce système sur le terrain
(mairie, hôpital, école, protection civile, Croix-Rouge, etc.).

Ludovic MARTIN / SOS-GUIDE agit en qualité de **sous-traitant technique**
(fournisseur du logiciel open source) conformément à l'art. 5 lit. j nLPD.

---

## 2. Données collectées — inventaire exhaustif

### 2.1 Données collectées par le portail captif (utilisateurs WiFi)

| Catégorie | Donnée | Base légale nLPD | Durée de conservation |
|-----------|--------|-------------------|----------------------|
| Réseau | Adresse IP locale DHCP (10.0.0.x) | Intérêt légitime (art. 31 nLPD) | **0 seconde** — tmpfs, jamais persistée |
| Réseau | Adresse MAC WiFi | Intérêt légitime (DHCP) | **0 seconde** — `dhcp-leasefile=/dev/null`, jamais écrite sur disque |
| Navigation | Requêtes HTTP | Aucune — logs nginx désactivés | **Néant** — `access_log off` dans nginx |
| Contenu | Messages LoRa envoyés | Consentement explicite (art. 6 nLPD) | Tmpfs uniquement — supprimés au redémarrage par tmpfiles.d |

**Aucun cookie, aucun tracker, aucune donnée personnelle persistée sur disque.**

### 2.2 Données de configuration (administrateur local uniquement)

| Donnée | Finalité | Base légale | Conservation |
|--------|----------|-------------|--------------|
| Nom du lieu | Identification du nœud dans le réseau mesh | Nécessité contractuelle | Jusqu'à réinitialisation |
| Numéros d'urgence locaux | Affichage sur portail | Nécessité contractuelle | Jusqu'à modification admin |
| Coordonnées GPS (optionnel) | Affichage de la carte locale | Consentement | Jusqu'à modification admin |
| Adresse du lieu | Affichage sur portail | Nécessité contractuelle | Jusqu'à modification admin |

### 2.3 Données de messages LoRa (si module activé)

Les messages texte envoyés via le réseau LoRa sont :
- **Chiffrés** avec AES-256-GCM avant transmission
- **Temporairement écrits** dans `/var/www/sos-guide/data/lora_inbox.json` (tmpfs) pour le portail
- **Supprimés au redémarrage** par `tmpfiles.d` (type `r`, conformité nLPD art. 6)
- **Pseudonymisés** : identifiant de nœud (8 hex) sans lien à une personne physique

---

## 3. Données non collectées (déclaration explicite)

SOS-GUIDE **ne collecte pas** et **ne peut pas collecter** :
- ✗ Contenu des navigations (sites visités par les clients WiFi)
- ✗ Identité des utilisateurs connectés
- ✗ Données de localisation des appareils clients
- ✗ Historique des connexions (pas de logs persistants)
- ✗ Données biométriques
- ✗ Données de santé
- ✗ Adresses e-mail ou numéros de téléphone des utilisateurs

---

## 4. Mesures techniques de protection (art. 8 nLPD)

### 4.1 Isolation réseau
- Clients WiFi isolés d'Internet (`FORWARD DROP` iptables)
- Isolation client-à-client (`ap_isolate=1` hostapd)
- DNS forcé vers le nœud local uniquement
- IPv6 désactivé sur toutes les interfaces

### 4.2 Chiffrement
- Messages LoRa : AES-256-GCM (nonce 96 bits, tag 128 bits)
- Clé dérivée via PBKDF2-HMAC-SHA256 (100 000 itérations)
- Administration HTTPS si certificat disponible

### 4.3 Intégrité système
- Hash SHA256 de tous les fichiers web au démarrage
- Vérification toutes les 5 minutes (sos-guide-health.timer)
- Arrêt automatique si intégrité compromise

### 4.4 Logs d'exploitation

Les logs nginx sont désactivés (`access_log off`) — aucun log de navigation n'est généré.

Les logs d'installation et d'audit système (`/var/log/sos-guide-*.log`) sont écrits sur la
carte SD mais **supprimés automatiquement au prochain démarrage** via
`systemd-tmpfiles --remove` (configuration `sos-guide-logs.conf`).

Ces logs ne contiennent pas de données personnelles identifiables : adresses IP des
clients WiFi non journalisées (nginx), noms et numéros de contact fournis lors de la
configuration uniquement dans `config.json` (non dans les logs).

> **Note technique** : les logs sont stockés sur la carte SD entre deux démarrages
> (pas de montage tmpfs). En cas d'arrêt brutal du Pi sans redémarrage propre, les
> logs de la dernière session peuvent persister sur la carte SD jusqu'au prochain boot.

### 4.5 Authentification administration
- Interface `/admin` protégée par authentification HTTP Basic (htpasswd)
- Token CSRF one-shot pour la configuration initiale
- Réseau WiFi toujours ouvert — accès immédiat sans mot de passe

---

## 5. Droits des personnes concernées (art. 25-27 nLPD)

En raison de l'**absence de collecte de données persistantes**, les droits
d'accès, rectification et effacement (art. 25 nLPD) ne s'appliquent pas
aux utilisateurs du portail captif — aucune donnée les concernant n'est conservée.

Pour les données de configuration (nom du lieu, contacts), le responsable
local du traitement peut les modifier à tout moment via `/admin`.

---

## 6. Transferts internationaux (art. 16 nLPD)

**Aucun transfert international.** Le système fonctionne intégralement
hors ligne. Aucune donnée ne quitte le réseau local sauf via le réseau
LoRa mesh vers d'autres nœuds SOS-GUIDE du même déploiement.

Si la connexion Ethernet est activée pour les mises à jour de contenu :
- Seul le fichier JSON de langue est téléchargé depuis `sos-guide.fr`
- Aucune donnée utilisateur n'est transmise au serveur distant
- La connexion utilise TLS 1.2+ avec vérification du certificat SHA256

---

## 7. Sous-traitants (art. 9 nLPD)

| Sous-traitant | Rôle | Lieu | Garanties |
|---------------|------|------|-----------|
| Raspberry Pi Foundation | Matériel (optionnel) | Royaume-Uni | Décision d'adéquation |
| sos-guide.fr (CDN mises à jour) | Hébergement JSON | France (UE) | RGPD applicable |

Aucun sous-traitant américain. Aucun service cloud. Aucun analytics.

---

## 8. Contact délégué à la protection des données

Pour toute question relative à cette politique :  
**contact@sos-guide.fr**  
Objet : [nLPD] Protection des données SOS-GUIDE

Conformément à l'art. 12 nLPD, toute demande recevra une réponse dans
un délai de 30 jours.

---

## 9. Modifications

Cette politique peut être mise à jour lors des nouvelles versions du logiciel.
La version applicable est celle incluse dans l'image `.img` installée.

Version du document : **2.4 — Avril 2026**  
Hash SHA256 : à calculer lors du build de l'image

---

*Ce document doit être affiché ou mis à disposition des utilisateurs du portail
captif. Une mention courte « Aucune donnée personnelle collectée — Politique
complète sur demande » est suffisante sur le portail.*
