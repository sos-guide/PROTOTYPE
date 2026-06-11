<?php
/**
 * SOS-GUIDE — Bascule STARTER ↔ PRODUCTION (dev uniquement)
 * POST /dev-switch → change le mode et retourne JSON
 */

header('Content-Type: application/json');

if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
    http_response_code(405);
    echo json_encode(['error' => 'POST requis']);
    exit;
}

// Runtime dev dans /tmp (world-writable, pas de sudo requis)
$runtime = '/tmp/sos-guide';
if (!is_dir($runtime)) {
    mkdir($runtime, 0750, true);
}

$mf   = $runtime . '/dev-mode';
$cur  = (file_exists($mf) && trim((string) file_get_contents($mf)) === 'production')
        ? 'production' : 'starter';
$next = ($cur === 'production') ? 'starter' : 'production';

file_put_contents($mf, $next);

// Bascule vers STARTER : régénère le token CSRF + efface le marqueur d'install
if ($next === 'starter') {
    $tok = bin2hex(random_bytes(32));
    // Le token précédent est en 0400 : le supprimer avant réécriture
    @unlink($runtime . '/firstboot_token');
    file_put_contents($runtime . '/firstboot_token', $tok);
    @chmod($runtime . '/firstboot_token', 0400);
    @unlink('/var/lib/sos-guide/installed');
    @unlink('/tmp/sos-guide/installed');
}

echo json_encode(['mode' => $next, 'success' => true]);
