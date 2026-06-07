#!/bin/bash
# sos-guide-fetch-tiles.sh — Téléchargement des tuiles OSM hors-ligne
# Lit lat/lon/mapZoom depuis config.json, calcule la bounding box et
# télécharge les tuiles OpenStreetMap pour les niveaux de zoom z-2 à z.
# Stocke les tuiles dans /var/www/sos-guide/tiles/{z}/{x}/{y}.png
# Usage : bash sos-guide-fetch-tiles.sh [--config /chemin/config.json]

set -euo pipefail

CONFIG_FILE="${1:-/var/www/sos-guide/data/config.json}"
TILES_DIR="/var/www/sos-guide/tiles"
OSM_URL="https://tile.openstreetmap.org"
MAX_TILES=2000
LOG="/var/log/sos-guide-fetch-tiles.log"

log()  { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG"; }
warn() { log "WARN  $*"; }
err()  { log "ERROR $*"; exit 1; }

# ── Lire config ───────────────────────────────────────────────────────────────
if ! command -v jq &>/dev/null; then
    apt-get update -qq && apt-get install -y -qq jq
fi
if ! command -v python3 &>/dev/null; then
    apt-get install -y -qq python3
fi

if [ ! -f "$CONFIG_FILE" ]; then
    err "config.json introuvable : $CONFIG_FILE"
fi

LAT=$(jq -r '.establishment.lat // ""' "$CONFIG_FILE")
LON=$(jq -r '.establishment.lon // ""' "$CONFIG_FILE")
ZOOM=$(jq -r '.establishment.mapZoom // 15' "$CONFIG_FILE")

if [ -z "$LAT" ] || [ -z "$LON" ] || [ "$LAT" = "null" ] || [ "$LON" = "null" ]; then
    err "Coordonnées GPS non configurées dans config.json — rien à télécharger."
fi

log "Coordonnées : lat=$LAT lon=$LON zoom=$ZOOM"

# ── Calcul lon/lat → numéro de tuile ─────────────────────────────────────────
deg2tile() {
    python3 - "$1" "$2" "$3" <<'EOF'
import math, sys
lat, lon, z = float(sys.argv[1]), float(sys.argv[2]), int(sys.argv[3])
n = 2**z
x = int((lon + 180) / 360 * n)
y = int((1 - math.log(math.tan(math.radians(lat)) + 1/math.cos(math.radians(lat))) / math.pi) / 2 * n)
print(x, y)
EOF
}

# ── Télécharger tuiles pour une plage de zoom ─────────────────────────────────
ZOOM_MIN=$(( ZOOM - 2 ))
[ "$ZOOM_MIN" -lt 10 ] && ZOOM_MIN=10
ZOOM_MAX=$ZOOM

DELTA=0.05  # ~5 km autour du point central
LAT_MIN=$(python3 -c "print($LAT - $DELTA)")
LAT_MAX=$(python3 -c "print($LAT + $DELTA)")
LON_MIN=$(python3 -c "print($LON - $DELTA)")
LON_MAX=$(python3 -c "print($LON + $DELTA)")

mkdir -p "$TILES_DIR"
TOTAL=0
SKIP=0
ERR=0

for z in $(seq "$ZOOM_MIN" "$ZOOM_MAX"); do
    read -r x_min y_max < <(deg2tile "$LAT_MIN" "$LON_MIN" "$z")
    read -r x_max y_min < <(deg2tile "$LAT_MAX" "$LON_MAX" "$z")
    COUNT=$(( (x_max - x_min + 1) * (y_max - y_min + 1) ))
    log "Zoom $z : tuiles [$x_min-$x_max] × [$y_min-$y_max] ($COUNT tuiles)"
    for x in $(seq "$x_min" "$x_max"); do
        for y in $(seq "$y_min" "$y_max"); do
            if [ "$TOTAL" -ge "$MAX_TILES" ]; then
                warn "Limite MAX_TILES=$MAX_TILES atteinte — arrêt."
                break 3
            fi
            dest="$TILES_DIR/$z/$x/$y.png"
            if [ -f "$dest" ]; then
                SKIP=$(( SKIP + 1 ))
                continue
            fi
            mkdir -p "$(dirname "$dest")"
            if wget -q -O "$dest" "${OSM_URL}/${z}/${x}/${y}.png" \
                   --user-agent="SOS-GUIDE/2.5 (emergency offline system; +https://sos-guide.fr)" \
                   --timeout=10 2>>"$LOG"; then
                TOTAL=$(( TOTAL + 1 ))
                sleep 0.1  # respecter le fair-use OSM
            else
                rm -f "$dest"
                ERR=$(( ERR + 1 ))
            fi
        done
    done
done

log "Terminé : $TOTAL tuiles téléchargées, $SKIP déjà présentes, $ERR erreurs."

# Fixer les permissions
find "$TILES_DIR" -type f -name '*.png' -exec chmod 644 {} +
find "$TILES_DIR" -type d -exec chmod 755 {} +
chown -R www-data:www-data "$TILES_DIR" 2>/dev/null || true

log "Tuiles disponibles dans $TILES_DIR"
