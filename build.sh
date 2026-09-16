#!/bin/bash
# Собирает BatLimit.app и BatLimit.dmg. Права root не нужны — приложение
# устанавливает свою службу само, при первом запуске.
#   ./build.sh          собрать
#   ./build.sh install  собрать и положить в /Applications
#
# Для проверки обновлений без публикации: BATLIMIT_VERSION, BATLIMIT_BUILD и
# BATLIMIT_FEED_URL подменяют версию, номер сборки и адрес appcast.xml.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_DIR"

# Версия живёт в git, а не здесь: последний тег вида v1.2.3 даёт 1.2.3,
# номер сборки — число коммитов (монотонное, в отличие от даты). Без git
# или без тегов собирается 0.0 — чтобы случайная сборка не выдавала себя
# за выпуск.
GIT_DESCRIBE="$(git describe --tags --always --dirty 2>/dev/null || true)"
VERSION="$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)"
VERSION="${BATLIMIT_VERSION:-${VERSION:-0.0}}"
BUILD_NUMBER="${BATLIMIT_BUILD:-$(git rev-list --count HEAD 2>/dev/null || date +%Y%m%d%H%M)}"
OUT_DIR="$PROJECT_DIR/build"

# Обновления (Sparkle). Номер сборки должен только расти: по нему Sparkle и
# решает, новее ли версия в appcast. Лента — всегда из последнего релиза.
FEED_URL="${BATLIMIT_FEED_URL:-https://github.com/DmitriyODS/BatLimit/releases/latest/download/appcast.xml}"
# Открытая половина ключа EdDSA. Закрытая — в связке ключей того, кто
# выпускает релизы (учётная запись «batlimit»); ею подписан каждый архив.
SPARKLE_PUBLIC_KEY="PLC16mw6kv6cDo4IZ89UU9eB0dr9+JXVSEmfU/TBNkA="
APP="$OUT_DIR/BatLimit.app"

if [[ -n "$GIT_DESCRIBE" ]]; then
    echo "==> Версия $VERSION, сборка $BUILD_NUMBER ($GIT_DESCRIBE)"
    if [[ "$GIT_DESCRIBE" == *-dirty ]]; then
        echo "    ВНИМАНИЕ: в рабочей копии есть незакоммиченные правки —"
        echo "    собранное не соответствует ни одному коммиту"
    fi
else
    echo "==> Версия $VERSION, сборка $BUILD_NUMBER (вне git-репозитория)"
fi

echo "==> Сборка (release, arm64)"
swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)"

echo "==> Формирование $APP"
rm -rf "$OUT_DIR"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

install -m 755 "$BIN/BatLimitApp" "$APP/Contents/MacOS/BatLimit"
install -m 755 "$BIN/batlimitd"   "$APP/Contents/Resources/batlimitd"
install -m 755 "$BIN/batlimit"    "$APP/Contents/Resources/batlimit"
install -m 755 "$PROJECT_DIR/Resources/install-helper.sh"   "$APP/Contents/Resources/"
install -m 755 "$PROJECT_DIR/Resources/uninstall-helper.sh" "$APP/Contents/Resources/"
# ditto, а не cp: внутри фреймворка символические ссылки Versions/Current.
ditto "$BIN/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"

# Переводы. Язык выбирает macOS по списку предпочтений пользователя: каталог
# <язык>.lproj внутри Resources — единственное, что для этого нужно.
for LPROJ in "$PROJECT_DIR"/Resources/*.lproj; do
    [[ -d "$LPROJ" ]] || continue
    mkdir -p "$APP/Contents/Resources/$(basename "$LPROJ")"
    install -m 644 "$LPROJ"/*.strings "$APP/Contents/Resources/$(basename "$LPROJ")/"
done

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
    <key>CFBundleDevelopmentRegion</key>    <string>en</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>en</string>
        <string>ru</string>
    </array>
    <key>CFBundleExecutable</key>           <string>BatLimit</string>
    <key>CFBundlePackageType</key>          <string>APPL</string>
    <key>CFBundleShortVersionString</key>   <string>$VERSION</string>
    <key>CFBundleVersion</key>              <string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key>       <string>13.0</string>
    <key>LSApplicationCategoryType</key>    <string>public.app-category.utilities</string>
    <key>NSHumanReadableCopyright</key>     <string>BatLimit $VERSION</string>
    <key>BLGitDescribe</key>                <string>${GIT_DESCRIBE:-неизвестно}</string>
    <key>SUFeedURL</key>                    <string>$FEED_URL</string>
    <key>SUPublicEDKey</key>                <string>$SPARKLE_PUBLIC_KEY</string>
    <!-- Проверять раз в сутки, не спрашивая разрешения при втором запуске:
         выключается в настройках BatLimit -->
    <key>SUEnableAutomaticChecks</key>      <true/>
$ICON_ENTRY
    <!-- Живёт только в строке меню: без окна и без значка в Dock -->
    <key>LSUIElement</key>                  <true/>
</dict>
</plist>
PLIST

# Ad-hoc подпись: Developer ID нет, но без всякой подписи macOS ругается сильнее.
# Подписываем изнутри наружу. Фреймворк Sparkle переподписываем тоже: его
# установщик сверяет подпись с приложением, и чужая команда разработчика
# рядом с ad-hoc приложением этой сверки не прошла бы.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
for PART in "$SPARKLE/XPCServices/Downloader.xpc" "$SPARKLE/XPCServices/Installer.xpc" \
            "$SPARKLE/Autoupdate" "$SPARKLE/Updater.app" "$APP/Contents/Frameworks/Sparkle.framework"; do
    [[ -e "$PART" ]] || continue
    codesign --force --sign - --preserve-metadata=entitlements "$PART" >/dev/null 2>&1 \
        || { echo "не удалось подписать $PART" >&2; exit 1; }
done
codesign --force --sign - "$APP" >/dev/null 2>&1 \
    || echo "    (подписать не удалось — приложение всё равно запустится)"

# Архив для Sparkle. Образ — для людей, а обновлению удобнее zip: ditto
# сохраняет символические ссылки фреймворка, обычный zip их бы развернул.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT_DIR/BatLimit.zip"

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
echo "  $OUT_DIR/BatLimit.zip   (для обновления через Sparkle)"

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
