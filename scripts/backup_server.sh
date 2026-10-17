#!/usr/bin/env bash
# Sicherung der Spielstände auf dem Server (läuft per Cron, installiert mit `./deploy cron`).
# Kopiert profiles.json und territory.json aus dem Container nach ~/osp-backups und löscht Sicherungen,
# die älter als 14 Tage sind. Ist der Container nicht erreichbar, endet das Skript mit Fehler (steht im Log).
set -euo pipefail

dir="$HOME/osp-backups"
mkdir -p "$dir"
stamp=$(date +%Y%m%d-%H%M%S)

docker cp osp:/data/profiles.json "$dir/profiles-$stamp.json"
# territory.json gibt es erst nach der ersten Eroberung
docker cp osp:/data/territory.json "$dir/territory-$stamp.json" 2>/dev/null || true

find "$dir" -maxdepth 1 -type f \( -name 'profiles-*.json' -o -name 'territory-*.json' \) -mtime +14 -delete
echo "$(date '+%F %T') gesichert: profiles-$stamp.json"
