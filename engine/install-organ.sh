#!/usr/bin/env bash
# install-organ.sh — установка и verify «органа» (skill-pack) в чужой ~/.claude.
#
# Пишет ТОЛЬКО в --claude-dir. Никогда не трогает офис клиента (target). Не читает
# .env/credentials/secrets — копирует лишь подкаталог installs_to из source-пака.
#
#   install-organ.sh --organ MANIFEST --claude-dir DIR [--source DIR]   # установка + verify
#   install-organ.sh --verify-only --organ MANIFEST --claude-dir DIR    # только verify
#
# Выход — JSON в stdout: {organ_id, installed, backup, verify{...}, manual_steps[...]}.
# Прогресс/ошибки — в stderr. Exit 0 если орган установлен (files_ok && frontmatter_ok), иначе 1.
set -euo pipefail

MODE="install"          # install | verify
MANIFEST=""
CLAUDE_DIR=""
SOURCE_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --organ)       MANIFEST="$2";        shift 2 ;;
    --claude-dir)  CLAUDE_DIR="$2";      shift 2 ;;
    --source)      SOURCE_OVERRIDE="$2"; shift 2 ;;
    --verify-only) MODE="verify";        shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$MANIFEST" && -f "$MANIFEST" ]] || { echo "no manifest: $MANIFEST" >&2; exit 2; }
[[ -n "$CLAUDE_DIR" ]] || { echo "--claude-dir required" >&2; exit 2; }

ORGAN_ID="$(jq -r '.organ_id' "$MANIFEST")"
INSTALLS_TO="$(jq -r '.installs_to' "$MANIFEST")"

# Ошибка безопасности: внятное сообщение в stderr + JSON {installed:false} в stdout, exit 1.
reject() {
  echo "install-organ: $1" >&2
  jq -n --arg id "$ORGAN_ID" --arg err "$1" '{organ_id:$id, installed:false, error:$err}'
  exit 1
}

# --- Гейт пути: installs_to обязан быть относительным и СТРОГО под --claude-dir. ---
# Абсолютный путь или сегмент '..' уводит DEST наружу → перезапись чужих файлов (CRIT).
case "$INSTALLS_TO" in
  ""|null) reject "installs_to missing in manifest" ;;
  /*)      reject "installs_to must be relative, not absolute: '$INSTALLS_TO'" ;;
esac
if printf '%s' "$INSTALLS_TO" | grep -qE '(^|/)\.\.(/|$)'; then
  reject "installs_to must not contain '..' segments: '$INSTALLS_TO'"
fi

# Резолвим абсолютный claude-dir и строим DEST от него — ниже проверяем, что не сбежали.
CLAUDE_ABS="$(cd "$CLAUDE_DIR" && pwd -P)" || reject "cannot resolve --claude-dir: '$CLAUDE_DIR'"
DEST="$CLAUDE_ABS/$INSTALLS_TO"
PLUGINS_JSON="$CLAUDE_ABS/plugins/installed_plugins.json"

# Элементы (в т.ч. с пробелами — install_hint) → корректный JSON-массив. Пусто → [].
json_arr() {
  if [[ $# -eq 0 ]]; then printf '[]'; else printf '%s\n' "$@" | jq -R . | jq -s .; fi
}

# --- Установка: разрешить источник, забэкапить старое, скопировать installs_to ---
backup="null"
if [[ "$MODE" == "install" ]]; then
  if [[ -n "$SOURCE_OVERRIDE" ]]; then
    SRC="$SOURCE_OVERRIDE"
  else
    local_src="$(jq -r '.source.local // ""' "$MANIFEST")"
    # Раскрываем ведущий '~' вручную — jq отдаёт литерал, шелл его не трогает.
    case "$local_src" in
      "~")   local_src="$HOME" ;;
      "~/"*) local_src="$HOME/${local_src#\~/}" ;;
    esac
    if [[ -n "$local_src" && -d "$local_src" ]]; then
      SRC="$local_src"
    else
      git_src="$(jq -r '.source.git // ""' "$MANIFEST")"
      [[ -n "$git_src" ]] || reject "no source: neither --source, local, nor git"
      # Гейт транспорта git: манифест — вход под контролем атакующего. Только https:// и
      # scp-подобный ssh (user@host:path). ext::/file://, ведущий '-', transport-helper
      # ('scheme::') = произвольное выполнение кода при clone → отказ, без clone (CRIT).
      case "$git_src" in
        -*)                       reject "git source must not start with '-': '$git_src'" ;;
        ext::*|file://*|git://*)  reject "refusing unsafe git transport: '$git_src'" ;;
      esac
      case "$git_src" in
        https://*) : ;;
        *::*)      reject "refusing git transport-helper syntax: '$git_src'" ;;
        *@*:*)     : ;;   # scp-подобный ssh: user@host:path
        *)         reject "git source must be https:// or scp-like ssh (user@host:path): '$git_src'" ;;
      esac
      SRC="$(mktemp -d)"
      git clone --depth 1 -- "$git_src" "$SRC" >/dev/null 2>&1 || reject "git clone failed: '$git_src'"
    fi
  fi
  SRC_DIR="$SRC/$INSTALLS_TO"
  [[ -d "$SRC_DIR" ]] || reject "source has no $INSTALLS_TO: $SRC_DIR"

  mkdir -p "$(dirname "$DEST")"
  # Финальная страховка: резолвим фактического родителя DEST (ловит symlink-побег внутри
  # claude-dir) и требуем, чтобы он остался под claude-dir — до любой записи.
  dest_parent="$(cd "$(dirname "$DEST")" && pwd -P)" || reject "cannot resolve install dir for '$DEST'"
  case "$dest_parent/" in
    "$CLAUDE_ABS"/*) : ;;
    *) reject "resolved install path escapes --claude-dir: '$dest_parent'" ;;
  esac

  # Существующее не перезаписываем молча — прячем в forge.bak-<ts>-<pid> рядом (откат клиента).
  if [[ -e "$DEST" ]]; then
    backup="$DEST.bak-$(date -u +%Y%m%d-%H%M%S)-$$"
    mv -- "$DEST" "$backup"
  fi
  cp -R -- "$SRC_DIR" "$DEST"
  echo "орган '$ORGAN_ID' скопирован в $DEST" >&2
fi

# --- Verify (ветка skill-pack) ---
# 1) все required_files существуют и непусты
missing_files=()
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  [[ -s "$DEST/$f" ]] || missing_files+=("$f")
done < <(jq -r '.required_files[]' "$MANIFEST")
if [[ ${#missing_files[@]} -eq 0 ]]; then files_ok=true; else files_ok=false; fi

# 2) frontmatter SKILL.md содержит name:
if [[ -s "$DEST/SKILL.md" ]] && grep -q '^name:' "$DEST/SKILL.md"; then
  frontmatter_ok=true
else
  frontmatter_ok=false
fi

# 3) каждый required_plugins.grep есть в installed_plugins.json; нет файла → все missing.
#    Missing плагины — НЕ фейл установки: файлы стоят, человек доставит плагины сам.
missing_hints=()
while IFS= read -r row; do
  [[ -n "$row" ]] || continue
  g="$(jq -r '.grep' <<< "$row")"
  hint="$(jq -r '.install_hint' <<< "$row")"
  if [[ -f "$PLUGINS_JSON" ]] && grep -qF -- "$g" "$PLUGINS_JSON"; then
    :
  else
    missing_hints+=("$hint")
  fi
done < <(jq -c '.required_plugins[]' "$MANIFEST")
if [[ ${#missing_hints[@]} -eq 0 ]]; then plugins_ok=true; else plugins_ok=false; fi

# Орган установлен, если файлы на месте и frontmatter валиден (плагины — вне этого критерия).
if [[ "$files_ok" == true && "$frontmatter_ok" == true ]]; then installed=true; else installed=false; fi

# bash 3.2: "${arr[@]}" на пустом массиве под set -u падает — гвардим через ${arr[@]+...}.
missing_files_json="$(json_arr ${missing_files[@]+"${missing_files[@]}"})"
manual_steps_json="$(json_arr ${missing_hints[@]+"${missing_hints[@]}"})"

verify_json="$(jq -n \
  --argjson files_ok "$files_ok" \
  --argjson frontmatter_ok "$frontmatter_ok" \
  --argjson plugins_ok "$plugins_ok" \
  --argjson missing_files "$missing_files_json" \
  '{files_ok:$files_ok, frontmatter_ok:$frontmatter_ok, plugins_ok:$plugins_ok, missing_files:$missing_files}')"

jq -n \
  --arg organ_id "$ORGAN_ID" \
  --argjson installed "$installed" \
  --arg backup "$backup" \
  --argjson verify "$verify_json" \
  --argjson manual_steps "$manual_steps_json" \
  '{organ_id:$organ_id, installed:$installed,
    backup: (if $backup == "null" then null else $backup end),
    verify:$verify, manual_steps:$manual_steps}'

[[ "$installed" == true ]] && exit 0 || exit 1
