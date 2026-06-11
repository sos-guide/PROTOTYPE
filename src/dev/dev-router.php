<?php
/**
 * SOS-GUIDE — Routeur de développement
 * Sert starter.html ou index.html selon le mode actif.
 * Injecte un token CSRF en live + une barre dev flottante.
 * ⚠  DEV UNIQUEMENT — ne pas déployer via install.sh en production.
 */

// Runtime dev dans /tmp (world-writable, pas de sudo requis)
define('RUNTIME_DIR', '/tmp/sos-guide');
define('MODE_FILE',   RUNTIME_DIR . '/dev-mode');
define('TOKEN_FILE',  RUNTIME_DIR . '/firstboot_token');
define('WEB_DIR',     __DIR__);

// Crée le répertoire runtime si absent (premier accès)
if (!is_dir(RUNTIME_DIR)) {
    mkdir(RUNTIME_DIR, 0750, true);
}

// ── Mode actif ────────────────────────────────────────────────────────────────
$mode = 'starter';
if (file_exists(MODE_FILE) && trim((string) file_get_contents(MODE_FILE)) === 'production') {
    $mode = 'production';
}

// ── Chargement de la page ────────────────────────────────────────────────────
if ($mode === 'production') {
    $file = WEB_DIR . '/index.html';
    if (!file_exists($file)) {
        http_response_code(503);
        die('<pre>index.html absent — lancez sync.sh</pre>');
    }
    $html = file_get_contents($file);
} else {
    $tpl = WEB_DIR . '/starter-template.html';
    if (!file_exists($tpl)) {
        http_response_code(503);
        die('<pre>starter-template.html absent — lancez sync.sh</pre>');
    }
    $html = file_get_contents($tpl);

    // Génère/relit le token CSRF one-shot
    if (!file_exists(TOKEN_FILE)) {
        $tok = bin2hex(random_bytes(32));
        file_put_contents(TOKEN_FILE, $tok);
        @chmod(TOKEN_FILE, 0400);
    }
    $tok = trim((string) file_get_contents(TOKEN_FILE));

    $html = str_replace('%%CSRF_TOKEN%%',   $tok,                     $html);
    $html = str_replace('%%WIFI_CHANNEL%%', '11',                     $html);
    $html = str_replace('%%STARTER_SSID%%', '⛑️ SOS-GUIDE – DEV PI', $html);
}

// ── Barre de développement (injectée dans le <head> + </body>) ───────────────
$mc     = ($mode === 'starter') ? '#58a6ff' : '#3fb950';
$ml     = strtoupper($mode);
$client = htmlspecialchars($_SERVER['REMOTE_ADDR'] ?? '?');

$style = '<style>'
    . '#sos-dev-bar{position:fixed;top:0;left:0;right:0;height:36px;'
    . 'background:#0d1117;color:#e6edf3;display:flex;align-items:center;'
    . 'gap:10px;padding:0 14px;z-index:2147483647;font:12px/1 monospace;'
    . 'border-bottom:2px solid #30363d;box-sizing:border-box}'
    . 'body{margin-top:36px!important}'
    . '</style>';

$bar = '<div id="sos-dev-bar">'
    . '<span style="color:#f85149;font-weight:bold">⚡ DEV PI</span>'
    . '<span style="background:#161b22;border:1px solid #30363d;padding:2px 9px;border-radius:3px">'
    .   'MODE&nbsp;:&nbsp;<b style="color:' . $mc . '">' . $ml . '</b>'
    . '</span>'
    . '<button onclick="fetch(\'/dev-switch\',{method:\'POST\'}).then(r=>r.json()).then(d=>{if(d.success)location.reload();else alert(\'Erreur bascule\');})" '
    .   'style="background:#21262d;color:#e6edf3;border:1px solid #30363d;'
    .   'padding:2px 10px;border-radius:3px;cursor:pointer">⇄ Basculer</button>'
    . '<button onclick="location.reload()" title="Recharger" '
    .   'style="background:#21262d;color:#7d8590;border:1px solid #30363d;'
    .   'padding:2px 7px;border-radius:3px;cursor:pointer">↻</button>'
    . '<span style="margin-left:auto;color:#7d8590">192.168.1.133 ← ' . $client . '</span>'
    . '</div>';

// Injection dans le HTML
$html = str_replace('</head>', $style . '</head>', $html);
$html = str_replace('</body>', $bar   . '</body>', $html);

header('Content-Type: text/html; charset=UTF-8');
header('Cache-Control: no-store, no-cache');
echo $html;
