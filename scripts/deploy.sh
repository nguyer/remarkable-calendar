#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
HOST="${1:-10.11.99.1}"
[[ "$HOST" =~ ^[a-zA-Z0-9._:-]+$ ]] || { echo 'Invalid host' >&2; exit 1; }
for f in resources.rcc manifest.json icon.png backend/entry; do test -f "dist/remarkable-calendar/$f" || { echo "Missing $f: build first" >&2; exit 1; }; done
# Close reMarkable Calendar and stop any manually launched v0.2 backend before deployment.
ssh "root@$HOST" 'mkdir -p /home/root/xovi/exthome/appload/remarkable-calendar/backend'
scp dist/remarkable-calendar/{manifest.json,resources.rcc,icon.png} "root@$HOST:/home/root/xovi/exthome/appload/remarkable-calendar/"
scp dist/remarkable-calendar/backend/entry "root@$HOST:/home/root/xovi/exthome/appload/remarkable-calendar/backend/entry.new"
ssh "root@$HOST" 'chmod 755 /home/root/xovi/exthome/appload/remarkable-calendar/backend/entry.new && mv /home/root/xovi/exthome/appload/remarkable-calendar/backend/entry.new /home/root/xovi/exthome/appload/remarkable-calendar/backend/entry'
echo 'Deployed. Open Calendar in AppLoad; backend starts automatically.'
