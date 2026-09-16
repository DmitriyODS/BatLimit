#!/bin/bash
# Готовит build/appcast.xml — ленту обновлений для Sparkle. Запускать после
# ./build.sh, ровно на теге выпуска:
#   Tools/make-appcast.sh <заметки.md>
#
# Архив подписывается закрытым ключом EdDSA из связки ключей (учётная запись
# «batlimit»). Без него лента не соберётся — и это правильно: неподписанное
# обновление приложения установить не даст.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

NOTES="${1:?укажи файл с описанием версии в Markdown}"
[[ -f "$NOTES" ]] || { echo "нет файла $NOTES" >&2; exit 1; }
[[ -f build/BatLimit.zip ]] || { echo "нет build/BatLimit.zip — сначала ./build.sh" >&2; exit 1; }

# Ссылка на архив ведёт в релиз с этим тегом — собирать ленту не с тега
# значит выдать ссылку на чужой архив.
TAG="$(git describe --tags --exact-match 2>/dev/null)" \
    || { echo "HEAD не стоит на теге выпуска" >&2; exit 1; }

TOOLS="$PROJECT_DIR/.build/artifacts/sparkle/Sparkle/bin"
[[ -x "$TOOLS/generate_appcast" ]] \
    || { echo "нет инструментов Sparkle — выполни swift package resolve" >&2; exit 1; }

# generate_appcast берёт каталог архивов и описания к ним с тем же именем.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cp build/BatLimit.zip "$WORK/BatLimit.zip"
cp "$NOTES" "$WORK/BatLimit.md"

"$TOOLS/generate_appcast" \
    --account batlimit \
    --download-url-prefix "https://github.com/DmitriyODS/BatLimit/releases/download/$TAG/" \
    --embed-release-notes \
    --maximum-deltas 0 \
    --link "https://github.com/DmitriyODS/BatLimit" \
    "$WORK"

cp "$WORK/appcast.xml" build/appcast.xml
echo "Готово: build/appcast.xml ($TAG)"
echo "К релизу приложить: build/BatLimit.dmg, build/BatLimit.zip, build/appcast.xml"
