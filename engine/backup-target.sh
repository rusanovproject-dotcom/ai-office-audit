#!/usr/bin/env bash
# backup-target.sh — контентный слепок чужого рабочего AI-офиса и восстановление из него.
#
# Слепок = cp -a СОДЕРЖИМОГО target (включая .git), а НЕ git-ветка. Причина:
# git-ветка пишет в чужой .git и не ловит незакоммиченное, а живой офис почти
# всегда грязный. Слепок обязан восстанавливать офис вместе с незакоммиченными
# правками и untracked-файлами. Цена ошибки = потеря клиента, изоляция — святое.
#
#   backup-target.sh --target DIR [--snapshots-root DIR]     # снять слепок
#   backup-target.sh --restore SNAPDIR --target DIR [--force] # восстановить
#
# Бэкап печатает путь снапшота последней строкой stdout.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"

MODE=backup
TARGET=""
SNAPSHOTS_ROOT=""
RESTORE_SNAP=""
FORCE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)         TARGET="$2";         shift 2 ;;
    --snapshots-root) SNAPSHOTS_ROOT="$2"; shift 2 ;;
    --restore)        MODE=restore; RESTORE_SNAP="$2"; shift 2 ;;
    --force)          FORCE=true;          shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

SNAPSHOTS_ROOT="${SNAPSHOTS_ROOT:-$REPO/snapshots}"

# Нормализация в абсолютный путь со снятием symlink. Каталог обязан существовать.
abspath() { ( cd "$1" && pwd -P ); }

# ISO-UTC текущего момента для meta.created.
now_utc() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

do_backup() {
  [[ -n "$TARGET" ]] || { echo "backup: нужен --target DIR" >&2; exit 2; }
  [[ -d "$TARGET" ]] || { echo "backup: target не каталог: $TARGET" >&2; exit 1; }
  local target; target="$(abspath "$TARGET")"

  # Имя снапшота — метка времени до секунды. Два бэкапа в одну секунду не должны
  # затирать друг друга, поэтому при коллизии добавляем суффикс.
  local stamp; stamp="$(date -u +"%Y-%m-%d_%H%M%S")"
  local snap="$SNAPSHOTS_ROOT/$stamp"
  local n=2
  while [[ -e "$snap" ]]; do snap="$SNAPSHOTS_ROOT/${stamp}_$n"; n=$((n + 1)); done

  # MED-6: офис с большим .git/монорепой может забить диск и дать битый частичный
  # слепок. Оцениваем размер target и свободное место на ФС снапшотов ДО cp — при
  # нехватке внятный отказ, ничего не создаём. Порог переопределяем env для тестов.
  mkdir -p "$SNAPSHOTS_ROOT"
  local need_kb avail_kb min_free
  need_kb="$(du -sk "$target" 2>/dev/null | awk '{print $1+0}')"; need_kb="${need_kb:-0}"
  avail_kb="$(df -Pk "$SNAPSHOTS_ROOT" 2>/dev/null | awk 'NR==2{print $4+0}')"
  min_free="${BACKUP_MIN_FREE_KB:-$(( need_kb + need_kb / 10 + 1 ))}"
  if [[ -n "$avail_kb" && "$avail_kb" -lt "$min_free" ]]; then
    echo "backup: недостаточно места на диске: нужно ~${min_free}KB (target ${need_kb}KB + запас), свободно ${avail_kb}KB. Слепок не снят." >&2
    exit 1
  fi

  mkdir -p "$snap/tree"

  # Грязный git — не ошибка: слепок снимаем ВСЁ РАВНО, только предупреждаем.
  # --no-optional-locks: git не рефрешит .git/index → в target не пишется ни байта.
  local git_dirty=false
  if git -C "$target" rev-parse --git-dir >/dev/null 2>&1; then
    if [[ -n "$(git -C "$target" --no-optional-locks status --porcelain 2>/dev/null)" ]]; then
      git_dirty=true
      echo "backup: git в target грязный (незакоммиченные правки) — слепок всё равно снимаю" >&2
    fi
  fi

  # cp -a содержимого target в tree/. Сокеты/fifo/спецфайлы могут вызвать ругань
  # cp — из-за них не падаем (обычные файлы уже скопированы), но реальные ошибки
  # (например, permission denied на обычном файле) наружу, не глотаем молча.
  local cp_err; cp_err="$(mktemp)"
  if ! ( cd "$target" && cp -a . "$snap/tree/" ) 2>"$cp_err"; then
    local real
    real="$(grep -vaiE 'socket|fifo|named pipe|Operation not supported|Bad file descriptor' "$cp_err" || true)"
    if [[ -n "$real" ]]; then
      echo "backup: cp завершился с ошибкой:" >&2
      echo "$real" >&2
      rm -f "$cp_err"
      exit 1
    fi
  fi
  rm -f "$cp_err"

  # HIGH-3: офис часто держит симлинки на данные ВНЕ репо (напр. карточки клиентов
  # → внешний data-каталог). cp -a сохраняет их как ссылки (40 байт) — реальные данные за
  # симлинком в слепок НЕ попадают, и откат их не вернёт. Честность: детектим
  # симлинки, резолвящиеся ЗА пределы target, громко предупреждаем и пишем список
  # в meta, чтобы консультант знал — эти данные вне слепка.
  local ext_list; ext_list="$(mktemp)"
  local L link resolved
  while IFS= read -r -d '' L; do
    link="$(readlink "$L")"
    case "$link" in
      /*) resolved="$link" ;;
      *)  resolved="$(cd "$(dirname "$L")" && pwd -P)/$link" ;;
    esac
    if [[ "$resolved" != "$target" && "$resolved" != "$target/"* ]]; then
      printf '%s\n' "${L#"$target"/}" >> "$ext_list"
    fi
  done < <(find "$target" -type l -print0 2>/dev/null)

  local ext_json='[]'
  if [[ -s "$ext_list" ]]; then
    ext_json="$(jq -R . "$ext_list" | jq -s .)"
    echo "backup: ВНИМАНИЕ — в офисе симлинки НАРУЖУ target (данные за ними НЕ в слепке, откат их не вернёт):" >&2
    sed 's/^/  - /' "$ext_list" >&2
  fi
  rm -f "$ext_list"

  jq -n --arg source "$target" --arg created "$(now_utc)" --argjson dirty "$git_dirty" \
    --argjson ext "$ext_json" \
    '{source: $source, created: $created, git_dirty: $dirty, external_symlinks: $ext}' > "$snap/meta.json"

  echo "$snap"
}

do_restore() {
  [[ -n "$RESTORE_SNAP" ]] || { echo "restore: нужен --restore SNAPDIR" >&2; exit 2; }
  [[ -n "$TARGET" ]]       || { echo "restore: нужен --target DIR" >&2; exit 2; }
  [[ -d "$TARGET" ]]       || { echo "restore: target не каталог: $TARGET" >&2; exit 1; }

  # Без tree/ восстанавливать нечего — отказ.
  [[ -d "$RESTORE_SNAP/tree" ]] || {
    echo "restore: в снапшоте нет tree/: $RESTORE_SNAP" >&2; exit 1; }

  # Защита от восстановления чужого слепка не туда: meta.source обязан совпасть
  # с целью. Снять защиту можно только явным --force.
  local target; target="$(abspath "$TARGET")"
  local source=""
  [[ -f "$RESTORE_SNAP/meta.json" ]] && source="$(jq -r '.source // ""' "$RESTORE_SNAP/meta.json" 2>/dev/null || true)"
  if [[ "$source" != "$target" && "$FORCE" != true ]]; then
    echo "restore: слепок снят с '$source', а target='$target' — не совпадает. --force чтобы разрешить." >&2
    exit 1
  fi

  # HIGH-4: restore — путь ОТКАТА после сорванной мутации, худший момент для wipe.
  # rsync --delete с ПУСТЫМ/полупустым source сотрёт весь офис клиента. meta.source
  # проверяет только КУДА, не наличие контента. Поэтому перед --delete: слепок не
  # должен быть пуст и не должен быть абсурдно меньше текущего target (защита от
  # битого/подделанного снапшота). Явный --force продавливает.
  if [[ "$FORCE" != true ]]; then
    local snap_n tgt_n
    snap_n="$(find "$RESTORE_SNAP/tree" -type f 2>/dev/null | wc -l | tr -d ' ')"
    tgt_n="$(find "$target" -type f 2>/dev/null | wc -l | tr -d ' ')"
    if [[ "$snap_n" -eq 0 ]]; then
      echo "restore: слепок пуст (tree/ без файлов) — отказ, иначе --delete сотрёт офис. --force чтобы продавить." >&2
      exit 1
    fi
    if [[ "$tgt_n" -gt 0 && $(( snap_n * 2 )) -lt "$tgt_n" ]]; then
      echo "restore: в слепке $snap_n файлов против $tgt_n в target — подозрительно мало (порча слепка?). --force чтобы продавить." >&2
      exit 1
    fi
  fi

  # rsync -a --delete: возвращает изменённое, восстанавливает незакоммиченное и
  # удаляет всё, что появилось в target после слепка.
  rsync -a --delete "$RESTORE_SNAP/tree/" "$target/"
}

case "$MODE" in
  backup)  do_backup ;;
  restore) do_restore ;;
esac
