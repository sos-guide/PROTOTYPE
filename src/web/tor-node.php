<?php
/**
 * SOS-GUIDE — tor-node.php v2.5
 *
 * Surface unique du service caché Tor (canal Ethernet → .onion).
 * Sert l'IDENTIFICATION du nœud et le MANIFESTE DE MISE À JOUR — jamais le
 * portail captif. Nginx ne route que ce fichier (+ /data/) sur 127.0.0.1:9080.
 *
 *   GET  /                      → page d'identité humaine (HTML)
 *   GET  /?format=json          → identité + manifeste, lisible par un script
 *   GET  /?manifest=1           → manifeste seul (SHA256 de chaque data/*.json)
 *
 * Aucune écriture, aucune commande système : lecture seule, sans authentification
 * (l'anonymat et l'adressage .onion forment la couche d'accès).
 */

define('WEB_ROOT',    '/var/www/sos-guide');
define('CONFIG_FILE', WEB_ROOT . '/data/config.json');
define('DATA_DIR',    WEB_ROOT . '/data');
define('VERSION_FILE', '/var/lib/sos-guide/version');
define('ONION_FILE',   '/var/lib/sos-guide/onion_hostname');
define('PUBKEY_FILE',  '/var/lib/sos-guide/node_pubkey.pem');

$config  = is_readable(CONFIG_FILE)
    ? (json_decode((string) file_get_contents(CONFIG_FILE), true) ?? [])
    : [];
$estab   = $config['establishment'] ?? [];
$version = is_readable(VERSION_FILE) ? trim((string) file_get_contents(VERSION_FILE)) : '2.5';
$onion   = is_readable(ONION_FILE)   ? trim((string) file_get_contents(ONION_FILE))   : null;

// Empreinte de clé publique du nœud (identification) si le keypair existe.
$pubFingerprint = null;
if (is_readable(PUBKEY_FILE)) {
    $pubFingerprint = hash('sha256', (string) file_get_contents(PUBKEY_FILE));
}

// ── Manifeste de mise à jour : SHA256 de chaque fichier de contenu ───────────
function build_manifest(): array {
    $files = glob(DATA_DIR . '/*.json') ?: [];
    $out = [];
    foreach ($files as $f) {
        $name = basename($f);
        if ($name === 'config.json') continue; // jamais distribué (données du lieu)
        $out[$name] = [
            'sha256' => hash_file('sha256', $f),
            'bytes'  => filesize($f),
            'mtime'  => gmdate('c', filemtime($f)),
        ];
    }
    ksort($out);
    return $out;
}

$identity = [
    'service'      => 'sos-guide-node',
    'version'      => $version,
    'name'         => $estab['name']    ?? null,
    'country'      => $estab['country'] ?? null,
    'type'         => $estab['type']    ?? null,
    'onion'        => $onion,
    'pubkey_sha256' => $pubFingerprint,
    'channels'     => [
        'wifi' => 'page statique de survie (10.0.0.1, hors-ligne)',
        'lora' => 'messages d\'urgence chiffrés (mesh 868 MHz)',
        'tor'  => 'mises à jour + identification (ce service caché)',
    ],
    'generated_at' => gmdate('c'),
];

// ── Sorties machine ───────────────────────────────────────────────────────────
if (isset($_GET['manifest'])) {
    header('Content-Type: application/json; charset=utf-8');
    echo json_encode(['version' => $version, 'files' => build_manifest()],
        JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES);
    exit;
}
if (($_GET['format'] ?? '') === 'json') {
    header('Content-Type: application/json; charset=utf-8');
    echo json_encode($identity + ['manifest' => build_manifest()],
        JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
    exit;
}

// ── Page d'identité humaine ───────────────────────────────────────────────────
$manifest = build_manifest();
header('Content-Type: text/html; charset=utf-8');
?>
<!DOCTYPE html>
<html lang="fr">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<meta name="robots" content="noindex,nofollow">
<title>⛑️ Nœud SOS-GUIDE — Identification (Tor)</title>
<link rel="stylesheet" href="/lib/sos-theme.css">
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{background:var(--bg);color:var(--text);font-family:system-ui,sans-serif;
     line-height:1.6;padding:2rem 1rem;max-width:720px;margin:0 auto}
h1{font-size:1.4rem;margin-bottom:.3rem;display:flex;align-items:center;gap:.5rem}
.sub{color:var(--sub);font-size:.9rem;margin-bottom:1.5rem}
.card{background:var(--card);border:1px solid var(--border);border-radius:var(--r);
      padding:1.25rem 1.5rem;margin-bottom:1.25rem}
.card h2{font-size:1rem;margin-bottom:.9rem;padding-bottom:.6rem;
         border-bottom:1px solid var(--border)}
.kv{display:grid;grid-template-columns:170px 1fr;gap:.4rem 1rem;font-size:.88rem}
.kv dt{color:var(--sub)}
.kv dd{word-break:break-all;font-family:monospace}
.chan{display:flex;gap:.6rem;padding:.5rem 0;border-bottom:1px solid var(--border);font-size:.88rem}
.chan:last-child{border:none}
.chan b{color:var(--accent)}
table{width:100%;border-collapse:collapse;font-size:.8rem}
th,td{text-align:left;padding:.4rem .5rem;border-bottom:1px solid var(--border)}
td.h{font-family:monospace;color:var(--sub);word-break:break-all}
.tag{display:inline-block;background:rgba(124,58,237,.18);color:#a78bfa;
     font-size:.72rem;padding:.15rem .5rem;border-radius:4px}
</style>
</head>
<body>
<h1>⛑️ Nœud SOS-GUIDE <span class="tag">Tor · nœud de secours</span></h1>
<p class="sub">Canal Ethernet → service caché. Identification et mises à jour uniquement.
   Le portail de survie reste sur le WiFi local (hors-ligne).</p>

<div class="card">
  <h2>🪪 Identité du nœud</h2>
  <dl class="kv">
    <dt>Nom du lieu</dt><dd><?= htmlspecialchars($identity['name'] ?? '—') ?></dd>
    <dt>Pays</dt><dd><?= htmlspecialchars($identity['country'] ?? '—') ?></dd>
    <dt>Version</dt><dd><?= htmlspecialchars($version) ?></dd>
    <dt>Adresse .onion</dt><dd><?= htmlspecialchars($onion ?? '—') ?></dd>
    <dt>Empreinte clé (SHA256)</dt><dd><?= htmlspecialchars($pubFingerprint ?? 'non signé') ?></dd>
    <dt>Horodatage (UTC)</dt><dd><?= htmlspecialchars($identity['generated_at']) ?></dd>
  </dl>
</div>

<div class="card">
  <h2>📡 Canaux du nœud</h2>
  <div class="chan"><b>WiFi</b><span>Page statique de survie — 10.0.0.1, hors-ligne, public.</span></div>
  <div class="chan"><b>LoRa</b><span>Messages d'urgence chiffrés (AES-256-GCM) — mesh 868 MHz.</span></div>
  <div class="chan"><b>Tor</b><span>Mises à jour de contenu + identification — ce service caché.</span></div>
</div>

<div class="card">
  <h2>📦 Manifeste de mise à jour (<?= count($manifest) ?> fichiers)</h2>
  <p class="sub" style="margin-bottom:.75rem">JSON : <code>?manifest=1</code> · Identité complète : <code>?format=json</code></p>
  <table>
    <thead><tr><th>Fichier</th><th>Octets</th><th>SHA256</th></tr></thead>
    <tbody>
    <?php foreach ($manifest as $name => $m): ?>
      <tr>
        <td><?= htmlspecialchars($name) ?></td>
        <td><?= number_format($m['bytes']) ?></td>
        <td class="h"><?= htmlspecialchars(substr($m['sha256'], 0, 24)) ?>…</td>
      </tr>
    <?php endforeach; ?>
    </tbody>
  </table>
</div>
</body>
</html>
