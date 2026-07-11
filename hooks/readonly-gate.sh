#!/usr/bin/env bash
# readonly-gate.sh — PreToolUse-хук: блокирует запись в аудируемый чужой офис (target).
#
# Контракт хука Claude Code: на stdin JSON {"tool_name":"Write","tool_input":{...}}.
# Заблокировать вызов = exit 2 + причина в stderr (её увидит модель). Разрешить = exit 0.
# Цена ошибки = порча чужого рабочего офиса, поэтому композитные/пишущие Bash — блокируем.
#
# Состояние берём из OU_STATE_DIR (дефолт <repo>/state):
#   target.path        — одна строка, абсолютный путь аудируемого офиса.
#   mutation-unlocked  — если есть и содержит путь существующего снапшота, мутации разрешены.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
STATE_DIR="${OU_STATE_DIR:-$REPO/state}"

# Хук не должен ронять сессию: любой сбой — пропускаем (exit 0), предупредив в stderr.
input="$(cat)"
if ! printf '%s' "$input" | jq -e . >/dev/null 2>&1; then
  echo "readonly-gate: не смог разобрать JSON вызова, пропускаю" >&2
  exit 0
fi

# Гейт неактивен, пока не задан target — ничего не защищаем.
target_file="$STATE_DIR/target.path"
[[ -s "$target_file" ]] || exit 0
target_raw="$(head -n1 "$target_file")"
[[ -n "$target_raw" ]] || exit 0

# Нормализованный абсолютный путь target (со снятием symlink), если каталог существует.
norm_target="$target_raw"
if [[ -d "$target_raw" ]]; then norm_target="$(cd "$target_raw" && pwd -P)"; fi

# Разблокировка мутаций: файл существует И указывает на существующий каталог-снапшот.
unlock_file="$STATE_DIR/mutation-unlocked"
if [[ -s "$unlock_file" ]]; then
  unlock_snap="$(head -n1 "$unlock_file")"
  if [[ -n "$unlock_snap" && -d "$unlock_snap" ]]; then
    exit 0
  fi
fi

tool_name="$(printf '%s' "$input" | jq -r '.tool_name // empty')"

block() { echo "readonly-gate: $1" >&2; exit 2; }

# Нормализация произвольного пути: раскрываем ~, делаем абсолютным, снимаем symlink
# с ближайшего существующего предка (сам путь может ещё не существовать).
norm_path() {
  local p="$1" tail=""
  p="${p/#\~/$HOME}"
  [[ "$p" = /* ]] || p="$PWD/$p"
  while [[ ! -d "$p" ]]; do
    tail="/$(basename "$p")$tail"
    p="$(dirname "$p")"
    [[ "$p" == "/" ]] && break
  done
  [[ -d "$p" ]] && p="$(cd "$p" && pwd -P)"
  printf '%s%s\n' "$p" "$tail"
}

inside_target() {
  local child; child="$(norm_path "$1")"
  [[ "$child" == "$norm_target" || "$child" == "$norm_target"/* ]]
}

# Подкоманда git, с пропуском глобальных опций (-C DIR, -c k=v, --no-pager …).
# set -f вокруг word-splitting: иначе глоб в аргументе раскрылся бы против cwd хука.
git_subcommand() {
  local -a toks; set -f; toks=($1); set +f; local i=1 t
  while (( i < ${#toks[@]} )); do
    t="${toks[i]}"
    case "$t" in
      -C|-c) i=$((i + 2)); continue ;;
      -*)    i=$((i + 1)); continue ;;
      *)     printf '%s\n' "$t"; return ;;
    esac
  done
}

# Доказуемо read-only ли Bash-команда. Модель default-deny: грамматика оболочки богаче
# любого блоклиста, поэтому разрешаем ТОЛЬКО одиночную простую команду без метасимволов
# (никаких >,<,|,;,&,$,подстановок,переводов строки), где первое слово — из строгого
# allowlist, а у find нет пишущих/исполняющих действий. Всё остальное — не read-only.
is_readonly_bash() {
  local c="$1"
  # Любой метасимвол записи/побочки/цепочки → не доказуемо read-only.
  case "$c" in
    *'>'*|*'<'*|*'|'*|*';'*|*'&'*|*'$'*|*'`'*|*'('*|*')'*) return 1 ;;
  esac
  case "$c" in
    *$'\n'*) return 1 ;;
  esac
  # Первое слово (без глоб-раскрытия против cwd хука).
  local -a toks; set -f; toks=($c); set +f
  local first="${toks[0]:-}"
  [[ -n "$first" ]] || return 1
  case "$first" in
    ls|cat|head|tail|grep|rg|find|wc|shasum|md5|md5sum|diff|jq|stat|file|du|tree)
      if [[ "$first" == find ]]; then
        # find умеет писать/исполнять — блокируем такие действия.
        case " $c " in
          *" -exec"*|*" -execdir"*|*" -ok"*|*" -okdir"*|*" -delete"*|\
          *" -fprintf"*|*" -fls"*|*" -fprint"*|*" -fprint0"*) return 1 ;;
        esac
      fi
      return 0 ;;
    git)
      local sub; sub="$(git_subcommand "$c")"
      case "$sub" in
        status|log|diff|show|grep|branch) return 0 ;;
        remote) [[ "$c" == *"remote -v"* || "$c" == *"remote --verbose"* ]] && return 0 || return 1 ;;
        *) return 1 ;;
      esac
      ;;
  esac
  return 1
}

case "$tool_name" in
  Write|Edit|NotebookEdit)
    fp="$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty')"
    [[ -n "$fp" ]] || exit 0
    if inside_target "$fp"; then
      block "запись в аудируемый офис заблокирована: $fp. Сначала сними слепок и разблокируй мутации."
    fi
    exit 0
    ;;
  Bash)
    cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty')"
    [[ -n "$cmd" ]] || exit 0
    # Гейт активен и мутации не разблокированы → тур read-only. Косвенная запись в офис
    # (симлинк-алиас, относительный путь при cwd в офисе, $VAR) в сырой строке не видна,
    # поэтому НЕ пытаемся доказать «трогает target»: пропускаем ТОЛЬКО доказуемо read-only.
    if is_readonly_bash "$cmd"; then
      exit 0
    fi
    block "Bash-команда не доказуемо read-only, во время аудита блокирую: $cmd. Разреши мутации или используй простую read-only команду (ls/cat/grep/find/git status …)."
    ;;
  *)
    # Неизвестный инструмент (в т.ч. файловый MCP). Блокируем, только если он адресует
    # путь внутри target И похож на пишущий — так чтение офиса (Read/Glob) не ломаем.
    path="$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.path // .tool_input.notebook_path // empty')"
    [[ -n "$path" ]] || exit 0
    inside_target "$path" || exit 0
    name_lc="$(printf '%s' "$tool_name" | tr '[:upper:]' '[:lower:]')"
    name_lc="${name_lc//_/ }"; name_lc="${name_lc//-/ }"
    name_lc="${name_lc//./ }"; name_lc="${name_lc//\// }"
    writes=false
    case " $name_lc " in
      *" write"*|*" writes"*|*" edit"*|*" edits"*|*" create"*|*" creates"*|\
      *" delete"*|*" deletes"*|*" put"*|*" puts"*|*" patch"*|*" patches"*|\
      *" move"*|*" moves"*|*" append"*|*" upload"*) writes=true ;;
    esac
    if [[ "$writes" != true ]]; then
      # Наличие тела записи (content/text/…) при пути в target — тоже пишущий вызов.
      has_content="$(printf '%s' "$input" | jq -r 'if (.tool_input // {}) | (has("content") or has("text") or has("data") or has("body") or has("new_string") or has("new_source") or has("source")) then "1" else "" end')"
      [[ "$has_content" == "1" ]] && writes=true
    fi
    [[ "$writes" == true ]] && block "инструмент $tool_name пишет в аудируемый офис: $path. Разблокируй мутации."
    exit 0
    ;;
esac
