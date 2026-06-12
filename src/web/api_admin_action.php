<?php
/**
 * SOS-GUIDE — api_admin_action.php v2.5
 *
 * Actions d'administration sensibles déclenchées depuis /admin :
 *   - action=wifi         state=on|off   → allume/éteint l'AP WiFi (hostapd + dnsmasq)
 *   - action=set_admin_pass   password   → change le mot de passe du portail /admin
 *   - action=set_system_pass  password   → change le mot de passe du compte Linux du Pi
 *
 * Sécurité (identique à api_reload_network_proxy.php) :
 *   - source restreinte à la whitelist IP partagée (lib/whitelist.php)
 *   - token CSRF de session OBLIGATOIRE, à usage unique (rotation après validation)
 *   - mots de passe transmis aux scripts root via STDIN (jamais en argv)
 *   - chaque action est journalisée dans l'audit (sans le mot de passe)
 */

header('Content-Type: application/json; charset=utf-8');
session_start();

define('AUDIT_LOG', '/var/log/sos-guide-admin-audit.log');
require_once __DIR__ . '/lib/whitelist.php';

function out(array $payload, int $code = 200): void {
    http_response_code($code);
    echo json_encode($payload, JSON_UNESCAPED_UNICODE);
    exit;
}

function audit(array $entry): void {
    $entry = ['ts' => date('c')] + $entry;
    @file_put_contents(AUDIT_LOG,
        json_encode($entry, JSON_UNESCAPED_UNICODE) . "\n", FILE_APPEND | LOCK_EX);
}

// ── 1. IP source ──────────────────────────────────────────────────────────────
$remote = $_SERVER['REMOTE_ADDR'] ?? '';
if (!is_allowed_ip($remote)) {
    out(['success' => false, 'message' => 'Accès refusé'], 403);
}

// ── 2. Méthode ────────────────────────────────────────────────────────────────
if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
    out(['success' => false, 'message' => 'POST requis'], 405);
}

// ── 3. CSRF ───────────────────────────────────────────────────────────────────
if (
    empty($_POST['csrf_token']) ||
    empty($_SESSION['csrf_token']) ||
    !hash_equals((string) $_SESSION['csrf_token'], (string) $_POST['csrf_token'])
) {
    audit(['ip' => $remote, 'action' => 'admin_action', 'result' => 'CSRF_REJECT']);
    out(['success' => false, 'message' => 'Requête non autorisée (CSRF)'], 403);
}
// Rotation immédiate du token (usage unique)
$_SESSION['csrf_token'] = bin2hex(random_bytes(32));

// ── 4. Dispatch ───────────────────────────────────────────────────────────────
$action = $_POST['action'] ?? '';

switch ($action) {

    // ── WiFi ON / OFF ────────────────────────────────────────────────────────
    case 'wifi': {
        $state = ($_POST['state'] ?? '') === 'on' ? 'on' : 'off';
        $cmd   = $state === 'on' ? 'start' : 'stop';
        $log = []; $errors = [];

        foreach (['hostapd', 'dnsmasq'] as $svc) {
            exec('sudo /bin/systemctl ' . $cmd . ' ' . $svc . ' 2>&1', $o, $r);
            $r === 0 ? $log[] = "$svc $cmd" : $errors[] = "$svc: " . implode(' ', $o);
            $o = [];
        }

        $success = empty($errors);
        audit(['ip' => $remote, 'action' => 'wifi_' . $state,
               'success' => $success, 'log' => $log, 'errors' => $errors]);

        out([
            'success' => $success,
            'state'   => $state,
            'log'     => $log,
            'errors'  => $errors,
            'warning' => $state === 'off'
                ? "AP éteint : les clients WiFi sont déconnectés. Rallumage possible "
                  . "uniquement via Ethernet/Tor ou accès physique au Pi."
                : null,
        ], $success ? 200 : 207);
    }

    // ── Changement de mot de passe (admin portail ou compte système) ─────────
    case 'set_admin_pass':
    case 'set_system_pass': {
        $target   = $action === 'set_admin_pass' ? 'admin' : 'system';
        $password = (string) ($_POST['password'] ?? '');

        if (strlen($password) < 8 || strlen($password) > 128) {
            out(['success' => false,
                 'message' => 'Mot de passe invalide (8 à 128 caractères).'], 422);
        }

        // Mot de passe transmis sur STDIN — jamais en argument de commande.
        $descriptors = [
            0 => ['pipe', 'r'],   // stdin → le script lit le mot de passe ici
            1 => ['pipe', 'w'],
            2 => ['pipe', 'w'],
        ];
        $proc = proc_open(
            'sudo /usr/local/bin/sos-guide-set-credentials.sh ' . escapeshellarg($target),
            $descriptors, $pipes
        );

        if (!is_resource($proc)) {
            out(['success' => false, 'message' => 'Impossible de lancer la commande.'], 500);
        }

        fwrite($pipes[0], $password . "\n");
        fclose($pipes[0]);
        $stdout = stream_get_contents($pipes[1]); fclose($pipes[1]);
        $stderr = stream_get_contents($pipes[2]); fclose($pipes[2]);
        $exit   = proc_close($proc);

        $success = ($exit === 0);
        // L'audit ne contient JAMAIS le mot de passe.
        audit(['ip' => $remote, 'action' => 'set_pass_' . $target,
               'success' => $success, 'detail' => trim($success ? $stdout : $stderr)]);

        out([
            'success' => $success,
            'message' => $success
                ? trim($stdout)
                : ('Échec : ' . trim($stderr ?: 'erreur inconnue')),
        ], $success ? 200 : 207);
    }

    default:
        out(['success' => false, 'message' => 'Action inconnue.'], 400);
}
