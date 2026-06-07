<?php
/**
 * SOS-GUIDE — lora-portal.php v2.3
 * Page LoRa du portail captif : envoi et réception de messages mesh d'urgence
 *
 * Accessible depuis le portail captif : http://10.0.0.1/lora
 * Communique avec lora-service.py via http://127.0.0.1:8765
 *
 * Sécurité :
 *   - Rate-limit : 5 messages / 10 minutes par IP
 *   - Contenu sanitisé (max 200 chars, no HTML)
 *   - Aucune donnée personnelle persistée (RAM only via lora-service)
 *   - Conformité nLPD §2.3 : messages pseudonymisés (node_id hex)
 */

header('X-Content-Type-Options: nosniff');
header('X-Frame-Options: SAMEORIGIN');

define('LORA_API',   'http://127.0.0.1:8765');
define('RATE_FILE',  '/run/sos-guide/lora_rate.json');
define('MAX_MSG',    5);
define('RATE_WIN',   600);
define('MAX_LEN',    200);

// ── Config & langue ───────────────────────────────────────────────────────────
$config = [];
if (file_exists('/var/www/sos-guide/data/config.json')) {
    $config = json_decode(file_get_contents('/var/www/sos-guide/data/config.json'), true) ?? [];
}
$loraEnabled = $config['enableLoRa'] ?? false;
$nodeName    = $config['establishment']['name'] ?? 'SOS-GUIDE';

// ── Rate limiting ─────────────────────────────────────────────────────────────
function check_rate(string $ip): array {
    $data = [];
    if (file_exists(RATE_FILE)) {
        $data = json_decode(file_get_contents(RATE_FILE), true) ?? [];
    }
    $key = md5($ip);
    $now = time();
    // Purger les entrées expirées
    foreach ($data as $k => $v) {
        if ($now - ($v['first'] ?? 0) > RATE_WIN) unset($data[$k]);
    }
    if (!isset($data[$key])) {
        $data[$key] = ['first' => $now, 'count' => 0];
    }
    $remaining = MAX_MSG - $data[$key]['count'];
    $wait      = $remaining > 0 ? 0 : RATE_WIN - ($now - $data[$key]['first']);
    return ['data' => $data, 'key' => $key, 'remaining' => $remaining, 'wait' => $wait];
}

// ── Appel API LoRa ────────────────────────────────────────────────────────────
function lora_api(string $path, string $method = 'GET', array $body = []): ?array {
    $ctx = stream_context_create(['http' => [
        'method'  => $method,
        'header'  => "Content-Type: application/json\r\n",
        'content' => $method === 'POST' ? json_encode($body) : null,
        'timeout' => 3,
        'ignore_errors' => true,
    ]]);
    $res = @file_get_contents(LORA_API . $path, false, $ctx);
    if ($res === false) return null;
    return json_decode($res, true);
}

// ── Traitement POST (envoi message) ──────────────────────────────────────────
$flashMsg  = '';
$flashType = '';

if ($_SERVER['REQUEST_METHOD'] === 'POST' && $loraEnabled) {
    $body    = trim(strip_tags((string)($_POST['body'] ?? '')));
    $type    = in_array($_POST['type'] ?? 'msg', ['msg','alert'], true)
               ? $_POST['type'] : 'msg';
    $ip      = $_SERVER['REMOTE_ADDR'] ?? '0.0.0.0';

    if (mb_strlen($body) < 1) {
        $flashMsg = 'Message vide.'; $flashType = 'warn';
    } elseif (mb_strlen($body) > MAX_LEN) {
        $flashMsg = 'Message trop long (max ' . MAX_LEN . ' caractères).'; $flashType = 'warn';
    } else {
        $rate = check_rate($ip);
        if ($rate['remaining'] <= 0) {
            $mins = ceil($rate['wait'] / 60);
            $flashMsg = "Trop de messages. Réessayez dans $mins minute(s).";
            $flashType = 'warn';
        } else {
            $result = lora_api('/send', 'POST', ['body' => $body, 'type' => $type]);
            if ($result && ($result['success'] ?? false)) {
                // Incrémenter le compteur
                $rate['data'][$rate['key']]['count']++;
                @file_put_contents(RATE_FILE, json_encode($rate['data']), LOCK_EX);
                $flashMsg  = $type === 'alert'
                    ? '🚨 Alerte envoyée sur le réseau mesh !'
                    : '✅ Message transmis sur le réseau LoRa.';
                $flashType = 'ok';
            } else {
                $flashMsg  = 'Erreur de transmission LoRa. Vérifiez que le module est connecté.';
                $flashType = 'err';
            }
        }
    }
}

// ── Récupérer les messages et stats ──────────────────────────────────────────
$messages = [];
$stats    = null;
$apiOk    = false;

if ($loraEnabled) {
    $stats = lora_api('/stats');
    $apiOk = ($stats !== null);
    if ($apiOk) {
        $raw      = lora_api('/messages?limit=30&since=' . (time() - 3600));
        $messages = $raw['messages'] ?? [];
        // Plus récents en premier
        usort($messages, fn($a, $b) => ($b['ts'] ?? 0) - ($a['ts'] ?? 0));
    }
}

// ── Formatage de la date ──────────────────────────────────────────────────────
function fmt_time(int $ts): string {
    $diff = time() - $ts;
    if ($diff < 60)   return 'il y a ' . $diff . 's';
    if ($diff < 3600) return 'il y a ' . floor($diff/60) . 'min';
    return date('H:i', $ts);
}
?>
<!DOCTYPE html>
<html lang="fr">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<title>📡 LoRa Mesh — <?= htmlspecialchars($nodeName) ?></title>
<link rel="icon" type="image/svg+xml" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 100 100'%3E%3Ctext y='80' font-size='80'%3E📡%3C/text%3E%3C/svg%3E">
<style>
:root{
  --bg:#060a12;--bg1:#0c1120;--card:#0f1826;--border:rgba(255,255,255,.07);
  --text:#e8eef8;--sub:#6b7fa3;--r:14px;
  --green:#22c55e;--red:#ef4444;--amber:#f59e0b;--blue:#3b82f6;
}
*{box-sizing:border-box;margin:0;padding:0}
body{background:var(--bg);color:var(--text);font-family:system-ui,-apple-system,'Segoe UI',sans-serif;
  min-height:100vh;padding-bottom:2rem}
.topbar{background:rgba(6,10,18,.95);backdrop-filter:blur(12px);border-bottom:1px solid var(--border);
  padding:.75rem 1.25rem;display:flex;align-items:center;justify-content:space-between;
  position:sticky;top:0;z-index:100}
.topbar-left{display:flex;align-items:center;gap:.6rem;font-weight:600;font-size:.9rem}
.topbar-right{display:flex;align-items:center;gap:.5rem}
.status-dot{width:8px;height:8px;border-radius:50%;flex-shrink:0}
.dot-ok {background:var(--green);box-shadow:0 0 6px var(--green)}
.dot-off{background:var(--sub)}
.dot-err{background:var(--red);box-shadow:0 0 6px var(--red)}
.back-btn{font-size:.8rem;color:var(--sub);text-decoration:none;
  padding:.3rem .7rem;border-radius:6px;border:1px solid var(--border)}
.back-btn:hover{color:var(--text);border-color:rgba(255,255,255,.2)}
.main{max-width:680px;margin:0 auto;padding:1.25rem}
.flash{padding:.7rem 1rem;border-radius:10px;font-size:.85rem;font-weight:500;
  margin-bottom:1rem;display:flex;align-items:center;gap:.5rem}
.flash.ok  {background:rgba(34,197,94,.12); border:1px solid rgba(34,197,94,.3); color:var(--green)}
.flash.warn{background:rgba(245,158,11,.12);border:1px solid rgba(245,158,11,.3);color:var(--amber)}
.flash.err {background:rgba(239,68,68,.12); border:1px solid rgba(239,68,68,.3); color:var(--red)}
.card{background:var(--card);border:1px solid var(--border);border-radius:var(--r);
  padding:1.25rem;margin-bottom:1rem}
.card-title{font-size:.8rem;font-weight:600;color:var(--sub);text-transform:uppercase;
  letter-spacing:.08em;margin-bottom:1rem;display:flex;align-items:center;
  justify-content:space-between}
/* Formulaire envoi */
.compose{display:flex;flex-direction:column;gap:.75rem}
.type-row{display:flex;gap:.5rem}
.type-btn{flex:1;padding:.5rem;border-radius:8px;border:1.5px solid var(--border);
  background:transparent;color:var(--sub);font-size:.82rem;font-weight:500;cursor:pointer;
  transition:all .15s}
.type-btn.active.msg  {background:rgba(59,130,246,.15);border-color:var(--blue);color:var(--blue)}
.type-btn.active.alert{background:rgba(239,68,68,.15); border-color:var(--red); color:var(--red)}
.compose textarea{background:var(--bg);border:1.5px solid var(--border);border-radius:10px;
  color:var(--text);font-size:.9rem;padding:.75rem 1rem;resize:vertical;min-height:80px;
  font-family:inherit;transition:border .2s}
.compose textarea:focus{outline:none;border-color:var(--blue)}
.compose-footer{display:flex;align-items:center;justify-content:space-between}
.char-count{font-size:.75rem;color:var(--sub)}
.char-count.near{color:var(--amber)}
.char-count.over{color:var(--red)}
.send-btn{padding:.6rem 1.4rem;border-radius:40px;border:none;font-weight:600;
  font-size:.85rem;cursor:pointer;transition:all .15s}
.send-msg  {background:var(--blue);color:#fff}
.send-alert{background:var(--red); color:#fff}
.send-btn:active{transform:scale(.96)}
.send-btn:disabled{opacity:.5;cursor:not-allowed}
/* Stats */
.stats-grid{display:grid;grid-template-columns:repeat(3,1fr);gap:.5rem}
.stat{background:var(--bg);border-radius:8px;padding:.6rem .75rem;text-align:center}
.stat .v{font-size:1.1rem;font-weight:600;color:var(--text)}
.stat .l{font-size:.68rem;color:var(--sub);margin-top:.1rem}
/* Messages */
.msg-list{display:flex;flex-direction:column;gap:.5rem}
.msg-item{background:var(--bg);border-radius:10px;padding:.75rem 1rem;
  border-left:3px solid var(--border)}
.msg-item.local   {border-left-color:var(--blue)}
.msg-item.received{border-left-color:var(--green)}
.msg-item.alert   {border-left-color:var(--red);background:rgba(239,68,68,.05)}
.msg-item.relayed {border-left-color:var(--amber)}
.msg-head{display:flex;align-items:center;justify-content:space-between;margin-bottom:.3rem}
.msg-meta{font-size:.68rem;color:var(--sub);display:flex;align-items:center;gap:.4rem}
.msg-badge{font-size:.62rem;padding:.1rem .4rem;border-radius:3px;font-weight:600}
.mb-local   {background:rgba(59,130,246,.15);color:var(--blue)}
.mb-received{background:rgba(34,197,94,.15); color:var(--green)}
.mb-alert   {background:rgba(239,68,68,.15); color:var(--red)}
.mb-relayed {background:rgba(245,158,11,.15);color:var(--amber)}
.msg-body{font-size:.88rem;color:var(--text);line-height:1.5;word-break:break-word}
.msg-src{font-size:.68rem;color:var(--sub);margin-top:.3rem;font-family:monospace}
.empty-state{text-align:center;padding:2rem;color:var(--sub);font-size:.85rem}
.empty-state .icon{font-size:2rem;display:block;margin-bottom:.5rem;opacity:.4}
/* Offline banner */
.offline-banner{background:rgba(245,158,11,.1);border:1px solid rgba(245,158,11,.3);
  border-radius:var(--r);padding:1rem 1.25rem;text-align:center;margin-bottom:1rem}
.offline-banner strong{color:var(--amber);display:block;font-size:.9rem}
.offline-banner p{font-size:.78rem;color:var(--sub);margin-top:.35rem}
/* Refresh auto */
.refresh-hint{font-size:.7rem;color:var(--sub);text-align:center;margin-top:.75rem}
</style>
</head>
<body>
<div class="topbar">
  <div class="topbar-left">
    <span class="status-dot <?= $apiOk ? 'dot-ok' : ($loraEnabled ? 'dot-err' : 'dot-off') ?>"></span>
    📡 LoRa Mesh — <?= htmlspecialchars($nodeName) ?>
  </div>
  <div class="topbar-right">
    <?php if ($apiOk && $stats): ?>
      <span style="font-size:.72rem;color:var(--sub)"><?= number_format($stats['freq_mhz'] ?? 868.1, 1) ?> MHz</span>
    <?php endif; ?>
    <a href="/" class="back-btn">← Portail</a>
  </div>
</div>

<div class="main">
<?php if (!$loraEnabled): ?>
  <div class="offline-banner">
    <strong>📡 Module LoRa non activé</strong>
    <p>Le module LoRa est désactivé sur ce nœud.<br>
    Activez-le dans <a href="/admin" style="color:var(--amber)">l'interface d'administration</a>.</p>
  </div>
<?php elseif (!$apiOk): ?>
  <div class="offline-banner">
    <strong>⚠️ Service LoRa indisponible</strong>
    <p>Le service de communication LoRa ne répond pas.<br>
    Vérifiez que le module SX1276 / RAK3172 est connecté.</p>
  </div>
<?php endif; ?>

<?php if ($flashMsg): ?>
  <div class="flash <?= $flashType ?>"><?= htmlspecialchars($flashMsg) ?></div>
<?php endif; ?>

<?php if ($loraEnabled): ?>
<!-- Formulaire envoi -->
<div class="card">
  <div class="card-title">
    <span>✉️ Envoyer un message</span>
    <?php if ($apiOk): ?>
      <span style="font-size:.7rem;color:var(--green);font-weight:400">● connecté</span>
    <?php endif; ?>
  </div>
  <form method="POST" action="/lora" id="sendForm">
    <div class="compose">
      <div class="type-row" id="typeRow">
        <button type="button" class="type-btn msg active" data-type="msg" onclick="setType('msg')">
          💬 Message
        </button>
        <button type="button" class="type-btn alert" data-type="alert" onclick="setType('alert')">
          🚨 Alerte d'urgence
        </button>
      </div>
      <input type="hidden" name="type" id="typeInput" value="msg">
      <textarea name="body" id="msgBody" maxlength="200"
        placeholder="Écrivez votre message d'urgence… (max 200 caractères)"
        oninput="updateCount()"
        <?= !$apiOk ? 'disabled' : '' ?>></textarea>
      <div class="compose-footer">
        <span class="char-count" id="charCount">0 / 200</span>
        <button type="submit" class="send-btn send-msg" id="sendBtn"
          <?= !$apiOk ? 'disabled' : '' ?>>
          Envoyer →
        </button>
      </div>
    </div>
  </form>
</div>

<!-- Statistiques -->
<?php if ($apiOk && $stats): ?>
<div class="card">
  <div class="card-title">📊 Réseau mesh</div>
  <div class="stats-grid">
    <div class="stat">
      <div class="v"><?= intval($stats['total_msgs'] ?? 0) ?></div>
      <div class="l">Messages total</div>
    </div>
    <div class="stat">
      <div class="v"><?= intval($stats['received'] ?? 0) ?></div>
      <div class="l">Reçus</div>
    </div>
    <div class="stat">
      <div class="v"><?= intval($stats['relayed'] ?? 0) ?></div>
      <div class="l">Relayés</div>
    </div>
    <div class="stat">
      <div class="v"><?= $stats['hw_ready'] ? '✓' : '~' ?></div>
      <div class="l">Hardware</div>
    </div>
    <div class="stat">
      <div class="v">SF<?= intval($stats['sf'] ?? 7) ?></div>
      <div class="l">Spreading</div>
    </div>
    <div class="stat">
      <div class="v"><?= intval(($stats['uptime'] ?? 0)/60) ?>min</div>
      <div class="l">Uptime</div>
    </div>
  </div>
</div>
<?php endif; ?>

<!-- Messages reçus -->
<div class="card">
  <div class="card-title">
    <span>📨 Messages (dernière heure)</span>
    <span style="font-size:.7rem;color:var(--sub);font-weight:400"><?= count($messages) ?> message<?= count($messages)>1?'s':'' ?></span>
  </div>
  <?php if (empty($messages)): ?>
    <div class="empty-state">
      <span class="icon">📡</span>
      Aucun message reçu sur le réseau mesh pour l'instant.<br>
      Les messages des nœuds voisins apparaîtront ici.
    </div>
  <?php else: ?>
    <div class="msg-list">
    <?php foreach ($messages as $msg):
      $isLocal   = $msg['local']   ?? false;
      $isRelayed = $msg['relayed'] ?? false;
      $msgType   = $msg['type']    ?? 'msg';
      $isAlert   = $msgType === 'alert';
      $cls = $isAlert ? 'alert' : ($isLocal ? 'local' : ($isRelayed ? 'relayed' : 'received'));
      $badgeCls  = 'mb-' . $cls;
      $badgeTxt  = $isAlert ? '🚨 ALERTE' : ($isLocal ? 'Envoyé' : ($isRelayed ? 'Relayé' : 'Reçu'));
    ?>
      <div class="msg-item <?= $cls ?>">
        <div class="msg-head">
          <span class="msg-badge <?= $badgeCls ?>"><?= $badgeTxt ?></span>
          <span style="font-size:.68rem;color:var(--sub)"><?= fmt_time(intval($msg['ts'] ?? 0)) ?></span>
        </div>
        <div class="msg-body"><?= htmlspecialchars($msg['body'] ?? '') ?></div>
        <?php if (!$isLocal): ?>
          <div class="msg-src">nœud : <?= htmlspecialchars(substr($msg['src'] ?? '????????', 0, 8)) ?> · TTL restant : <?= intval($msg['ttl'] ?? 0) ?></div>
        <?php endif; ?>
      </div>
    <?php endforeach; ?>
    </div>
    <div class="refresh-hint">🔄 Actualisation automatique toutes les 15 secondes</div>
  <?php endif; ?>
</div>

<?php endif; // $loraEnabled ?>

<!-- Note nLPD -->
<div style="font-size:.68rem;color:var(--sub);text-align:center;padding:.5rem;line-height:1.6">
  🔒 Les messages LoRa sont chiffrés AES-256-GCM et stockés uniquement en RAM.<br>
  Aucune donnée personnelle persistée — conformité nLPD RS 235.1
</div>
</div>

<script>
let msgType = 'msg';

function setType(t) {
  msgType = t;
  document.getElementById('typeInput').value = t;
  document.querySelectorAll('.type-btn').forEach(b => {
    b.classList.toggle('active', b.dataset.type === t);
  });
  const btn = document.getElementById('sendBtn');
  if (btn) {
    btn.textContent = t === 'alert' ? '🚨 Envoyer alerte →' : 'Envoyer →';
    btn.className = 'send-btn send-' + t;
  }
}

function updateCount() {
  const ta  = document.getElementById('msgBody');
  const el  = document.getElementById('charCount');
  if (!ta || !el) return;
  const len = ta.value.length;
  el.textContent = len + ' / 200';
  el.className = 'char-count' + (len > 190 ? ' over' : len > 160 ? ' near' : '');
}

// Actualisation auto des messages toutes les 15s
setTimeout(() => { location.reload(); }, 15000);

// Submit : désactiver le bouton pour éviter le double-envoi
document.getElementById('sendForm')?.addEventListener('submit', function() {
  const btn = document.getElementById('sendBtn');
  if (btn) { btn.disabled = true; btn.textContent = 'Envoi…'; }
});
</script>
</body>
</html>
