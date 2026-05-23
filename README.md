### **RÉSUMÉ DÉTAILLÉ DU PROJET SOS-GUIDE v2.1**  
**Système de Communication d’Urgence Hors Ligne avec Réseau Mesh LoRa**  

---

#### **🎯 Objectif Principal**  
Créer un **système de communication autonome et résilient** permettant de rester connecté en cas de 
panne des réseaux Internet, d’attaque cybernétique, ou de catastrophe naturelle. Ce système est 
basé sur des **Raspberry Pi**, des **batteries**, et des **réseaux de communication LoRa** pour une 
diffusion de messages sans dépendre de l’infrastructure Internet classique.  

---

#### **🔧 Composants Techniques**  
1. **Raspberry Pi (Modèle 4 ou 5)** :  
   - Central de traitement, serveur Wi-Fi, gestion de la communication LoRa.  
   - Alimenté par une **batterie externe (5V/3A)** pour une autonomie prolongée.  
2. **Réseau Wi-Fi** :  
   - Point d’accès ouvert (`SSID : ⛑️ SOS-GUIDE`) sur canal 11, capacité jusqu’à 50 clients 
simultanés.  
   - Isolation totale des clients : aucune connexion Internet, redirection des requêtes vers le 
portail captif.  
3. **Réseau Mesh LoRa** :  
   - Communication entre nœuds via **fréquence LoRa (868 MHz, 915 MHz, ou 433 MHz)**.  
   - Chaque boîtier dispose d’une **antenne LoRa** pour la transmission de messages.  
   - Messages cryptés en **AES-256** et diffusion via **multicast** (diffusion aux nœuds voisins).  


---

#### **🌐 Fonctionnement du Système**  
1. **Accès Wi-Fi** :  
   - Les utilisateurs (clients) se connectent via le SSID `SOS-GUIDE` pour accéder au portail 
captif.  
   - Le portail affiche des **guides de survie multilingues**, des contacts d’urgence, et des 
alertes en temps réel.  
2. **Communication LoRa** :  
   - Les clients peuvent **envoyer des messages texte (ou alertes)** via le réseau LoRa.  
   - Les messages sont cryptés et diffusés aux nœuds voisins (mesh), permettant une transmission 
jusqu’à **5 km** (en fonction de la fréquence et de l’antenne).  
   - Les nœuds reçoivent les messages, les relaient, et les stockent en RAM pour éviter les pertes 
de données.  
3. **Isolation et Sécurité** :  
   - Le système est **désconnecté d’Internet** pour garantir l’autonomie.  
   - Les fichiers sont verrouillés avec `chattr +i` (sauf pour l’administration).  
   - Vérification d’intégrité SHA256 au démarrage et **health check** toutes les 5 minutes.  

---

#### **📲 Interfaces et Fonctionnalités Clés**  
1. **Portail Captif Multilingue** :  
   - 25+ langues (français, anglais, espagnol, etc.).  
   - Contient des guides de premiers secours, outils pratiques (métronome, lampe torche), et 
alertes.  
   - Messages de réassurance et numéros d’urgence locaux.  
2. **Interface Admin (Local)** :  
   - Modification des contacts, des messages, et de l’identité du lieu via une interface web 
`/admin`.  
   - Mise à jour automatique des contenus (si connexion Ethernet disponible).  
3. **Mode "Firstboot"** :  
   - Déploiement rapide pour les terrains : configuration minimale, activation automatique du mesh 
LoRa.  
   - Génération de clé AES-256 préconfigurée pour la communication.  

---

#### **🔋 Énergie et Robustesse**  
- **Autonomie** :  
  - Batterie externe pour alimenter le Raspberry Pi et le module LoRa.  
  - Mode veille intelligente pour prolonger la durée de vie.  
- **Redondance** :  
  - Les messages sont stockés en RAM (tmpfs) pour éviter la perte de données.  
  - Réseau mesh LoRa pour garantir la communication même si un nœud échoue.  
- **Robustesse** :  
  - Watchdog matériel (redémarrage automatique en cas de plantage).  
  - Vérification régulière de l’intégrité du système.  

---

#### **🛠️ Prérequis Matériels**  
- **Raspberry Pi** (modèle 4 ou 5 recommandé).  
- **Carte microSD** (8 Go minimum, classe A1).  
- **Batterie externe 5V/3A**.  
- **Module LoRa** (SX1276, SX1280, etc.) + **antenne LoRa**.  
- **Optionnel** : câble Ethernet pour administration ou mises à jour.  

---

#### **📲 Intégration des Messages LoRa**  
- **Sensibilité** : Les clients Wi-Fi peuvent envoyer des messages texte via le portail captif.  
- **Transmission** : Le Raspberry Pi envoie ces messages en AES-256 via LoRa vers d’autres nœuds.  
- **Diffusion** : Les messages sont répartis dans le réseau mesh pour garantir une couverture 
maximale.  
- **Récupération** : Les utilisateurs peuvent consulter les alertes sur leur appareil, même si leur 
connexion Wi-Fi est coupée.  

---

#### **🔎 Avantages et Utilisation**  
1. **Autonomie Totale** : Fonctionne sans Internet, même en cas de blackout.  
2. **Robustesse** : Réseau mesh LoRa pour une transmission fiable.  
3. **Accessibilité** : Interface multilingue et guides de survie pour tous les utilisateurs.  
4. **Évolutivité** : Ajout de nœuds LoRa facile, sans dépendance matérielle.  
5. **Sécurité** : Cryptage des messages, isolation des clients, et vérification d’intégrité.  

---

#### **🧪 Cas d’Utilisation**  
- **Catastrophes naturelles** : Inondation, séisme, incendie.  
- **Attaques cybernétiques** : Bloquage des réseaux Internet.  
- **Événements collectifs** : Attentats, fuites de gaz, NRBC.  
- **Systèmes critiques** : Usines, hôpitaux, mairies, écoles.  

---

#### **📌 Conclusion**  
**SOS-GUIDE v2.1** est une solution **open source, robuste, et d’avenir** pour les communications 
d’urgence. En combinant **Wi-Fi et LoRa**, elle garantit une connexion stable, une diffusion de 
messages cryptés, et une gestion locale des alertes. Ce système est idéal pour des déploiements 
rapides en terrain, en milieu rural, ou en cas de crise.  

**⚠️ Note** : Ce projet est conçu pour être **désconnecté d’Internet**, **autonome**, et **protégé 
des attaques externes**.  

--- 

**Prêt pour déployer un système de survie à l’échelle d’une communauté ! 🌍**

