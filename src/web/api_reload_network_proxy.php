<?php
/**
 * SOS-GUIDE — api_reload_network_proxy.php v2.4
 *
 * Proxy interne : appelé par admin.php via fetch('/api/reload-network-proxy')
 * Il relaie la requête vers /api/reload-network (restreint à 127.0.0.1 par nginx)
 *
 * CORRECTIONS v2.3 :
 *   ✅ Bypass CSRF via Referer supprimé
 *      (les headers Referer sont falsifiables par n'importe quel client du réseau local)
 *      Le token CSRF de session est maintenant OBLIGATOIRE sans exception
 *   ✅ admin.php envoie désormais le token CSRF dans le fetch() (voir admin.php)
 *   ✅ Appel curl interne vers 127.0.0.1 (contourne la restriction nginx)
 *   ✅ Journal d'audit structuré
 *
 * CORRECTION v2.4 :
 *   ✅ Whitelist IP ETH partagée avec update_config.php — les admins ETH
 *      pouvaient charger admin.php mais recevaient 403 sur les boutons reload (corrigé)
 */

header('Content-Type: application/json; charset=utf-8');
session_start();

define('AUDIT_LOG', '/var/log/sos-guide-admin-audit.log');
require_once __DIR__ . '/lib/whitelist.php';

// ── 1. Vérification IP source ─────────────────────────────────────────────────
$remote = $_SERVER['REMOTE_ADDR'] ?? '';

if (!is_allowed_ip($remote)) {
    http_response_code(403);
    echo json_encode(['success' => false, 'message' => 'Accès refusé']);
    exit;
}

// ── 2. Méthode HTTP ───────────────────────────────────────────────────────────
if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
    http_response_code(405);
    echo json_encode(['success' => false, 'message' => 'POST requis']);
    exit;
}

// ── 3. Vérification CSRF — token de session OBLIGATOIRE ──────────────────────
// FIX v2.3 : Le bypass via Referer est supprimé.
//
// Ancien code (VULNÉRABLE) :
//   if (token_invalide) {
//       $localReferer = str_starts_with($referer, 'http://10.0.0.1/');
//       if (!$localReferer) { return 403; }
//       // ← Si referer = 10.0.0.1, accès accordé SANS token
//       //   N'importe quel script sur le réseau local peut falsifier le Referer
//   }
//
// Nouveau code (CORRECT) :
//   Le token CSRF de session doit toujours être présent et valide.
//   admin.php envoie maintenant le token dans chaque fetch() (voir admin.php fix).

if (
    empty($_POST['csrf_token']) ||
    empty($_SESSION['csrf_token']) ||
    !hash_equals((string) $_SESSION['csrf_token'], (string) $_POST['csrf_token'])
) {
    // Audit de la tentative rejetée
    $entry = [
        'ts'     => date('c'),
        'ip'     => $remote,
        'action' => 'CSRF_REJECT',
        'detail' => empty($_SESSION['csrf_token']) ? 'session absente' : 'token invalide',
    ];
    @file_put_contents(AUDIT_LOG,
        json_encode($entry, JSON_UNESCAPED_UNICODE) . "\n", FILE_APPEND | LOCK_EX);

    http_response_code(403);
    echo json_encode(['success' => false, 'message' => 'Requête non autorisée (CSRF)']);
    exit;
}

// ── 4. Rotation du token CSRF après validation ────────────────────────────────
$_SESSION['csrf_token'] = bin2hex(random_bytes(32));

// ── 5. Paramètres ─────────────────────────────────────────────────────────────
$reloadWifi = (($_POST['reload_wifi'] ?? 'false') === 'true');

// ── 6. Appel interne curl vers /api/reload-network (127.0.0.1) ───────────────
// nginx restreint cet endpoint à 127.0.0.1 — ce proxy tourne côté serveur
$ch = curl_init('http://127.0.0.1/api/reload-network');
curl_setopt_array($ch, [
    CURLOPT_POST           => true,
    CURLOPT_POSTFIELDS     => http_build_query(['reload_wifi' => $reloadWifi ? 'true' : 'false']),
    CURLOPT_RETURNTRANSFER => true,
    CURLOPT_TIMEOUT        => 30,
    CURLOPT_CONNECTTIMEOUT => 5,
    CURLOPT_HTTPHEADER     => [
        'Content-Type: application/x-www-form-urlencoded',
    ],
]);

$response = curl_exec($ch);
$httpCode = curl_getinfo($ch, CURLINFO_HTTP_CODE);
$curlErr  = curl_error($ch);
curl_close($ch);

// ── 7. Fallback si curl non disponible : exécuter directement les reloads ─────
if ($response === false || $curlErr !== '') {
    $log    = [];
    $errors = [];

    exec('sudo /usr/local/bin/sos-guide-regen-hash.sh 2>&1', $o, $r);
    $r === 0 ? $log[] = 'Hash SHA256 régénéré' : $errors[] = 'Hash: ' . implode(' ', $o);

    exec('sudo /bin/systemctl reload nginx 2>&1', $o, $r);
    $r === 0 ? $log[] = 'nginx rechargé' : $errors[] = 'nginx: ' . implode(' ', $o);

    exec('sudo /bin/systemctl reload dnsmasq 2>&1', $o, $r);
    $r === 0 ? $log[] = 'dnsmasq rechargé' : $errors[] = 'dnsmasq: ' . implode(' ', $o);

    if ($reloadWifi) {
        exec('sudo /bin/systemctl restart hostapd 2>&1', $o, $r);
        $r === 0 ? $log[] = 'hostapd redémarré' : $errors[] = 'hostapd: ' . implode(' ', $o);
    }

    $success  = empty($errors);
    $response = json_encode([
        'success' => $success,
        'log'     => $log,
        'errors'  => $errors,
        'source'  => 'fallback',
    ]);
    $httpCode = $success ? 200 : 207;
}

// ── 8. Audit ──────────────────────────────────────────────────────────────────
$decoded = json_decode($response ?? '{}', true) ?? [];
$entry = [
    'ts'          => date('c'),
    'ip'          => $remote,
    'action'      => 'reload_network_proxy',
    'reload_wifi' => $reloadWifi,
    'http_code'   => $httpCode,
    'success'     => $decoded['success'] ?? false,
    'log'         => $decoded['log']    ?? [],
    'errors'      => $decoded['errors'] ?? [],
];
@file_put_contents(AUDIT_LOG,
    json_encode($entry, JSON_UNESCAPED_UNICODE) . "\n", FILE_APPEND | LOCK_EX);

http_response_code($httpCode ?: 200);
echo $response ?: json_encode(['success' => false, 'message' => 'Réponse vide']);
