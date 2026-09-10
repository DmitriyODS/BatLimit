#!/bin/bash
# Установщик BatLimit с образа.
#
# Делает то, что вручную приходится делать после скачивания неподписанного
# приложения: проверяет, подходит ли Mac, копирует программу в «Программы»,
# снимает карантин Gatekeeper и возвращает бит выполнения.
#
# Сам скрипт при первом запуске тоже под карантином, поэтому открывать его
# нужно через правую кнопку → «Открыть». Обычный двойной щелчок macOS
# заблокирует — это ограничение Gatekeeper, обойти его изнутри образа нельзя.

set -uo pipefail

APP_NAME="BatLimit.app"
DEST_DIR="/Applications"
DEST="$DEST_DIR/$APP_NAME"

if [[ -t 1 ]]; then
    B=$'\033[1m'; DIM=$'\033[2m'; R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; N=$'\033[0m'
else
    B=''; DIM=''; R=''; G=''; Y=''; N=''
fi

say()  { printf '%s\n' "$*"; }
ok()   { printf '%s✓%s %s\n' "$G" "$N" "$*"; }
warn() { printf '%s!%s %s\n' "$Y" "$N" "$*"; }

# Окно Terminal закрывать сразу нельзя — иначе ошибку никто не прочитает.
# Паузу делаем только при живом терминале: запущенный из другого скрипта или
# из CI установщик не должен висеть на чтении ввода, которого не будет.
finish() {
    local code=$1
    say ""
    if [[ -t 0 ]]; then
        printf '%s' "${DIM}Нажми Enter, чтобы закрыть окно.${N}"
        read -r _ || true
    fi
    exit "$code"
}

die() {
    say ""
    printf '%s✗ %s%s\n' "$R" "$*" "$N"
    finish 1
}

say ""
say "${B}Установка BatLimit${N}"
say "${DIM}ограничитель зарядки батареи для MacBook на Apple Silicon${N}"
say ""

# --- 1. Подходит ли машина -------------------------------------------------
# Проверяем до копирования: незачем засорять «Программы» тем, что не заработает.
say "${B}1.${N} Проверка Mac"

MODEL="$(/usr/sbin/sysctl -n hw.model 2>/dev/null || echo 'неизвестно')"
CHIP="$(/usr/sbin/sysctl -n machdep.cpu.brand_string 2>/dev/null || echo 'неизвестно')"
OS_VER="$(/usr/bin/sw_vers -productVersion 2>/dev/null || echo '0')"
OS_MAJOR="${OS_VER%%.*}"

say "   модель:    $MODEL"
say "   процессор: $CHIP"
say "   macOS:     $OS_VER"

# Под Rosetta `uname -m` врёт про x86_64, поэтому спрашиваем ядро напрямую.
if [[ "$(/usr/sbin/sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" != "1" ]]; then
    die "нужен Mac на Apple Silicon (M1 и новее). Здесь: $CHIP"
fi
if [[ "$OS_MAJOR" -lt 13 ]] 2>/dev/null; then
    die "нужна macOS 13 или новее, установлена $OS_VER"
fi
# `-rc` показывает поддерево найденного класса; `-d 1` здесь не годится —
# он обрезает обход на первом уровне, а батарея лежит гораздо глубже.
# Результат забираем в переменную, а не через `| grep -q`: grep выходит на
# первом же совпадении, ioreg получает SIGPIPE, и `pipefail` объявляет всю
# цепочку неудачной — на машине с батареей мы получали «батареи нет».
BATTERY="$(/usr/sbin/ioreg -rc AppleSmartBattery 2>/dev/null || true)"
if [[ -z "$BATTERY" ]]; then
    die "в этом Mac нет встроенной батареи — ограничивать нечего"
fi
ok "Mac подходит"

# --- 2. Откуда ставим ------------------------------------------------------
SRC_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SRC="$SRC_DIR/$APP_NAME"
[[ -d "$SRC" ]] || die "рядом со скриптом нет $APP_NAME (ищу в $SRC_DIR)"

say ""
say "${B}2.${N} Копирование в «Программы»"

if [[ ! -w "$DEST_DIR" ]]; then
    die "нет прав на запись в $DEST_DIR — перетащи $APP_NAME туда вручную и запусти скрипт снова"
fi

# Запущенную копию сначала гасим, иначе файлы заняты и cp упадёт на полпути.
if pgrep -x BatLimit >/dev/null 2>&1; then
    pkill -x BatLimit 2>/dev/null || true
    sleep 1
fi

rm -rf "$DEST" || die "не удалось убрать прежнюю версию $DEST"
cp -R "$SRC" "$DEST_DIR/" || die "не удалось скопировать в $DEST_DIR"
ok "скопировано в $DEST"

# --- 3. Карантин и права ---------------------------------------------------
say ""
say "${B}3.${N} Снятие карантина"

# Сборка не подписана Developer ID: без снятия атрибута macOS откажется
# открывать программу и не объяснит толком почему.
if /usr/bin/xattr -dr com.apple.quarantine "$DEST" 2>/dev/null; then
    ok "атрибут com.apple.quarantine снят"
else
    warn "снять карантин не удалось — если macOS откажется открывать программу,"
    warn "выполни: xattr -dr com.apple.quarantine $DEST"
fi

# Права на выполнение теряются при копировании через некоторые архиваторы.
chmod +x "$DEST/Contents/MacOS/BatLimit" 2>/dev/null || true
for helper in batlimitd batlimit install-helper.sh uninstall-helper.sh; do
    chmod +x "$DEST/Contents/Resources/$helper" 2>/dev/null || true
done
ok "права на выполнение восстановлены"

# --- 4. Полная проверка совместимости --------------------------------------
# Теперь, когда карантин снят, можно запустить настоящую проверку из бандла:
# она умеет то, что шеллу недоступно, — читает SMC и смотрит набор ключей.
say ""
say "${B}4.${N} Проверка контроллера питания"

CHECK_BIN="$DEST/Contents/Resources/batlimit"
if [[ -x "$CHECK_BIN" ]]; then
    if CHECK_OUT="$("$CHECK_BIN" check 2>&1)"; then
        say "$CHECK_OUT" | sed 's/^/   /'
        ok "контроллер питания отвечает"
    else
        say "$CHECK_OUT" | sed 's/^/   /'
        die "этот Mac не поддерживается — программа установлена, но работать не будет"
    fi
else
    warn "не нашёл $CHECK_BIN, пропускаю проверку"
fi

# --- 5. Запуск -------------------------------------------------------------
say ""
say "${B}5.${N} Запуск"
open "$DEST" || die "не удалось запустить $DEST"
ok "BatLimit запущен — значок появился в строке меню"

say ""
say "${DIM}При первом запуске программа попросит пароль администратора и поставит"
say "фоновую службу. Дальше пароль больше не спрашивается.${N}"
finish 0
