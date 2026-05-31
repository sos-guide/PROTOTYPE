<?php
/**
 * SOS-GUIDE Admin Panel v2.4
 *
 * CORRECTIONS v2.4 :
 *   ✅ Erreur gracieuse si config.json invalide/absent (+ chargement backup .bak)
 *   ✅ Champ localPoliceNumber ajouté dans les contacts
 *   ✅ Détection dynamique interface ETH (suppression eth0 hardcodé)
 *   ✅ IP whitelist étendue : ETH privé si enableEthernet=true
 *   ✅ Indicateurs statut temps réel conservés
 *   ✅ Reload à chaud sans reboot
 *   ✅ Journal d'audit visible
 *   ✅ Mention nLPD
 */

session_start();

define('CONFIG_FILE', '/var/www/sos-guide/data/config.json');
define('AUDIT_LOG',   '/var/log/sos-guide-admin-audit.log');
define('HASH_FILE',   '/root/integrity.hash');

if (empty($_SESSION['csrf_token'])) {
    $_SESSION['csrf_token'] = bin2hex(random_bytes(32));
}

// ── v2.4 : Chargement config avec gestion d'erreur gracieuse ─────────────────
$config      = [];
$configError = null;

if (file_exists(CONFIG_FILE)) {
    $raw     = (string) file_get_contents(CONFIG_FILE);
    $decoded = json_decode($raw, true);

    if ($decoded === null) {
        // JSON malformé : tenter le backup
        $configError = 'config.json invalide : ' . json_last_error_msg();
        $backupFile  = CONFIG_FILE . '.bak';
        if (file_exists($backupFile)) {
            $decoded = json_decode((string) file_get_contents($backupFile), true);
            if (is_array($decoded)) {
                $config      = $decoded;
                $configError .= ' — Backup chargé automatiquement. Corrigez le fichier principal via SSH.';
            } else {
                $configError .= ' — Backup aussi invalide. Vérifiez ' . CONFIG_FILE . ' via SSH.';
            }
        } else {
            $configError .= ' — Aucun backup disponible. Vérifiez ' . CONFIG_FILE . ' via SSH.';
        }
    } else {
        $config = $decoded;
    }
} else {
    $configError = 'config.json introuvable (' . CONFIG_FILE . '). Le système n\'est peut-être pas encore configuré.';
}

$establishment  = $config['establishment'] ?? [];
$reassurance    = $config['reassurance']   ?? ['message' => ''];
$wifiChannel    = intval($config['wifiChannel'] ?? 11);
$enableLoRa     = $config['enableLoRa']     ?? false;
$enableEthernet = $config['enableEthernet'] ?? false;

// ── Statut des services ───────────────────────────────────────────────────────
function svc_active(string $name): bool {
    exec('systemctl is-active --quiet ' . escapeshellarg($name) . ' 2>/dev/null', $o, $r);
    return $r === 0;
}

$services = [
    'hostapd' => svc_active('hostapd'),
    'dnsmasq' => svc_active('dnsmasq'),
    'nginx'   => svc_active('nginx'),
    'lora'    => svc_active('lora-service'),
];

// ── Hash intégrité ────────────────────────────────────────────────────────────
$hashAge = file_exists(HASH_FILE)
    ? round((time() - filemtime(HASH_FILE)) / 60) . ' min'
    : 'absent';

// ── Mode dégradé actif ? ──────────────────────────────────────────────────────
$degradedMode = file_exists('/var/www/sos-guide/INTEGRITY_ALERT.flag');

// ── Dernières entrées d'audit ─────────────────────────────────────────────────
$auditLines = [];
if (file_exists(AUDIT_LOG)) {
    $lines      = file(AUDIT_LOG);
    $auditLines = array_slice(array_reverse($lines), 0, 5);
}

// ── v2.4 : Détection dynamique de l'interface Ethernet ───────────────────────
// Remplace le eth0 hardcodé de la v2.3
$ethIface = trim((string)(shell_exec(
    "ip -o link show 2>/dev/null | awk -F': ' '/^[0-9]+: (en|eth)/{gsub(/@.*/, \"\", \$2); print \$2; exit}'"
) ?? ''));

$ethIp = '';
if ($ethIface !== '') {
    $ethIp = trim((string)(shell_exec(
        "ip -4 addr show " . escapeshellarg($ethIface)
        . " 2>/dev/null | grep -oP '(?<=inet\\s)\\d+(\\.\\d+){3}' | head -1"
    ) ?? ''));
}

// ── Message flash ─────────────────────────────────────────────────────────────
$flash = ''; $flashType = '';
if (isset($_GET['updated'])) {
    $flash     = '✅ Configuration mise à jour et services rechargés avec succès.';
    $flashType = 'success';
    if (isset($_GET['warn'])) {
        $flash    .= ' ⚠️ Avertissements : ' . htmlspecialchars($_GET['warn']);
        $flashType = 'warning';
    }
} elseif (isset($_GET['error'])) {
    $flash     = '❌ Erreur lors de la mise à jour. Vérifiez les logs.';
    $flashType = 'error';
}

$mapExists = file_exists('/var/www/sos-guide/img/map_location.png');

$types = [
    'erp'         => 'ERP (Public)',
    'ecole'       => 'École',
    'mairie'      => 'Mairie',
    'ehpad'       => 'EHPAD',
    'entreprise'  => 'Entreprise',
    'bar'         => 'Bar/Restaurant',
    'boitedenuit' => 'Discothèque',
    'hopital'     => 'Hôpital/Clinique',
    'gymnase'     => 'Gymnase/PA',
];
?>
<!DOCTYPE html>
<html lang="fr">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>⛑️ SOS-GUIDE — Administration v2.4</title>
<style>
:root{
  --bg:#0f172a;--card:#1e293b;--border:#334155;
  --text:#f1f5f9;--sub:#94a3b8;--muted:#475569;
  --accent:#3b82f6;--green:#22c55e;--red:#ef4444;
  --yellow:#eab308;--r:12px;
}
*{box-sizing:border-box;margin:0;padding:0}
body{background:var(--bg);color:var(--text);font-family:system-ui,-apple-system,sans-serif;
     line-height:1.5;min-height:100vh}
.top-bar{background:#0c1524;border-bottom:1px solid var(--border);
         padding:.75rem 1.5rem;display:flex;align-items:center;
         justify-content:space-between;position:sticky;top:0;z-index:100}
.top-bar h1{font-size:1rem;font-weight:600;display:flex;align-items:center;gap:.5rem}
.top-bar nav{display:flex;gap:.5rem}
.top-bar nav a{font-size:.8rem;color:var(--sub);text-decoration:none;
               padding:.3rem .7rem;border-radius:6px;border:1px solid var(--border)}
.top-bar nav a:hover{border-color:var(--accent);color:var(--accent)}
.layout{display:grid;grid-template-columns:220px 1fr;min-height:calc(100vh - 49px)}
.sidebar{background:#0c1524;border-right:1px solid var(--border);
         padding:1rem;display:flex;flex-direction:column;gap:.25rem}
.sidebar a{display:flex;align-items:center;gap:.6rem;padding:.55rem .75rem;
           border-radius:8px;font-size:.88rem;color:var(--sub);text-decoration:none;
           transition:all .15s}
.sidebar a:hover,.sidebar a.active{background:rgba(59,130,246,.15);color:var(--accent)}
.sidebar .section-label{font-size:.7rem;text-transform:uppercase;letter-spacing:.08em;
                         color:var(--muted);margin:.75rem 0 .25rem .75rem}
.main{padding:1.5rem}
/* Flash messages */
.flash{padding:.8rem 1.2rem;border-radius:var(--r);margin-bottom:1.5rem;font-size:.9rem;font-weight:500}
.flash.success{background:rgba(34,197,94,.15);border:1px solid var(--green);color:var(--green)}
.flash.warning{background:rgba(234,179,8,.15);border:1px solid var(--yellow);color:var(--yellow)}
.flash.error  {background:rgba(239,68,68,.15); border:1px solid var(--red);   color:var(--red)}
.flash.info   {background:rgba(59,130,246,.15);border:1px solid var(--accent);color:var(--accent)}
/* Grids */
.grid4{display:grid;grid-template-columns:repeat(4,1fr);gap:.75rem;margin-bottom:1.5rem}
.stat-card{background:var(--card);border:1px solid var(--border);border-radius:var(--r);padding:.9rem 1rem}
.stat-card .val{font-size:1.5rem;font-weight:600;margin:.2rem 0}
.stat-card .lbl{font-size:.78rem;color:var(--sub)}
/* Cards */
.card{background:var(--card);border:1px solid var(--border);
      border-radius:var(--r);padding:1.25rem 1.5rem;margin-bottom:1.25rem}
.card h2{font-size:1rem;font-weight:600;margin-bottom:1rem;padding-bottom:.75rem;
         border-bottom:1px solid var(--border);display:flex;align-items:center;gap:.5rem}
/* Form */
.form-grid{display:grid;grid-template-columns:repeat(2,1fr);gap:1rem 1.5rem}
.fg-full{grid-column:span 2}
.form-group{display:flex;flex-direction:column;gap:.35rem}
label{font-size:.8rem;font-weight:500;color:var(--sub);text-transform:uppercase;letter-spacing:.04em}
input,textarea,select{background:var(--bg);border:1.5px solid var(--border);
  border-radius:8px;padding:.6rem .9rem;color:var(--text);font-size:.9rem;
  width:100%;transition:border .2s}
input:focus,textarea:focus,select:focus{outline:none;border-color:var(--accent)}
textarea{min-height:70px;resize:vertical}
/* Toggles */
.toggle-row{display:flex;align-items:center;justify-content:space-between;
            padding:.6rem 0;border-bottom:1px solid var(--border);font-size:.9rem}
.toggle-row:last-child{border:none}
.toggle{position:relative;width:44px;height:24px;flex-shrink:0}
.toggle input{opacity:0;width:0;height:0}
.toggle-slider{position:absolute;inset:0;background:var(--border);
               border-radius:24px;cursor:pointer;transition:.2s}
.toggle-slider:before{content:'';position:absolute;width:18px;height:18px;
  background:white;border-radius:50%;left:3px;top:3px;transition:.2s}
.toggle input:checked + .toggle-slider{background:var(--accent)}
.toggle input:checked + .toggle-slider:before{transform:translateX(20px)}
/* Buttons */
.btn{display:inline-flex;align-items:center;justify-content:center;gap:.4rem;
     padding:.65rem 1.4rem;border-radius:40px;font-weight:600;font-size:.88rem;
     border:none;cursor:pointer;transition:all .15s}
.btn-primary{background:var(--accent);color:white}
.btn-primary:hover{background:#2563eb}
.btn-danger{background:rgba(239,68,68,.15);color:var(--red);border:1px solid var(--red)}
.btn-danger:hover{background:var(--red);color:white}
.btn-ghost{background:transparent;color:var(--sub);border:1px solid var(--border)}
.btn-ghost:hover{border-color:var(--accent);color:var(--accent)}
.btn-sm{padding:.4rem 1rem;font-size:.8rem}
.btn-group{display:flex;gap:.75rem;margin-top:1.25rem;flex-wrap:wrap}
/* Services */
.svc-row{display:flex;align-items:center;gap:.75rem;padding:.5rem 0;
         border-bottom:1px solid var(--border);font-size:.88rem}
.svc-row:last-child{border:none}
.dot{width:9px;height:9px;border-radius:50%;flex-shrink:0}
.dot.ok {background:var(--green);box-shadow:0 0 8px var(--green)}
.dot.err{background:var(--red);  box-shadow:0 0 8px var(--red)}
.dot.off{background:var(--muted)}
.dot.warn{background:var(--yellow);box-shadow:0 0 8px var(--yellow)}
.svc-name{flex:1;font-weight:500}
.svc-action{font-size:.75rem;color:var(--sub)}
/* Audit */
.audit-row{font-size:.75rem;padding:.4rem 0;border-bottom:1px solid var(--border);
           color:var(--sub);font-family:monospace;white-space:nowrap;
           overflow:hidden;text-overflow:ellipsis}
.audit-row:last-child{border:none}
/* Badges */
.badge{display:inline-block;font-size:.72rem;padding:.15rem .5rem;border-radius:4px;font-weight:500;margin-left:.4rem}
.badge-ok  {background:rgba(34,197,94,.15); color:var(--green)}
.badge-warn{background:rgba(234,179,8,.15); color:var(--yellow)}
.badge-err {background:rgba(239,68,68,.15); color:var(--red)}
/* Reload banner */
.reload-banner{background:rgba(59,130,246,.08);border:1px solid rgba(59,130,246,.3);
               border-radius:var(--r);padding:1rem 1.25rem;margin-bottom:1.25rem;
               display:flex;align-items:center;gap:1rem;flex-wrap:wrap}
.reload-banner .icon{font-size:1.8rem;flex-shrink:0}
.reload-banner p{font-size:.85rem;color:var(--sub);margin:.2rem 0 0}
.reload-banner strong{color:var(--text)}
#reloadResult{margin-top:.75rem;font-size:.82rem;display:none;width:100%}
/* Mode dégradé banner */
.degraded-banner{background:rgba(239,68,68,.12);border:1px solid var(--red);
                 border-radius:var(--r);padding:1rem 1.25rem;margin-bottom:1.25rem;
                 font-size:.88rem;color:var(--red)}
.degraded-banner strong{display:block;margin-bottom:.3rem}
/* Privacy */
.privacy-note{font-size:.72rem;color:var(--muted);margin-top:1rem;padding:.5rem;
              border:1px solid var(--border);border-radius:8px;line-height:1.6}
@media(max-width:768px){
  .layout{grid-template-columns:1fr}
  .sidebar{display:none}
  .form-grid,.grid4{grid-template-columns:1fr}
  .fg-full{grid-column:span 1}
}
</style>
</head>
<body>

<div class="top-bar">
  <h1>⛑️ SOS-GUIDE Administration
    <span class="badge badge-ok">v2.4</span>
    <?php if ($degradedMode): ?>
      <span class="badge badge-err">MODE DÉGRADÉ</span>
    <?php endif; ?>
  </h1>
  <nav>
    <a href="/">← Portail</a>
    <a href="/admin">⚙️ Config</a>
    <?php if (!empty($ethIp)): ?>
    <a href="#ssh" title="SSH : pi@<?= htmlspecialchars($ethIp) ?> (<?= htmlspecialchars($ethIface) ?>)">🔐 SSH</a>
    <?php endif; ?>
    <a href="PRIVACY.md" target="_blank">🔒 nLPD</a>
  </nav>
</div>

<div class="layout">
  <nav class="sidebar">
    <span class="section-label">Configuration</span>
    <a href="#lieu"     class="active">🏢 Lieu</a>
    <a href="#contacts">📞 Contacts</a>
    <a href="#reseau">📡 Réseau WiFi</a>
    <a href="#lora">📻 LoRa mesh</a>
    <a href="#carte">🗺️ Carte</a>
    <span class="section-label">Système</span>
    <a href="#services">⚡ Services</a>
    <a href="#securite">🔒 Sécurité</a>
    <a href="#audit">📋 Audit</a>
  </nav>

  <main class="main">

    <?php if ($degradedMode): ?>
    <div class="degraded-banner">
      <strong>⚠️ Système en mode dégradé</strong>
      Le contrôle d'intégrité SHA256 a détecté une anomalie.
      PHP-FPM peut être arrêté — le portail HTML statique reste accessible.
      <br>Vérifiez via SSH : <code>sudo bash /usr/local/bin/sos-guide-boot-check.sh</code>
      puis <code>sudo bash /usr/local/bin/sos-guide-regen-hash.sh</code>
    </div>
    <?php endif; ?>

    <?php if ($configError): ?>
    <div class="flash error">
      ⚠️ <?= htmlspecialchars($configError) ?>
      <br><small>Fichier : <?= CONFIG_FILE ?> — Corriger manuellement via SSH puis recharger cette page.</small>
    </div>
    <?php endif; ?>

    <?php if ($flash): ?>
    <div class="flash <?= $flashType ?>"><?= htmlspecialchars($flash) ?></div>
    <?php endif; ?>

    <!-- Métriques rapides -->
    <div class="grid4">
      <div class="stat-card">
        <div class="lbl">Services actifs</div>
        <div class="val" style="color:var(--<?= array_sum(array_values($services)) >= 3 ? 'green' : 'red' ?>)">
          <?= array_sum(array_values($services)) ?>/4
        </div>
        <div class="lbl">hostapd dnsmasq nginx lora</div>
      </div>
      <div class="stat-card">
        <div class="lbl">Hash intégrité</div>
        <div class="val" style="font-size:1rem;color:var(--<?= file_exists(HASH_FILE) ? 'green' : 'red' ?>)">
          <?= file_exists(HASH_FILE) ? '✓' : '✗' ?>
        </div>
        <div class="lbl">Màj il y a <?= $hashAge ?></div>
      </div>
      <div class="stat-card">
        <div class="lbl">Canal WiFi</div>
        <div class="val"><?= $wifiChannel ?></div>
        <div class="lbl">EU : 1, 6 ou 11</div>
      </div>
      <div class="stat-card">
        <div class="lbl">LoRa mesh</div>
        <div class="val" style="color:var(--<?= $enableLoRa ? 'green' : 'muted' ?>)">
          <?= $enableLoRa ? 'ON' : 'OFF' ?>
        </div>
        <div class="lbl">868.1 MHz EU868</div>
      </div>
    </div>

    <!-- Reload à chaud -->
    <div class="reload-banner" id="reloadBanner">
      <span class="icon">🔄</span>
      <div style="flex:1">
        <strong>Appliquer les changements réseau sans redémarrage</strong>
        <p>nginx (zero-downtime) · dnsmasq (baux conservés) · hostapd (~3s si SSID/WPA/canal changé)</p>
        <div id="reloadResult"></div>
      </div>
      <div style="display:flex;gap:.5rem;flex-wrap:wrap">
        <button class="btn btn-ghost btn-sm" onclick="reloadNetwork(false)">🔄 Reload services</button>
        <button class="btn btn-danger btn-sm" onclick="reloadNetwork(true)"
                title="Redémarre hostapd — clients WiFi reconnectés (~3s)">📡 Reload WiFi</button>
      </div>
    </div>

    <form method="post" action="update_config.php">
      <input type="hidden" name="csrf_token" id="csrf_token"
             value="<?= htmlspecialchars($_SESSION['csrf_token']) ?>">

      <!-- LIEU -->
      <div class="card" id="lieu">
        <h2>🏢 Informations du lieu</h2>
        <div class="form-grid">
          <div class="form-group fg-full">
            <label>Nom du lieu / nœud *</label>
            <input type="text" name="name" required maxlength="128"
                   value="<?= htmlspecialchars($establishment['name'] ?? '') ?>"
                   placeholder="Ex : Mairie de Genève, Caserne Rive">
          </div>
          <div class="form-group fg-full">
            <label>Adresse complète</label>
            <input type="text" name="address" maxlength="256"
                   value="<?= htmlspecialchars($establishment['address'] ?? '') ?>">
          </div>
          <div class="form-group">
            <label>Latitude GPS (ex: 46.9480)</label>
            <input type="text" name="lat" maxlength="12" pattern="-?\d{1,3}(\.\d{1,8})?"
                   value="<?= htmlspecialchars($establishment['lat'] ?? '') ?>"
                   placeholder="optionnel">
          </div>
          <div class="form-group">
            <label>Longitude GPS (ex: 7.4474)</label>
            <input type="text" name="lon" maxlength="12" pattern="-?\d{1,3}(\.\d{1,8})?"
                   value="<?= htmlspecialchars($establishment['lon'] ?? '') ?>"
                   placeholder="optionnel">
          </div>
          <div class="form-group">
            <label>Type d'établissement</label>
            <select name="type">
              <?php foreach ($types as $v => $l): ?>
              <option value="<?= $v ?>" <?= (($establishment['type'] ?? 'erp') === $v) ? 'selected' : '' ?>>
                <?= htmlspecialchars($l) ?>
              </option>
              <?php endforeach; ?>
            </select>
          </div>
          <div class="form-group">
            <label>Risque local spécifique</label>
            <input type="text" name="localRisk" maxlength="256"
                   value="<?= htmlspecialchars($establishment['localRisk'] ?? '') ?>"
                   placeholder="Ex: Zone SEVESO, inondable">
          </div>
          <div class="form-group fg-full">
            <label>Message de réassurance</label>
            <textarea name="reassuranceMessage" maxlength="512"><?=
              htmlspecialchars($reassurance['message'] ?? '')
            ?></textarea>
          </div>
        </div>
      </div>

      <!-- CONTACTS -->
      <div class="card" id="contacts">
        <h2>📞 Contacts d'urgence locaux</h2>
        <p style="font-size:.8rem;color:var(--sub);margin-bottom:1rem">
          Ces numéros s'affichent sur le portail et <strong>remplacent</strong> les numéros par défaut de la langue sélectionnée.
        </p>
        <div class="form-grid">
          <?php
          // v2.4 : localPoliceNumber ajouté
          $contactFields = [
            ['localCrisisNumber',   '📞 Cellule de crise locale'],
            ['localSamuNumber',     '🚑 SAMU / Ambulance locale'],
            ['localPoliceNumber',   '🚔 Police / Gendarmerie locale'],
            ['localPompiersNumber', '🚒 Pompiers locaux'],
            ['localMairieNumber',   '🏛️ Mairie / Municipalité'],
            ['localPrefecture',     '🏛️ Préfecture / Canton'],
            ['localDsden',          '🎓 DSDEN / Inspection académique'],
            ['localCroixRouge',     '🔴 Croix-Rouge locale'],
            ['localRadioFreq',      '📻 Radio locale (fréquence MHz)'],
          ];
          foreach ($contactFields as [$name, $lbl]):
          ?>
          <div class="form-group">
            <label><?= $lbl ?></label>
            <input type="text" name="<?= $name ?>"
                   value="<?= htmlspecialchars($establishment[$name] ?? '') ?>">
          </div>
          <?php endforeach; ?>
          <div class="form-group fg-full">
            <label>📍 Adresse PCC (Poste de Commandement)</label>
            <input type="text" name="localPccAddress" maxlength="256"
                   value="<?= htmlspecialchars($establishment['localPccAddress'] ?? '') ?>">
          </div>
          <div class="form-group fg-full">
            <label>🚶 Point de rassemblement</label>
            <input type="text" name="localMeetingPoint" maxlength="256"
                   value="<?= htmlspecialchars($establishment['localMeetingPoint'] ?? '') ?>">
          </div>
          <div class="form-group fg-full">
            <label>🗺️ Plan d'évacuation</label>
            <input type="text" name="localEvacuationPlan" maxlength="512"
                   value="<?= htmlspecialchars($establishment['localEvacuationPlan'] ?? '') ?>">
          </div>
        </div>
      </div>

      <!-- RÉSEAU WIFI -->
      <div class="card" id="reseau">
        <h2>📡 Réseau WiFi</h2>
        <div class="form-grid">
          <div class="form-group">
            <label>Canal WiFi (EU : 1, 6 ou 11 recommandés)</label>
            <select name="wifiChannel">
              <?php for ($c = 1; $c <= 13; $c++): ?>
              <option value="<?= $c ?>" <?= $wifiChannel === $c ? 'selected' : '' ?>>
                Canal <?= $c ?><?php if (in_array($c, [1,6,11])): ?> ★<?php endif; ?>
              </option>
              <?php endfor; ?>
            </select>
          </div>
          <div class="form-group">
            <label>Nouveau mot de passe WiFi <small style="text-transform:none;font-weight:400">(vide = inchangé)</small></label>
            <input type="password" name="wifiPassword" minlength="8" maxlength="63"
                   placeholder="8 caractères min — vide = réseau ouvert">
          </div>
        </div>
        <p style="font-size:.8rem;color:var(--sub);margin-top:.75rem">
          ⚠️ Un changement de canal ou de mot de passe nécessite un <strong>Reload WiFi</strong> (~3s d'interruption).
        </p>
      </div>

      <!-- LORA -->
      <div class="card" id="lora">
        <h2>📻 LoRa Mesh</h2>
        <div class="toggle-row">
          <div>
            <strong>Activer le module LoRa (SX1276 / RFM95W)</strong>
            <div style="font-size:.8rem;color:var(--sub)">868.1 MHz · AES-256-GCM · Portée 2–10 km · API :8765</div>
          </div>
          <label class="toggle">
            <input type="checkbox" name="enableLoRa" value="true" <?= $enableLoRa ? 'checked' : '' ?>>
            <span class="toggle-slider"></span>
          </label>
        </div>
        <div class="toggle-row">
          <div>
            <strong>Activer la connexion Ethernet (mises à jour JSON)</strong>
            <div style="font-size:.8rem;color:var(--sub)">Accès Internet pour télécharger les contenus multilingues</div>
          </div>
          <label class="toggle">
            <input type="checkbox" name="enableEthernet" value="true" <?= $enableEthernet ? 'checked' : '' ?>>
            <span class="toggle-slider"></span>
          </label>
        </div>
        <?php if ($enableLoRa && $services['lora']): ?>
        <div style="margin-top:1rem;padding:.6rem;background:rgba(34,197,94,.1);border-radius:8px;font-size:.82rem">
          ✅ lora-service actif ·
          <a href="http://127.0.0.1:8765/stats" style="color:var(--accent)">http://127.0.0.1:8765/stats</a>
        </div>
        <?php elseif ($enableLoRa): ?>
        <div style="margin-top:1rem;padding:.6rem;background:rgba(239,68,68,.1);border-radius:8px;font-size:.82rem;color:var(--red)">
          ✗ lora-service inactif — vérifier : <code>journalctl -u lora-service -f</code>
        </div>
        <?php endif; ?>
      </div>

      <!-- CARTE -->
      <div class="card" id="carte">
        <h2>🗺️ Carte du lieu</h2>
        <div style="display:flex;align-items:center;gap:.75rem;font-size:.9rem">
          <span class="dot <?= $mapExists ? 'ok' : 'off' ?>"></span>
          <?= $mapExists ? '✅ Carte PNG présente (map_location.png)' : '⚠️ Aucune carte PNG' ?>
        </div>
        <p style="font-size:.82rem;color:var(--sub);margin-top:.75rem">
          Pour ajouter une carte :<br>
          <code>sudo bash /usr/local/bin/sos-guide-copy-image.sh /chemin/vers/carte.png</code>
        </p>
      </div>

      <div class="btn-group">
        <button type="submit" class="btn btn-primary">💾 Enregistrer</button>
        <a href="/" class="btn btn-ghost">← Portail</a>
      </div>
    </form>

    <!-- SERVICES -->
    <div class="card" id="services" style="margin-top:1.25rem">
      <h2>⚡ État des services</h2>
      <?php foreach ($services as $name => $active): ?>
      <div class="svc-row">
        <span class="dot <?= $active ? 'ok' : 'err' ?>"></span>
        <span class="svc-name"><?= htmlspecialchars($name) ?></span>
        <span class="svc-action">
          <?= $active
            ? '<span style="color:var(--green)">actif</span>'
            : '<span style="color:var(--red)">arrêté</span>' ?>
        </span>
      </div>
      <?php endforeach; ?>
      <div class="svc-row">
        <span class="dot <?= file_exists(HASH_FILE) ? ($degradedMode ? 'warn' : 'ok') : 'err' ?>"></span>
        <span class="svc-name">hash SHA256 intégrité</span>
        <span class="svc-action" style="color:var(--sub)">
          <?= $degradedMode ? '⚠️ Alerte active' : 'màj il y a ' . $hashAge ?>
        </span>
      </div>
      <?php if (!empty($ethIp)): ?>
      <div class="svc-row" id="ssh">
        <span class="dot ok"></span>
        <span class="svc-name">
          Ethernet
          <span style="font-size:.75rem;color:var(--muted);font-weight:400">(<?= htmlspecialchars($ethIface) ?>)</span>
        </span>
        <span class="svc-action" style="color:var(--sub)">
          <?= htmlspecialchars($ethIp) ?> —
          SSH : <code>ssh pi@<?= htmlspecialchars($ethIp) ?></code>
        </span>
      </div>
      <?php endif; ?>
    </div>

    <!-- AUDIT LOG -->
    <div class="card" id="audit">
      <h2>📋 Journal d'audit (5 dernières entrées)</h2>
      <?php if (empty($auditLines)): ?>
        <div style="font-size:.85rem;color:var(--sub)">Aucune entrée dans le journal.</div>
      <?php else: ?>
        <?php foreach ($auditLines as $line): ?>
          <?php
          $entry = json_decode(trim($line), true);
          if (!$entry) continue;
          $action = $entry['action'] ?? '?';
          $cls = str_contains($action, 'FAIL') || str_contains($action, 'REJECT')
               ? 'badge-err' : (str_contains($action, 'WARN') ? 'badge-warn' : 'badge-ok');
          ?>
          <div class="audit-row">
            <span style="color:var(--muted)"><?= htmlspecialchars(substr($entry['ts'] ?? '', 0, 19)) ?></span>
            <span class="badge <?= $cls ?>"><?= htmlspecialchars($action) ?></span>
            <?php if (!empty($entry['fields_changed'])): ?>
              · <?= htmlspecialchars(implode(', ', $entry['fields_changed'])) ?>
            <?php endif; ?>
            <span style="color:var(--muted)"> — <?= htmlspecialchars($entry['ip'] ?? '') ?></span>
          </div>
        <?php endforeach; ?>
      <?php endif; ?>
    </div>

    <!-- nLPD Notice -->
    <div class="privacy-note">
      🔒 <strong>Confidentialité (nLPD art. 5-6)</strong> — Ce système ne collecte
      aucune donnée personnelle persistante. Les logs réseau sont en mémoire volatile (tmpfs)
      et effacés au redémarrage. Les messages LoRa sont chiffrés AES-256-GCM.
      <a href="PRIVACY.md" target="_blank" style="color:var(--accent)">Politique complète →</a>
    </div>

  </main>
</div>

<script>
async function reloadNetwork(reloadWifi) {
    const btn    = event.target;
    const result = document.getElementById('reloadResult');

    btn.disabled    = true;
    btn.textContent = '⏳ Rechargement...';
    result.style.display = 'block';
    result.style.color   = 'var(--sub)';
    result.textContent   = 'Envoi de la commande...';

    try {
        const body = new FormData();
        body.append('reload_wifi',  reloadWifi ? 'true' : 'false');
        // v2.4 : CSRF token inclus (obligatoire — fix sécurité)
        body.append('csrf_token', document.getElementById('csrf_token').value);

        const resp = await fetch('/api/reload-network-proxy', {
            method: 'POST',
            body
        });
        const data = await resp.json();

        if (data.success) {
            result.style.color = 'var(--green)';
            result.textContent = '✅ ' + (data.log || []).join(' · ');
        } else {
            result.style.color = 'var(--yellow)';
            result.textContent = '⚠️ Partiel — ' + (data.errors || []).join(', ');
        }
    } catch(e) {
        result.style.color = 'var(--red)';
        result.textContent = '❌ Erreur réseau : ' + e.message;
    } finally {
        btn.disabled    = false;
        btn.textContent = reloadWifi ? '📡 Reload WiFi' : '🔄 Reload services';
        setTimeout(() => location.reload(), 3000);
    }
}
</script>

</body>
</html>
