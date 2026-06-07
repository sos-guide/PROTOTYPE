<?php
/**
 * SOS-GUIDE — lib/whitelist.php
 * Whitelist IP partagée : WiFi AP (10.0.0.x) toujours, ETH privé si enableEthernet=true.
 * Inclus par update_config.php et api_reload_network_proxy.php.
 */

if (!defined('CONFIG_FILE')) {
    define('CONFIG_FILE', '/var/www/sos-guide/data/config.json');
}

function is_allowed_ip(string $remote): bool
{
    if (in_array($remote, ['127.0.0.1', '::1'], true)) return true;

    // Réseau AP WiFi — toujours autorisé
    if (preg_match('/^10\.0\.0\.\d{1,3}$/', $remote)) return true;

    // Réseau ETH privé — uniquement si enableEthernet=true dans config
    $cfg = [];
    if (file_exists(CONFIG_FILE)) {
        $cfg = json_decode((string) file_get_contents(CONFIG_FILE), true) ?? [];
    }
    if ($cfg['enableEthernet'] ?? false) {
        if (preg_match('/^192\.168\.\d{1,3}\.\d{1,3}$/', $remote))                return true;
        if (preg_match('/^172\.(1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3}$/', $remote)) return true;
        // 10.x.x.x hors 10.0.0.x déjà traité
        if (preg_match('/^10\.(?!0\.0\.)\d{1,3}\.\d{1,3}\.\d{1,3}$/', $remote))   return true;
    }
    return false;
}
