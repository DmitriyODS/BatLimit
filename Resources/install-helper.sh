#!/bin/bash
# Ставит службу batlimitd. Запускается приложением от имени root
# (через системный запрос пароля администратора).
#   $1 — путь к бинарнику демона внутри бандла
#   $2 — версия приложения
set -euo pipefail

DAEMON_SRC="${1:?нужен путь к демону}"
VERSION="${2:-0}"

LABEL="com.dmitriy.batlimit"
DAEMON_DST="/Library/PrivilegedHelperTools/$LABEL"
PLIST="/Library/LaunchDaemons/$LABEL.plist"
SUPPORT_DIR="/Library/Application Support/BatLimit"
LOG_FILE="/var/log/batlimit.log"

[[ -f "$DAEMON_SRC" ]] || { echo "не найден демон: $DAEMON_SRC" >&2; exit 1; }

# Останавливаем прошлую версию, если работает. Демон по SIGTERM сам снимает
# блокировку зарядки, поэтому обновление не оставит батарею запертой.
launchctl bootout "system/$LABEL" 2>/dev/null || true

install -d -m 755 -o root -g wheel /Library/PrivilegedHelperTools
install -o root -g wheel -m 755 "$DAEMON_SRC" "$DAEMON_DST"

# Каталог состояния: группа admin, чтобы приложение и CLI могли писать конфиг
# без повышения прав. Сам демон при этом остаётся единственным, кто пишет в SMC.
install -d -o root -g admin -m 775 "$SUPPORT_DIR"
if [[ ! -f "$SUPPORT_DIR/config.json" ]]; then
    cat > "$SUPPORT_DIR/config.json" <<'JSON'
{
  "chargeNow" : false,
  "high" : 80,
  "low" : 30,
  "mode" : "off"
}
JSON
fi
chown root:admin "$SUPPORT_DIR/config.json"
chmod 664 "$SUPPORT_DIR/config.json"

printf '%s' "$VERSION" > "$SUPPORT_DIR/installed-version"
chmod 644 "$SUPPORT_DIR/installed-version"

touch "$LOG_FILE"
chown root:wheel "$LOG_FILE"
chmod 644 "$LOG_FILE"

cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>              <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$DAEMON_DST</string>
    </array>
    <key>RunAtLoad</key>          <true/>
    <key>KeepAlive</key>          <true/>
    <key>ProcessType</key>        <string>Background</string>
    <key>StandardOutPath</key>    <string>$LOG_FILE</string>
    <key>StandardErrorPath</key>  <string>$LOG_FILE</string>
</dict>
</plist>
PLISTEOF
chown root:wheel "$PLIST"
chmod 644 "$PLIST"

launchctl bootstrap system "$PLIST"

# CLI — приятное дополнение, не обязательное: если /usr/local/bin недоступен,
# установка всё равно считается успешной.
CLI_SRC="$(dirname "$DAEMON_SRC")/batlimit"
if [[ -f "$CLI_SRC" ]]; then
    install -d -m 755 /usr/local/bin 2>/dev/null || true
    install -o root -g wheel -m 755 "$CLI_SRC" /usr/local/bin/batlimit 2>/dev/null || true
fi

echo "BatLimit $VERSION установлен"
