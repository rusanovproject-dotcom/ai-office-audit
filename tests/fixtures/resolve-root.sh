# --- ai-office-audit: находим ДОВЕРЕННЫЙ корень пака (где engine/); CWD чужого офиса не доверяем ---
# Канон. Исполняемые строки ниже дословно вшиты в каждый .claude/skills/audit-*/SKILL.md
# (drift-guard в tests/resolve-root.bats сверяет каждую). После source: $PACK_ROOT — доверенный
# корень, CWD = он, дальше engine/*.sh идут относительно. Маркер .ai-office-audit — публичный
# и подделываемый, поэтому САМ ПО СЕБЕ он не доверенный якорь: принимаем каталог из обхода вверх
# только если это наш git-клон (origin == ai-office-audit). $HOME-клон доверяем как свою ФС.
PACK_ROOT=""
if [ -f "$HOME/ai-office-audit/.ai-office-audit" ]; then PACK_ROOT="$HOME/ai-office-audit"; fi
if [ -z "$PACK_ROOT" ]; then _d="$PWD"; while [ "$_d" != "/" ]; do
  if [ -f "$_d/.ai-office-audit" ]; then
    case "$(git -C "$_d" config --get remote.origin.url 2>/dev/null)" in
      */ai-office-audit|*/ai-office-audit.git|*/ai-office-audit/) PACK_ROOT="$_d" ;;
    esac
    break
  fi
  _d="$(dirname "$_d")"
done; fi
if [ -z "$PACK_ROOT" ]; then echo 'ai-office-audit: доверенный корень пака не найден — склонируй ОФИЦИАЛЬНЫЙ репо и запусти /audit-* из его папки (README). Из каталога проверяемого офиса не запускай.' >&2; exit 1; fi
cd "$PACK_ROOT" && echo "pack root: $PACK_ROOT"
