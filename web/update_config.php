<?php
/**
 * SOS-GUIDE — update_config.php v2.4
 *
 * CORRECTIONS v2.4 :
 *   ✅ IP whitelist étendue : ETH privé (192.168.x.x / 172.16-31.x.x / 10.x.x.x)
 *      si enableEthernet=true dans config — accès admin sans WiFi AP possible
 *   ✅ localPoliceNumber ajouté dans $estFields (override numéro police sur portail)
 *   ✅ Backup automatique config.json avant toute écriture (.bak)
 *   ✅ Reload à chaud sans reboot (nginx, dnsmasq, hostapd si SSID/canal changé)
 *   ✅ Validation complète de tous les champs
 *   ✅ Journal d'audit structuré JSON (PCi-CH)
 *   ✅ Écriture atomique config.json (.tmp + rename)
 *   ✅ Régénération SHA256 obligatoire après chaque save
 *   ✅ wifiChannel lu et sauvegardé (était ignoré en v2.2)
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

// ── v2.4 : Whitelist IP étendue ───────────────────────────────────────────────
// WiFi AP (10.0.0.x) toujours autorisé.
// ETH privé autorisé si enableEthernet=true dans config.
function is_allowed_ip(string $remote): bool
{
    if (in_array($remote, ['127.0.0.1', '::1'], true)) return true;

    // Réseau AP WiFi — toujours autorisé
    if (preg_match('/^10\.0\.0\.\d{1,3}$/', $remote)) return true;

    // Réseau ETH privé — uniquement si enableEthernet=true
    $config = [];
    if (file_exists(CONFIG_FILE)) {
        $config = json_decode((string) file_get_contents(CONFIG_FILE), true) ?? [];
    }
    if ($config['enableEthernet'] ?? false) {
        if (preg_match('/^192\.168\.\d{1,3}\.\d{1,3}$/', $remote))            return true;
        if (preg_match('/^172\.(1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3}$/', $remote)) return true;
        // 10.x.x.x hors 10.0.0.x déjà traité
        if (preg_match('/^10\.(?!0\.0\.)\d{1,3}\.\d{1,3}\.\d{1,3}$/', $remote)) return true;
    }
    return false;
}

// ── Vérifications préliminaires ───────────────────────────────────────────────
if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
    header('Location: admin.php');
    exit;
}

// Vérification IP
$remote = $_SERVER['REMOTE_ADDR'] ?? '';
if (!is_allowed_ip($remote)) {
    audit(['ts' => date('c'), 'ip' => $remote, 'action' => 'REJECT_IP']);
    http_response_code(403);
    echo '403 Accès refusé';
    exit;
}

// CSRF
if (
    empty($_POST['csrf_token']) ||
    empty($_SESSION['csrf_token']) ||
    !hash_equals($_SESSION['csrf_token'], $_POST['csrf_token'])
) {
    audit(['ts' => date('c'), 'ip' => $remote, 'action' => 'CSRF_FAIL']);
    redirect(false);
}
$_SESSION['csrf_token'] = bin2hex(random_bytes(32));

// ── Chargement config existante ───────────────────────────────────────────────
$config = ['establishment' => [], 'reassurance' => ['message' => '']];
if (file_exists(CONFIG_FILE)) {
    $existing = json_decode((string) file_get_contents(CONFIG_FILE), true);
    if (is_array($existing)) $config = $existing;
}

$before  = $config;
$changed = [];

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
    // v2.4 : localPoliceNumber ajouté
    'localPoliceNumber'   => ['s_phone', 0  ],
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

$allowedTypes = [
    'erp','ecole','mairie','ehpad','entreprise',
    'bar','boitedenuit','hopital','gymnase'
];

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

// ── Canal WiFi ────────────────────────────────────────────────────────────────
$oldChannel     = intval($config['wifiChannel'] ?? 11);
$newChannel     = s_channel($_POST['wifiChannel'] ?? $oldChannel);
$channelChanged = ($oldChannel !== $newChannel);
if ($channelChanged) {
    $changed['wifiChannel'] = ['from' => $oldChannel, 'to' => $newChannel];
}
$config['wifiChannel'] = $newChannel;

// ── Mot de passe WiFi ─────────────────────────────────────────────────────────
$pwdChanged = false;
if (isset($_POST['wifiPassword']) && $_POST['wifiPassword'] !== '') {
    $newPwd = (string) $_POST['wifiPassword'];
    if (mb_strlen($newPwd) >= 8) {
        $old = $config['wifiPassword'] ?? '';
        if ($old !== $newPwd) {
            $pwdChanged = true;
            $changed['wifiPassword'] = '[redacted]';
        }
        $config['wifiPassword'] = $newPwd;
    } elseif ($newPwd === '') {
        // Réseau ouvert
        $config['wifiPassword'] = '';
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

$ethChanged = false;
$newEth = isset($_POST['enableEthernet']) && $_POST['enableEthernet'] === 'true';
if (($config['enableEthernet'] ?? false) !== $newEth) {
    $changed['enableEthernet'] = ['from' => $config['enableEthernet'] ?? false, 'to' => $newEth];
    $ethChanged = true;
}
$config['enableEthernet'] = $newEth;

// ── Détecter si hostapd doit être redémarré ───────────────────────────────────
$oldName     = $before['establishment']['name'] ?? '';
$newName     = $config['establishment']['name']  ?? '';
$ssidChanged = ($oldName !== $newName) || $pwdChanged || $channelChanged;

// ── v2.4 : Backup atomique avant écriture ─────────────────────────────────────
if (file_exists(CONFIG_FILE)) {
    @copy(CONFIG_FILE, CONFIG_FILE . '.bak');
}

// ── Écriture atomique ─────────────────────────────────────────────────────────
$json = json_encode(
    $config,
    JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES
);
if ($json === false) redirect(false);

$tmp = CONFIG_FILE . '.tmp.' . getmypid();
if (file_put_contents($tmp, $json, LOCK_EX) === false) redirect(false);
if (!rename($tmp, CONFIG_FILE)) {
    @unlink($tmp);
    redirect(false);
}
@chown(CONFIG_FILE, 'www-data');
@chmod(CONFIG_FILE, 0640);

// ── Régénération SHA256 (obligatoire après chaque save) ───────────────────────
$hashOk = false;
if (is_executable(REGEN_SCRIPT)) {
    exec('sudo ' . REGEN_SCRIPT . ' 2>&1', $hashOut, $hashRet);
    $hashOk = ($hashRet === 0);
} else {
    // Fallback inline si le script n'est pas disponible
    $cmd = 'find /var/www/sos-guide -type f ! -path "*/data/config.json" -exec sha256sum {} \; '
         . '> /root/integrity.hash.tmp && mv /root/integrity.hash.tmp /root/integrity.hash';
    exec('sudo bash -c ' . escapeshellarg($cmd), $hashOut, $hashRet);
    $hashOk = ($hashRet === 0);
}

// ── Détection dynamique interface WiFi pour reload ────────────────────────────
$wifiIface = trim((string)(shell_exec(
    "for i in /sys/class/net/*; do"
    . " i=\$(basename \$i);"
    . " [ -d \"/sys/class/net/\$i/wireless\" ] && { echo \$i; break; };"
    . " done 2>/dev/null"
) ?? ''));
if (empty($wifiIface)) {
    $wifiIface = trim((string)(shell_exec(
        "ip link show 2>/dev/null | awk -F': ' '/wl/{print \$2}' | head -1"
    ) ?? ''));
}

// ── Reload à chaud des services ───────────────────────────────────────────────
$reloadLog    = [];
$reloadErrors = [];

// nginx — zero-downtime
exec('sudo /bin/systemctl reload nginx 2>&1', $o, $r);
$r === 0
    ? ($reloadLog[] = 'nginx rechargé (zero-downtime)')
    : ($reloadErrors[] = 'nginx: ' . implode('', $o));

// dnsmasq — SIGHUP conserve les baux DHCP
exec('sudo /bin/systemctl reload dnsmasq 2>&1', $o, $r);
$r === 0
    ? ($reloadLog[] = 'dnsmasq rechargé (baux conservés)')
    : ($reloadErrors[] = 'dnsmasq: ' . implode('', $o));

// hostapd — uniquement si SSID, canal ou WPA changé (~3s d'interruption WiFi)
if ($ssidChanged) {
    // Remonter l'interface WiFi proprement avant restart
    if (!empty($wifiIface)) {
        exec('sudo /sbin/ip link set ' . escapeshellarg($wifiIface) . ' down 2>&1');
        sleep(1);
        exec('sudo /sbin/ip link set ' . escapeshellarg($wifiIface) . ' up 2>&1');
        sleep(1);
    }
    exec('sudo /bin/systemctl restart hostapd 2>&1', $o, $r);
    if ($r === 0) {
        $reloadLog[] = 'hostapd redémarré (SSID/canal/WPA changé)';
        // Réattribuer l'IP AP après restart
        if (!empty($wifiIface)) {
            exec('sudo /sbin/ip addr add 10.0.0.1/24 dev ' . escapeshellarg($wifiIface) . ' 2>/dev/null');
        }
    } else {
        $reloadErrors[] = 'hostapd: ' . implode('', $o);
    }
} else {
    $reloadLog[] = 'hostapd inchangé (pas de restart nécessaire)';
}

// lora-service — si état a changé
if ($loraChanged) {
    if ($newLora) {
        exec('sudo /bin/systemctl enable --now lora-service 2>&1', $o, $r);
        $r === 0
            ? ($reloadLog[] = 'lora-service activé')
            : ($reloadErrors[] = 'lora-service: ' . implode('', $o));
    } else {
        exec('sudo /bin/systemctl disable --now lora-service 2>&1', $o, $r);
        $r === 0
            ? ($reloadLog[] = 'lora-service désactivé')
            : ($reloadErrors[] = 'lora-service: ' . implode('', $o));
    }
}

// ── Audit structuré ───────────────────────────────────────────────────────────
audit([
    'ts'              => date('c'),
    'ip'              => $remote,
    'action'          => 'config_update',
    'fields_changed'  => array_keys($changed),
    'ssid_changed'    => $ssidChanged,
    'channel_changed' => $channelChanged,
    'lora_changed'    => $loraChanged,
    'eth_changed'     => $ethChanged,
    'hash_ok'         => $hashOk,
    'reload_log'      => $reloadLog,
    'reload_errors'   => $reloadErrors,
    'backup_created'  => file_exists(CONFIG_FILE . '.bak'),
]);

// ── Réponse ───────────────────────────────────────────────────────────────────
$warns = array_filter([
    !$hashOk              ? 'hash_fail'      : '',
    !empty($reloadErrors) ? 'reload_partial' : '',
]);

redirect(true, implode(',', array_values($warns)));
