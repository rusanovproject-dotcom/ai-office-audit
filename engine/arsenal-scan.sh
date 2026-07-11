#!/usr/bin/env bash
# arsenal-scan.sh — инвентарь «арсенала» чужого AI-офиса: какие скиллы, агенты,
# команды и хуки у человека уже есть. Пара к fit-scan.sh: тот снимает, ЧТО он
# делал руками; этот — ЧЕМ он мог бы это делать. Маппинг одного на другое —
# работа LLM в скилле /audit-fit.
#
# READ-ONLY. Ни байта в чужой офис. НИКОГДА не читает .env*, credentials*, secrets*
# — движок открывает только SKILL.md / core.md / агентские .md, прочие файлы лишь
# перечисляет по имени.
#
#   arsenal-scan.sh --target <dir> [--claude-dir <dir>]
#
# --target     — корень чужого офиса (его .claude/ и office/).
# --claude-dir — опционально, его пользовательский ~/.claude (скиллы вне репо).
#                По умолчанию не сканируется.
#
# Выход — JSON в stdout.
set -euo pipefail

TARGET=""
CLAUDE_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)     TARGET="$2";     shift 2 ;;
    --claude-dir) CLAUDE_DIR="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$TARGET" ]] || { echo "usage: arsenal-scan.sh --target <dir> [--claude-dir <dir>]" >&2; exit 2; }
[[ -d "$TARGET" ]] || { echo "no target dir: $TARGET" >&2; exit 1; }

DESC_MAX=300   # длинные простыни описаний не должны раздувать отчёт
HINT_MAX=200

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
: > "$SCRATCH/skills"
: > "$SCRATCH/agents"
: > "$SCRATCH/commands"
: > "$SCRATCH/hooks"

# Тело frontmatter: строки между первым `---` и следующим `---`.
# Нет открывающего или нет закрывающего `---` → пусто (битый frontmatter не роняет).
extract_frontmatter() {
  awk '
    NR==1 { sub(/\r$/,""); if ($0 != "---") exit; infm=1; next }
    { sub(/\r$/,"") }
    infm && $0=="---" { exit }
    infm { print }
  ' "$1"
}

# Значение YAML-ключа из frontmatter (stdin). Понимает и однострочный `key: v`,
# и свёрнутый блок `key: >-` с отступами. Останавливает блок на первом ключе
# без отступа — чтобы соседний ключ (allowed-tools) не протёк в значение.
fm_field() {
  awk -v key="$1" '
    function flush() { if (found && !printed) { print val; printed=1 } }
    {
      sub(/\r$/,"")
      if (!found && $0 ~ "^"key"[ \t]*:") {
        found=1; line=$0
        sub("^"key"[ \t]*:[ \t]*","",line)
        tmp=line; gsub(/[ \t]+$/,"",tmp)
        if (tmp=="" || tmp ~ /^[>|][+-]?[0-9]*$/) { block=1; val="" }
        else { val=tmp; flush(); done=1 }
        next
      }
      if (found && block && !done) {
        if ($0 ~ /^[ \t]/) {
          s=$0; gsub(/^[ \t]+/,"",s); gsub(/[ \t]+$/,"",s)
          val=(val==""?s:val" "s); next
        } else { flush(); done=1; next }
      }
    }
    END { flush() }
  '
}

# Однострочно + обрезка. Любые остаточные переводы строк схлопываем в пробел.
oneline_cut() {
  local max="$1"
  tr '\n' ' ' | sed 's/  */ /g; s/^ //; s/ $//' | cut -c1-"$max"
}

# Первая непустая строка после заголовка (пропускаем frontmatter и `#`-заголовки).
role_hint() {
  awk '
    NR==1 { sub(/\r$/,""); if ($0=="---") { infm=1; next } }
    { sub(/\r$/,"") }
    infm && $0=="---" { infm=0; next }
    infm { next }
    /^[ \t]*#/ { next }
    /^[ \t]*$/ { next }
    { line=$0; gsub(/^[ \t]+/,"",line); gsub(/[ \t]+$/,"",line); print line; exit }
  ' "$1"
}

emit_skills() {
  local skills_dir="$1" source="$2"
  [[ -d "$skills_dir" ]] || return 0
  shopt -s nullglob
  local f folder fm name desc
  for f in "$skills_dir"/*/SKILL.md; do
    folder="$(basename "$(dirname "$f")")"
    fm="$(extract_frontmatter "$f")"
    name="$(printf '%s' "$fm" | fm_field name | oneline_cut 200)"
    [[ -n "$name" ]] || name="$folder"
    desc="$(printf '%s' "$fm" | fm_field description | oneline_cut "$DESC_MAX")"
    jq -nc --arg n "$name" --arg d "$desc" --arg p "$f" --arg s "$source" \
      '{name:$n, description:$d, path:$p, source:$s}' >> "$SCRATCH/skills"
  done
  shopt -u nullglob
}

emit_agents() {
  shopt -s nullglob
  local f name hint
  # Layout A: office/agents/<name>/core.md
  for f in "$TARGET"/office/agents/*/core.md; do
    name="$(basename "$(dirname "$f")")"
    hint="$(role_hint "$f" | oneline_cut "$HINT_MAX")"
    jq -nc --arg n "$name" --arg h "$hint" --arg p "$f" \
      '{name:$n, role_hint:$h, path:$p}' >> "$SCRATCH/agents"
  done
  # Layout B: .claude/agents/<name>.md
  for f in "$TARGET"/.claude/agents/*.md; do
    name="$(basename "$f" .md)"
    hint="$(role_hint "$f" | oneline_cut "$HINT_MAX")"
    jq -nc --arg n "$name" --arg h "$hint" --arg p "$f" \
      '{name:$n, role_hint:$h, path:$p}' >> "$SCRATCH/agents"
  done
  shopt -u nullglob
}

emit_hooks() {
  shopt -s nullglob
  local f
  for f in "$TARGET"/.claude/hooks/*.sh; do
    basename "$f" >> "$SCRATCH/hooks"
  done
  shopt -u nullglob
}

emit_commands() {
  local cdir="$TARGET/.claude/commands"
  [[ -d "$cdir" ]] || return 0
  # Рекурсивно; сортируем ради идемпотентности (find не гарантирует порядок).
  find "$cdir" -type f -name '*.md' 2>/dev/null | sort | while IFS= read -r f; do
    basename "$f" .md
  done > "$SCRATCH/commands"
}

emit_skills "$TARGET/.claude/skills" "project"
[[ -n "$CLAUDE_DIR" ]] && emit_skills "$CLAUDE_DIR/skills" "user"
emit_agents
emit_hooks
emit_commands

# Сборка. jq -s над пустым файлом даёт [] — пустой офис отдаёт валидный JSON.
jq -nc \
  --slurpfile skills <(cat "$SCRATCH/skills") \
  --slurpfile agents <(cat "$SCRATCH/agents") \
  --rawfile hooks_raw "$SCRATCH/hooks" \
  --rawfile cmds_raw "$SCRATCH/commands" '
  ($hooks_raw | split("\n") | map(select(length>0))) as $hooks
  | ($cmds_raw | split("\n") | map(select(length>0))) as $commands
  | {
      skills: $skills,
      agents: $agents,
      commands: $commands,
      hooks: $hooks,
      skills_total: ($skills | length),
      agents_total: ($agents | length)
    }
'
