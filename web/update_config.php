<?php
/**
 * SOS-GUIDE — update_config.php v2.3
 *
 * CORRECTIONS v2.3 :
 *   ✅ wifiChannel désormais lu et sauvegardé (était ignoré dans la v2.2)
 *   ✅ Reload à chaud sans reboot (nginx, dnsmasq, hostapd si SSID/canal changé)
 *   ✅ Validation complète de tous les champs
 *   ✅ Journal d'audit structuré JSON (PCi-CH)
 *   ✅ Écriture atomique config.json
 *   ✅ Régénération SHA256 obligatoire après chaque save
 */

ini_set('display_errors', 0);
error_reporting(0);
session_start();

define('CONFIG_FILE',  '/var/www/sos-guide/data/config.json');
define('AUDIT_LOG',    '/var/log/sos-guide-admin-audit.log');
define('REGEN_SCRIPT', '/usr/local/bin/sos-guide-regen-hash.sh');

// ── Helpers ───────────────────────────────────────────────────────────────────
function redirect(bool $ok, string $warn = ''): void
{
    $q = $ok
        ? 'updated=1' . ($warn ? '&warn=' . urlencode($warn) : '')
        : 'error=1';
    header('Location: admin.php?' . $q);
    exit;
}

function s_text(string $v, int $max = 256): string
{
    return mb_substr(trim(strip_tags($v)), 0, $max);
}

function s_phone(string $v): string
{
    return mb_substr(preg_replace('/[^\d\+\s\-\(\)\/]/', '', $v), 0, 32);
}

function s_gps(string $v): string
{
    $v = trim($v);
    return preg_match('/^-?\d{1,3}(\.\d{1,8})?$/', $v) ? $v : '';
}

function s_channel(mixed $v): int
{
    $c = intval($v);
    return ($c >= 1 && $c <= 13) ? $c : 11;
}

function audit(array $entry): void
{
    @file_put_contents(
        AUDIT_LOG,
        json_encode($entry, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES) . "\n",
        FILE_APPEND | LOCK_EX
    );
}

// ── Vérifications préliminaires ───────────────────────────────────────────────
if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
    header('Location: admin.php');
    exit;
}

// CSRF
if (
    empty($_POST['csrf_token']) ||
    empty($_SESSION['csrf_token']) ||
    !hash_equals($_SESSION['csrf_token'], $_POST['csrf_token'])
) {
    audit(['ts' => date('c'), 'ip' => $_SERVER['REMOTE_ADDR'] ?? '', 'action' => 'CSRF_FAIL']);
    redirect(false);
}
$_SESSION['csrf_token'] = bin2hex(random_bytes(32));

// ── Chargement config existante ───────────────────────────────────────────────
$config = ['establishment' => [], 'reassurance' => ['message' => '']];
if (file_exists(CONFIG_FILE)) {
    $existing = json_decode(file_get_contents(CONFIG_FILE), true);
    if (is_array($existing)) $config = $existing;
}

$before   = $config;
$changed  = [];

// ── Champs establishment ──────────────────────────────────────────────────────
$estFields = [
    'name'                => ['s_text',  128],
    'address'             => ['s_text',  256],
    'lat'                 => ['s_gps',   0  ],
    'lon'                 => ['s_gps',   0  ],
    'type'                => ['s_text',  32 ],
    'localRisk'           => ['s_text',  256],
    'localCrisisNumber'   => ['s_phone', 0  ],
    'localSamuNumber'     => ['s_phone', 0  ],
    'localPompiersNumber' => ['s_phone', 0  ],
    'localMairieNumber'   => ['s_phone', 0  ],
    'localPrefecture'     => ['s_text',  128],
    'localDsden'          => ['s_text',  128],
    'localRadioFreq'      => ['s_text',  16 ],
    'localCroixRouge'     => ['s_text',  128],
    'localPccAddress'     => ['s_text',  256],
    'localMeetingPoint'   => ['s_text',  256],
    'localEvacuationPlan' => ['s_text',  512],
];

$allowedTypes = ['erp','ecole','mairie','ehpad','entreprise','bar','boitedenuit','hopital','gymnase'];

if (empty($config['establishment'])) $config['establishment'] = [];

foreach ($estFields as $key => [$fn, $max]) {
    if (!array_key_exists($key, $_POST)) continue;
    $raw   = (string) $_POST[$key];
    $clean = $max > 0 ? $fn($raw, $max) : $fn($raw);
    if ($key === 'type' && !in_array($clean, $allowedTypes, true)) $clean = 'erp';
    $old   = $config['establishment'][$key] ?? '';
    if ($old !== $clean) $changed[$key] = ['from' => $old, 'to' => $clean];
    $config['establishment'][$key] = $clean;
}

// ── Réassurance ───────────────────────────────────────────────────────────────
if (isset($_POST['reassuranceMessage'])) {
    $new = s_text((string) $_POST['reassuranceMessage'], 512);
    $old = $config['reassurance']['message'] ?? '';
    if ($old !== $new) $changed['reassuranceMessage'] = ['from' => $old, 'to' => $new];
    $config['reassurance']['message'] = $new;
}

// ── Canal WiFi — FIX v2.3 : désormais sauvegardé ─────────────────────────────
$oldChannel     = intval($config['wifiChannel'] ?? 11);
$newChannel     = s_channel($_POST['wifiChannel'] ?? $oldChannel);
$channelChanged = ($oldChannel !== $newChannel);
if ($channelChanged) {
    $changed['wifiChannel'] = ['from' => $oldChannel, 'to' => $newChannel];
}
$config['wifiChannel'] = $newChannel;

// ── Mot de passe WiFi ─────────────────────────────────────────────────────────
$pwdChanged = false;
if (!empty($_POST['wifiPassword'])) {
    $newPwd = (string) $_POST['wifiPassword'];
    if (mb_strlen($newPwd) >= 8 || $newPwd === '') {
        $old = $config['wifiPassword'] ?? '';
        if ($old !== $newPwd) { $pwdChanged = true; $changed['wifiPassword'] = '[redacted]'; }
        $config['wifiPassword'] = $newPwd;
    }
}

// ── LoRa / Ethernet ───────────────────────────────────────────────────────────
$loraChanged = false;
$newLora = isset($_POST['enableLoRa']) && $_POST['enableLoRa'] === 'true';
if (($config['enableLoRa'] ?? false) !== $newLora) {
    $changed['enableLoRa'] = ['from' => $config['enableLoRa'] ?? false, 'to' => $newLora];
    $loraChanged = true;
}
$config['enableLoRa'] = $newLora;

$newEth = isset($_POST['enableEthernet']) && $_POST['enableEthernet'] === 'true';
if (($config['enableEthernet'] ?? false) !== $newEth) {
    $changed['enableEthernet'] = ['from' => $config['enableEthernet'] ?? false, 'to' => $newEth];
}
$config['enableEthernet'] = $newEth;

// ── Déterminer si un restart hostapd est nécessaire ──────────────────────────
$oldName     = $before['establishment']['name'] ?? '';
$newName     = $config['establishment']['name']  ?? '';
$ssidChanged = ($oldName !== $newName) || $pwdChanged || $channelChanged;

// ── Écriture atomique ─────────────────────────────────────────────────────────
$json = json_encode($config, JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
if ($json === false) redirect(false);

$tmp = CONFIG_FILE . '.tmp.' . getmypid();
if (file_put_contents($tmp, $json, LOCK_EX) === false) redirect(false);
if (!rename($tmp, CONFIG_FILE)) { @unlink($tmp); redirect(false); }

@chown(CONFIG_FILE, 'www-data');
@chmod(CONFIG_FILE, 0640);

// ── Régénération SHA256 (obligatoire après chaque save) ───────────────────────
$hashOk = false;
if (is_executable(REGEN_SCRIPT)) {
    exec('sudo ' . REGEN_SCRIPT . ' 2>&1', $hashOut, $hashRet);
    $hashOk = ($hashRet === 0);
} else {
    // Fallback inline
    $cmd = 'find /var/www/sos-guide -type f -exec sha256sum {} \; '
         . '> /root/integrity.hash.tmp && mv /root/integrity.hash.tmp /root/integrity.hash';
    exec('sudo bash -c ' . escapeshellarg($cmd), $hashOut, $hashRet);
    $hashOk = ($hashRet === 0);
}

// ── Reload à chaud des services ───────────────────────────────────────────────
$reloadLog    = [];
$reloadErrors = [];

// nginx — zero-downtime
exec('sudo /bin/systemctl reload nginx 2>&1', $o, $r);
$r === 0 ? ($reloadLog[] = 'nginx rechargé') : ($reloadErrors[] = 'nginx: ' . implode('', $o));

// dnsmasq — SIGHUP conserve les baux DHCP
exec('sudo /bin/systemctl reload dnsmasq 2>&1', $o, $r);
$r === 0 ? ($reloadLog[] = 'dnsmasq rechargé') : ($reloadErrors[] = 'dnsmasq: ' . implode('', $o));

// hostapd — uniquement si SSID, canal ou WPA changé (~3s d'interruption WiFi)
if ($ssidChanged) {
    exec('sudo /bin/systemctl restart hostapd 2>&1', $o, $r);
    $r === 0
        ? ($reloadLog[] = 'hostapd redémarré (SSID/canal/WPA changé)')
        : ($reloadErrors[] = 'hostapd: ' . implode('', $o));
} else {
    $reloadLog[] = 'hostapd inchangé (pas de restart)';
}

// lora-service — si état a changé
if ($loraChanged) {
    if ($newLora) {
        exec('sudo /bin/systemctl enable --now lora-service 2>&1', $o, $r);
        $r === 0 ? ($reloadLog[] = 'lora-service activé') : ($reloadErrors[] = 'lora: ' . implode('', $o));
    } else {
        exec('sudo /bin/systemctl disable --now lora-service 2>&1', $o, $r);
        $r === 0 ? ($reloadLog[] = 'lora-service désactivé') : ($reloadErrors[] = 'lora: ' . implode('', $o));
    }
}

// ── Audit ─────────────────────────────────────────────────────────────────────
audit([
    'ts'             => date('c'),
    'ip'             => $_SERVER['REMOTE_ADDR'] ?? 'unknown',
    'action'         => 'config_update',
    'fields_changed' => array_keys($changed),
    'ssid_changed'   => $ssidChanged,
    'channel_changed'=> $channelChanged,
    'lora_changed'   => $loraChanged,
    'hash_ok'        => $hashOk,
    'reload_log'     => $reloadLog,
    'reload_errors'  => $reloadErrors,
]);

// ── Réponse ───────────────────────────────────────────────────────────────────
$warns = array_filter([
    !$hashOk           ? 'hash_fail'      : '',
    !empty($reloadErrors) ? 'reload_partial' : '',
]);

redirect(true, implode(',', $warns));
