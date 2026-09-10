#!/bin/bash
# Собирает BatLimit.app и BatLimit.dmg. Права root не нужны — приложение
# устанавливает свою службу само, при первом запуске.
#   ./build.sh          собрать
#   ./build.sh install  собрать и положить в /Applications
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_DIR"

VERSION="1.0"
BUILD_NUMBER="$(date +%Y%m%d%H%M)"
OUT_DIR="$PROJECT_DIR/build"
APP="$OUT_DIR/BatLimit.app"

echo "==> Сборка (release, arm64)"
swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)"

echo "==> Формирование $APP"
rm -rf "$OUT_DIR"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

install -m 755 "$BIN/BatLimitApp" "$APP/Contents/MacOS/BatLimit"
install -m 755 "$BIN/batlimitd"   "$APP/Contents/Resources/batlimitd"
install -m 755 "$BIN/batlimit"    "$APP/Contents/Resources/batlimit"
install -m 755 "$PROJECT_DIR/Resources/install-helper.sh"   "$APP/Contents/Resources/"
install -m 755 "$PROJECT_DIR/Resources/uninstall-helper.sh" "$APP/Contents/Resources/"

if [[ -f "$PROJECT_DIR/Resources/AppIcon.icns" ]]; then
    install -m 644 "$PROJECT_DIR/Resources/AppIcon.icns" "$APP/Contents/Resources/"
    ICON_ENTRY='    <key>CFBundleIconFile</key>             <string>AppIcon</string>'
else
    ICON_ENTRY=''
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                 <string>BatLimit</string>
    <key>CFBundleDisplayName</key>          <string>BatLimit</string>
    <key>CFBundleIdentifier</key>           <string>com.dmitriy.batlimit.app</string>
    <key>CFBundleExecutable</key>           <string>BatLimit</string>
    <key>CFBundlePackageType</key>          <string>APPL</string>
    <key>CFBundleShortVersionString</key>   <string>$VERSION</string>
    <key>CFBundleVersion</key>              <string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key>       <string>13.0</string>
    <key>LSApplicationCategoryType</key>    <string>public.app-category.utilities</string>
    <key>NSHumanReadableCopyright</key>     <string>BatLimit $VERSION</string>
$ICON_ENTRY
    <!-- Живёт только в строке меню: без окна и без значка в Dock -->
    <key>LSUIElement</key>                  <true/>
</dict>
</plist>
PLIST

# Ad-hoc подпись: Developer ID нет, но без всякой подписи macOS ругается сильнее.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 \
    || echo "    (подписать не удалось — приложение всё равно запустится)"

echo "==> Сборка образа BatLimit.dmg"
VOLNAME="BatLimit"
SETUP_NAME="Установить BatLimit.command"
STAGING="$OUT_DIR/dmg"
RW_DMG="$OUT_DIR/rw.dmg"
DMG="$OUT_DIR/BatLimit.dmg"
BG="$OUT_DIR/dmg-background.png"

swift "$PROJECT_DIR/Tools/make-dmg-background.swift" "$BG"

rm -rf "$STAGING"
mkdir -p "$STAGING/.background"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
install -m 755 "$PROJECT_DIR/Resources/dmg-setup.command" "$STAGING/$SETUP_NAME"
cp "$BG" "$STAGING/.background/background.png"

# Прерванная сборка могла оставить том примонтированным — иначе получим
# «BatLimit 1» и оформим не тот образ.
hdiutil detach "/Volumes/$VOLNAME" -quiet 2>/dev/null || true

# Оформление живёт в .DS_Store, а его пишет Finder — значит образ должен быть
# записываемым. Сжимаем уже после того, как раскладка сохранена.
rm -f "$RW_DMG"
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGING" -ov -quiet \
    -format UDRW -fs HFS+ "$RW_DMG"

MOUNT="$(hdiutil attach "$RW_DMG" -noautoopen | grep -o '/Volumes/.*' | tail -1)"
[[ -n "$MOUNT" ]] || { echo "не удалось смонтировать $RW_DMG" >&2; exit 1; }
VOL="$(basename "$MOUNT")"

# Finder'ом управляем через Apple Events: при первом запуске macOS спросит
# разрешение на автоматизацию. Откажут — образ соберётся, просто без оформления.
if osascript >/dev/null 2>&1 <<APPLESCRIPT
tell application "Finder"
    tell disk "$VOL"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 860, 560}
        set opts to the icon view options of container window
        set arrangement of opts to not arranged
        set icon size of opts to 96
        set text size of opts to 12
        set background picture of opts to file ".background:background.png"
        set position of item "BatLimit.app" of container window to {170, 170}
        set position of item "Applications" of container window to {490, 170}
        set position of item "$SETUP_NAME" of container window to {170, 335}
        update without registering applications
        delay 2
        close
    end tell
end tell
APPLESCRIPT
then
    echo "    оформление окна применено"
else
    echo "    (оформить окно не удалось — нужно разрешение «Автоматизация» для Terminal;"
    echo "     образ собран, но откроется стандартным списком)"
fi

sync
hdiutil detach "$MOUNT" -quiet || hdiutil detach "$MOUNT" -force -quiet
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -ov -quiet -o "$DMG"
rm -f "$RW_DMG"
rm -rf "$STAGING"

echo
echo "Готово:"
echo "  $APP"
echo "  $OUT_DIR/BatLimit.dmg"

if [[ "${1:-}" == "install" ]]; then
    echo
    echo "==> Установка в /Applications"
    # Запущенную копию сначала останавливаем, иначе Finder держит файлы.
    pkill -x BatLimit 2>/dev/null || true
    sleep 1
    rm -rf /Applications/BatLimit.app
    cp -R "$APP" /Applications/
    xattr -dr com.apple.quarantine /Applications/BatLimit.app 2>/dev/null || true
    open /Applications/BatLimit.app
    echo "BatLimit запущен — иконка появилась в строке меню."
fi
