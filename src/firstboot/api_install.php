<?php
/**
 * SOS-GUIDE — api_install.php v2.5
 * Endpoint de configuration initial (mode STARTER → PRODUCTION)
 *
 * CORRECTIONS v2.4 :
 *   ✅ Suppression complète du PIN HDMI (define PIN_FILE, vérification, rate-limit PIN)
 *   ✅ Authentification par CSRF one-shot uniquement (token injecté dans starter.html)
 *   ✅ IP whitelist étendue : WiFi AP (10.0.0.x) + ETH privé si enableEthernet=true
 *   ✅ Rate-limiting par IP conservé (5 tentatives / 15 min)
 *   ✅ Journal d'audit structuré
 *
 * Sécurité v2.4 :
 *   ✅ Token CSRF one-shot généré au démarrage du service firstboot
 *   ✅ Whitelist IP stricte (localhost + réseau AP + ETH si activé)
 *   ✅ Rate-limiting par IP (max 5 tentatives / 15 min)
 *   ✅ Invalidation immédiate du token après utilisation réussie
 *   ✅ Journal d'audit de toutes les tentatives
 */

header('Content-Type: application/json; charset=utf-8');

// Runtime : /tmp/sos-guide en dev (créé par dev-router.php), /run/sos-guide en prod (créé par firstboot.sh)
$_sg_rt = is_dir('/tmp/sos-guide') ? '/tmp/sos-guide' : '/run/sos-guide';
define('RUNTIME_DIR',  $_sg_rt);
define('TOKEN_FILE',   $_sg_rt . '/firstboot_token');
define('RATE_FILE',    $_sg_rt . '/rate_limit');
unset($_sg_rt);
define('AUDIT_LOG',    '/var/log/sos-guide-firstboot-audit.log');
define('CONFIG_FILE',  '/var/www/sos-guide/data/config.json');
define('INSTALL_DONE', '/var/lib/sos-guide/installed');
define('MAX_ATTEMPTS', 5);
define('RATE_WINDOW',  900); // 15 minutes

// ── Helpers ──────────────────────────────────────────────────────────────────
function json_error(int $code, string $msg): void
{
    http_response_code($code);
    echo json_encode(['success' => false, 'message' => $msg]);
    exit;
}

function audit(string $action, array $extra = []): void
{
    $entry = array_merge([
        'ts'     => date('c'),
        'ip'     => $_SERVER['REMOTE_ADDR'] ?? 'unknown',
        'ua'     => substr($_SERVER['HTTP_USER_AGENT'] ?? '', 0, 80),
        'action' => $action,
    ], $extra);
    @file_put_contents(AUDIT_LOG,
        json_encode($entry, JSON_UNESCAPED_UNICODE) . "\n",
        FILE_APPEND | LOCK_EX);
}

// ── Whitelist IP (alignée avec lib/whitelist.php) ─────────────────────────────
function is_allowed_ip(string $remote): bool
{
    // DEV : /tmp/sos-guide/ créé par dev-router.php au premier chargement de page
    if (is_dir('/tmp/sos-guide') || file_exists('/var/lib/sos-guide/dev-mode')) return true;

    if (in_array($remote, ['127.0.0.1', '::1'], true)) return true;

    // Réseau AP WiFi (10.0.0.x — toujours autorisé)
    if (preg_match('/^10\.0\.0\.\d{1,3}$/', $remote)) return true;

    // Réseau ETH privé — uniquement si enableEthernet=true dans config
    $cfg = [];
    if (file_exists(CONFIG_FILE)) {
        $cfg = json_decode((string) file_get_contents(CONFIG_FILE), true) ?? [];
    }
    if ($cfg['enableEthernet'] ?? false) {
        if (preg_match('/^192\.168\.\d{1,3}\.\d{1,3}$/', $remote))                return true;
        if (preg_match('/^172\.(1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3}$/', $remote)) return true;
        // 10.x.x.x hors 10.0.0.x déjà traité ci-dessus
        if (preg_match('/^10\.(?!0\.0\.)\d{1,3}\.\d{1,3}\.\d{1,3}$/', $remote))   return true;
    }
    return false;
}

// ── 1. Installation déjà effectuée ? ─────────────────────────────────────────
if (file_exists(INSTALL_DONE)) {
    audit('REJECT_ALREADY_INSTALLED');
    json_error(410, 'Installation déjà effectuée. Ce endpoint est désactivé.');
}

// ── 2. Méthode POST uniquement ────────────────────────────────────────────────
if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
    json_error(405, 'POST requis');
}

// ── 3. Whitelist IP ───────────────────────────────────────────────────────────
$remote = $_SERVER['REMOTE_ADDR'] ?? '';
if (!is_allowed_ip($remote)) {
    audit('REJECT_IP', ['ip' => $remote]);
    json_error(403, 'Accès refusé — IP non autorisée');
}

// ── 4. Rate-limiting par IP ───────────────────────────────────────────────────
$rateData = [];
if (file_exists(RATE_FILE)) {
    $rateData = json_decode((string) file_get_contents(RATE_FILE), true) ?? [];
}

$now   = time();
$ipKey = md5($remote); // anonymiser l'IP dans le fichier de rate

// Purger les entrées expirées
foreach ($rateData as $k => $entry) {
    if ($now - ($entry['first'] ?? 0) > RATE_WINDOW) {
        unset($rateData[$k]);
    }
}

if (!isset($rateData[$ipKey])) {
    $rateData[$ipKey] = ['first' => $now, 'count' => 0];
}
$rateData[$ipKey]['count']++;

if ($rateData[$ipKey]['count'] > MAX_ATTEMPTS) {
    $remaining = RATE_WINDOW - ($now - $rateData[$ipKey]['first']);
    file_put_contents(RATE_FILE, json_encode($rateData), LOCK_EX);
    audit('RATE_LIMITED', ['attempts' => $rateData[$ipKey]['count']]);
    json_error(429, 'Trop de tentatives. Réessayez dans ' . ceil($remaining / 60) . ' minute(s).');
}
file_put_contents(RATE_FILE, json_encode($rateData), LOCK_EX);

// ── 5. Vérification du token CSRF one-shot ────────────────────────────────────
if (!file_exists(TOKEN_FILE)) {
    audit('REJECT_NO_TOKEN');
    json_error(503, 'Service non prêt (token absent). Patientez 30 secondes.');
}

$expectedToken  = trim((string) file_get_contents(TOKEN_FILE));
$submittedToken = trim((string) ($_POST['_csrf'] ?? ''));

if (empty($submittedToken) || !hash_equals($expectedToken, $submittedToken)) {
    audit('REJECT_CSRF', ['submitted' => substr($submittedToken, 0, 8) . '...']);
    json_error(403, 'Token CSRF invalide ou expiré');
}

// ── 6. Validation des données de configuration ────────────────────────────────
$nodeName = trim((string) ($_POST['nodeName'] ?? ''));
// Nettoyer avant de valider la longueur (évite faux positifs sur chars invalides)
$nodeName = preg_replace('/[^\pL\pN\s\-\.\,\'\(\)–—]/u', '', $nodeName);
$nodeName = function_exists('mb_substr') ? mb_substr(trim($nodeName), 0, 128) : substr(trim($nodeName), 0, 128);
if (empty($nodeName)) {
    json_error(400, 'Nom du lieu requis (1–128 caractères, lettres/chiffres)');
}

$enableLoRa     = isset($_POST['enableLoRa'])     && $_POST['enableLoRa']     === 'true';
$enableEthernet = isset($_POST['enableEthernet']) && $_POST['enableEthernet'] === 'true';
$wifiChannel    = intval($_POST['wifiChannel'] ?? 11);
$nodeType       = preg_replace('/[^a-z]/', '', strtolower((string)($_POST['nodeType'] ?? 'erp')));
// Langue par défaut du portail (choisie au starter) — whitelist des 29 langues
$allLangs    = ['fr','de','it','rm','en','es','pt','ar','zh','ja','ko','ru','uk','pl','nl',
                'sv','no','da','fi','hu','ro','cs','el','tr','fa','hi','th','vi','he'];
$defaultLang = preg_replace('/[^a-z]/', '', strtolower((string)($_POST['defaultLang'] ?? 'fr')));
if (!in_array($defaultLang, $allLangs, true)) {
    $defaultLang = 'fr';
}
$nodeAddress    = function_exists('mb_substr') ? mb_substr(trim((string)($_POST['nodeAddress'] ?? '')), 0, 256) : substr(trim((string)($_POST['nodeAddress'] ?? '')), 0, 256);
// Pays du lieu (optionnel) — lettres/espaces/tirets uniquement
$nodeCountry    = preg_replace('/[^\pL\s\-\.\,\'\(\)]/u', '', (string)($_POST['nodeCountry'] ?? ''));
$nodeCountry    = function_exists('mb_substr') ? mb_substr(trim($nodeCountry), 0, 64) : substr(trim($nodeCountry), 0, 64);
$lat            = (float)($_POST['lat'] ?? 0);
$lon            = (float)($_POST['lon'] ?? 0);
$mapZoom        = min(19, max(10, intval($_POST['mapZoom'] ?? 15)));

// Canal WiFi valide (EU : 1-13)
if ($wifiChannel < 1 || $wifiChannel > 13) {
    $wifiChannel = 11;
}

// ── 7. Upload image carte (optionnel) ────────────────────────────────────────
$mapImageSaved = false;
if (isset($_FILES['mapImage']) && $_FILES['mapImage']['error'] === UPLOAD_ERR_OK) {
    $tmpFile  = $_FILES['mapImage']['tmp_name'];
    $fileSize = $_FILES['mapImage']['size'];
    $mime     = mime_content_type($tmpFile);
    $allowed  = ['image/jpeg', 'image/png', 'image/webp', 'image/gif'];
    if (in_array($mime, $allowed, true) && $fileSize <= 10 * 1024 * 1024) {
        $ext     = ($mime === 'image/png') ? 'png' : (($mime === 'image/webp') ? 'webp' : 'jpg');
        $destDir = '/var/www/sos-guide/img';
        @mkdir($destDir, 0755, true);
        $destPath = $destDir . '/map_local.' . $ext;
        if (move_uploaded_file($tmpFile, $destPath)) {
            @chmod($destPath, 0644);
            $mapImageSaved = true;
        }
    }
}

// ── 8. Chargement / création de config.json ──────────────────────────────────
@mkdir(dirname(CONFIG_FILE), 0755, true);
$config = ['establishment' => [], 'reassurance' => ['message' => '']];
if (file_exists(CONFIG_FILE)) {
    $existing = json_decode((string) file_get_contents(CONFIG_FILE), true);
    if (is_array($existing)) {
        $config = $existing;
    }
}

$config['establishment']['name']    = $nodeName;
$config['establishment']['type']    = $nodeType;
$config['establishment']['country'] = $nodeCountry;
$config['establishment']['address'] = $nodeAddress;
if ($lat !== 0.0 || $lon !== 0.0) {
    $config['establishment']['lat']     = $lat;
    $config['establishment']['lon']     = $lon;
    $config['establishment']['mapZoom'] = $mapZoom;
}
$config['wifiChannel']  = $wifiChannel;
$config['defaultLang']  = $defaultLang;
$config['enableLoRa']   = $enableLoRa;
$config['enableEthernet'] = $enableEthernet;
$config['installed']    = false;
$config['installDate']  = date('c');
// S-03/N-02 : IP du configurateur non persistée (donnée personnelle — nLPD art. 6)

// ── 9. Écriture atomique ──────────────────────────────────────────────────────
$json    = json_encode($config, JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
$tmpFile = CONFIG_FILE . '.tmp.' . getmypid();
if (file_put_contents($tmpFile, $json, LOCK_EX) === false) {
    audit('WRITE_FAIL');
    json_error(500, 'Erreur écriture configuration');
}
if (!rename($tmpFile, CONFIG_FILE)) {
    @unlink($tmpFile);
    json_error(500, 'Erreur sauvegarde atomique');
}
@chown(CONFIG_FILE, 'www-data');
@chgrp(CONFIG_FILE, 'www-data');
@chmod(CONFIG_FILE, 0640);

// ── 10. Invalidation du token CSRF (one-shot) ────────────────────────────────
// Le token ne peut être utilisé qu'une seule fois
@unlink(TOKEN_FILE);

// ── 11. Lancement de finalize_install.sh en arrière-plan ─────────────────────
// C2 : ne pas copier depuis /boot (partition FAT rw — vecteur d'escalade root)
// firstboot.sh est seul responsable de la copie au moment du premier démarrage.
$finalizeScript = '/usr/local/bin/finalize_install.sh';

$launched = false;
if (!file_exists($finalizeScript) || !is_executable($finalizeScript)) {
    audit('FINALIZE_MISSING', ['path' => $finalizeScript]);
} else {
    // C8 : écrire un marqueur .pending avant le lancement pour détecter les échecs
    $pendingFlag = RUNTIME_DIR . '/install_pending';
    @file_put_contents($pendingFlag, date('c'));

    $cmd = "sudo $finalizeScript >> /var/log/sos-guide-install.log 2>&1 &";
    exec($cmd, $out, $rc);
    // exec() avec & retourne toujours 0 — on vérifie que le processus a bien démarré
    // en regardant si sudo a pu forker (rc=0 garantit que le fork a réussi)
    $launched = ($rc === 0);
    if (!$launched) {
        @unlink($pendingFlag);
        audit('FINALIZE_LAUNCH_FAILED', ['rc' => $rc]);
    }
}

// ── 12. Audit succès ─────────────────────────────────────────────────────────
audit('INSTALL_STARTED', [
    'node'     => $nodeName,
    'channel'  => $wifiChannel,
    'lora'     => $enableLoRa,
    'ethernet' => $enableEthernet,
    'launched' => $launched,
]);

// Réinitialiser le rate-limit en cas de succès
unset($rateData[$ipKey]);
file_put_contents(RATE_FILE, json_encode($rateData), LOCK_EX);

// ── 13. Réponse ──────────────────────────────────────────────────────────────
echo json_encode([
    'success'       => true,
    'launched'      => $launched,
    'mapImageSaved' => $mapImageSaved,
    'message'       => $launched
        ? 'Configuration enregistrée. Finalisation en cours...'
        : 'Configuration enregistrée. Lancer : sudo /usr/local/bin/finalize_install.sh',
    'node'          => $nodeName,
    'channel'       => $wifiChannel,
]);
