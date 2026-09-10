#!/bin/bash
# Удаляет службу batlimitd и возвращает обычную зарядку.
# Запускается приложением от имени root.
set -uo pipefail

LABEL="com.dmitriy.batlimit"
SUPPORT_DIR="/Library/Application Support/BatLimit"

# Сначала просим демон вернуть обычный режим, потом останавливаем: так батарея
# гарантированно не останется с запрещённой зарядкой.
if [[ -f "$SUPPORT_DIR/config.json" ]]; then
    cat > "$SUPPORT_DIR/config.json" <<'JSON'
{ "chargeNow" : false, "high" : 80, "low" : 30, "mode" : "off" }
JSON
    sleep 2
fi

launchctl bootout "system/$LABEL" 2>/dev/null || true
sleep 1

rm -f "/Library/LaunchDaemons/$LABEL.plist"
rm -f "/Library/PrivilegedHelperTools/$LABEL"
rm -f /usr/local/bin/batlimit
rm -rf "$SUPPORT_DIR"
rm -f /var/log/batlimit.log

echo "BatLimit удалён"
