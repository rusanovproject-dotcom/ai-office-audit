#!/bin/bash
# validate-office.sh — Полный health-check ВСЕГО офиса (AGENTS.md + context.md + все агенты).
# 20 проверок в 4 категориях. Запускать ПОСЛЕ wiring-фазы (TEAM-режим).
# Для одного агента детально: validate-agent.sh
# Для общего health-check директории: validate.sh
# Usage: bash validate-office.sh [/path/to/office]
# Exit: 0 if no BLOCKERs, 1 if BLOCKERs found

set -uo pipefail

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# --- Target directory ---
TARGET="${1:-.}"
TARGET=$(cd "$TARGET" 2>/dev/null && pwd) || { echo "Error: directory '$1' not found"; exit 1; }

# --- Counters ---
PASS=0
WARN=0
ERROR=0
BLOCKER=0

# --- Collected issues ---
BLOCKER_LIST=""
ERROR_LIST=""
WARN_LIST=""

# --- Helpers ---
pass() {
  echo -e "  ${GREEN}PASS${NC}  $1"
  ((PASS++))
}

warn() {
  echo -e "  ${YELLOW}WARN${NC}  $1"
  ((WARN++))
  WARN_LIST="${WARN_LIST}\n  - $1"
}

error() {
  echo -e "  ${RED}ERROR${NC} $1"
  ((ERROR++))
  ERROR_LIST="${ERROR_LIST}\n  - $1"
}

blocker() {
  echo -e "  ${RED}${BOLD}FAIL${NC}  $1"
  ((BLOCKER++))
  BLOCKER_LIST="${BLOCKER_LIST}\n  - $1"
}

# --- Header ---
echo -e "${BOLD}=== AI Office Health Check ===${NC}"
echo "Target: $TARGET"
echo "Date: $(date +%Y-%m-%d)"
echo ""

# ============================================================
# A. STRUCTURE (5 checks)
# ============================================================
echo -e "${CYAN}[A. Structure]${NC}"

# A1: Root CLAUDE.md exists (BLOCKER)
if [ -f "$TARGET/CLAUDE.md" ]; then
  pass "A1: Root CLAUDE.md exists"
else
  blocker "A1: Root CLAUDE.md is MISSING"
fi

# A2: AGENTS.md exists (BLOCKER for small+) — поддержка office/ layout клиентского шаблона
if [ -f "$TARGET/AGENTS.md" ] || [ -f "$TARGET/office/AGENTS.md" ]; then
  pass "A2: AGENTS.md exists"
else
  # Check if there are agents/ dir — if yes, it's small+ and AGENTS.md is required
  if [ -d "$TARGET/agents" ] || [ -d "$TARGET/.claude/agents" ] || [ -d "$TARGET/office/agents" ]; then
    blocker "A2: AGENTS.md is MISSING (agents/ directory exists — small+ pattern requires it)"
  else
    pass "A2: AGENTS.md not needed (solo pattern)"
  fi
fi

# A3: context.md exists and <= 50 lines (WARNING)
CONTEXT_FILE=""
for candidate in "$TARGET/context.md" "$TARGET/ops/context.md"; do
  [ -f "$candidate" ] && CONTEXT_FILE="$candidate" && break
done

if [ -n "$CONTEXT_FILE" ]; then
  ctx_lines=$(wc -l < "$CONTEXT_FILE" | tr -d ' ')
  if [ "$ctx_lines" -le 50 ]; then
    pass "A3: context.md exists ($ctx_lines lines)"
  else
    warn "A3: context.md is $ctx_lines lines (limit: 50)"
  fi
else
  warn "A3: context.md not found"
fi

# A4: knowledge/INDEX.md exists (WARNING)
if [ -d "$TARGET/knowledge" ]; then
  if [ -f "$TARGET/knowledge/INDEX.md" ]; then
    pass "A4: knowledge/INDEX.md exists"
  else
    warn "A4: knowledge/ exists but INDEX.md is missing"
  fi
else
  warn "A4: knowledge/ directory not found"
fi

# A5: Directory nesting <= 3 levels (WARNING)
max_depth=0
while IFS= read -r dir; do
  # Сам TARGET find тоже выдаёт — префикс не срезается (нет хвостового «/»),
  # и depth считался бы от корня ФС. Пропускаем.
  [ "$dir" = "$TARGET" ] && continue
  rel="${dir#$TARGET/}"
  depth=$(echo "$rel" | awk -F'/' '{print NF}')
  [ "$depth" -gt "$max_depth" ] && max_depth=$depth
done < <(find "$TARGET" -type d -not -path '*/.git/*' -not -path '*/.git' -not -path '*/node_modules/*' -not -path '*/.claude/*' 2>/dev/null)

if [ "$max_depth" -le 3 ]; then
  pass "A5: Max nesting depth is $max_depth (limit: 3)"
else
  warn "A5: Max nesting depth is $max_depth (limit: 3)"
fi

echo ""

# ============================================================
# B. AGENTS (5 checks)
# ============================================================
echo -e "${CYAN}[B. Agents]${NC}"

# Parse AGENTS.md to find agent file references
AGENTS_FILE=""
for candidate in "$TARGET/AGENTS.md" "$TARGET/office/AGENTS.md"; do
  [ -f "$candidate" ] && AGENTS_FILE="$candidate" && break
done
AGENTS_DIR=""
for candidate in "$TARGET/agents" "$TARGET/.claude/agents" "$TARGET/office/agents"; do
  [ -d "$candidate" ] && AGENTS_DIR="$candidate" && break
done

# Collect agents listed in AGENTS.md (look for file paths like agents/xxx.md or .claude/agents/xxx.md)
declare -a LISTED_AGENTS=()
if [ -f "$AGENTS_FILE" ]; then
  while IFS= read -r agent_path; do
    # Clean up: remove backticks, brackets, leading/trailing spaces
    clean=$(echo "$agent_path" | sed 's/`//g; s/\[//g; s/\]//g; s/(//g; s/)//g' | xargs)
    [ -n "$clean" ] && LISTED_AGENTS+=("$clean")
  done < <(grep -oE '(\.claude/agents|agents)/[a-zA-Z0-9_-]+\.(md|yml)|(office/|\.claude/)?agents/[a-zA-Z0-9_-]+/(core|CLAUDE)\.md' "$AGENTS_FILE" 2>/dev/null | sort -u)
fi

# B1: Every agent in AGENTS.md has a file (BLOCKER)
b1_ok=true
if [ -f "$AGENTS_FILE" ] && [ ${#LISTED_AGENTS[@]} -gt 0 ]; then
  for agent_ref in "${LISTED_AGENTS[@]}"; do
    if [ ! -f "$TARGET/$agent_ref" ]; then
      blocker "B1: Agent \"$(basename "$agent_ref" .md)\" in AGENTS.md but file missing: $agent_ref"
      b1_ok=false
    fi
  done
  $b1_ok && pass "B1: All agents in AGENTS.md have files"
elif [ -f "$AGENTS_FILE" ]; then
  # AGENTS.md exists but no agent paths found — try to parse agent names from table rows
  has_agents=false
  while IFS= read -r line; do
    # Look for table rows with agent names
    name=$(echo "$line" | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2}' 2>/dev/null)
    [ -z "$name" ] && continue
    [[ "$name" == "---"* ]] && continue
    [[ "$name" == "Агент"* ]] && continue
    [[ "$name" == "Agent"* ]] && continue
    [[ "$name" == "#"* ]] && continue
    has_agents=true
  done < <(grep '|' "$AGENTS_FILE" 2>/dev/null)
  if $has_agents; then
    pass "B1: AGENTS.md found (no direct file paths to validate)"
  else
    pass "B1: AGENTS.md found (no agents listed)"
  fi
else
  pass "B1: No AGENTS.md — skipped"
fi

# B2: No orphan files in agents/ without entry in AGENTS.md (ERROR)
if [ -n "$AGENTS_DIR" ] && [ -f "$AGENTS_FILE" ]; then
  b2_ok=true
  # Поддержка ДВУХ layout'ов: flat (agents/<name>.md) и folder-per-agent
  # (agents/<name>/core.md|CLAUDE.md). Для файлов глубины 2 сверяем по имени
  # ПАПКИ агента (как F1), иначе grep «core.md» давал бы ложный PASS у всех.
  while IFS= read -r agent_file; do
    rel="${agent_file#$AGENTS_DIR/}"
    case "$rel" in
      */*)
        # folder-per-agent: только core.md/CLAUDE.md — вход агента
        case "$rel" in */core.md|*/CLAUDE.md) ;; *) continue ;; esac
        aname="${rel%%/*}"
        case "$aname" in _*) continue ;; esac  # _templates и т.п. — служебные
        # один вход на папку: есть core.md → CLAUDE.md пропускаем (дубль)
        [[ "$rel" == */CLAUDE.md && -f "$AGENTS_DIR/$aname/core.md" ]] && continue
        if ! grep -qi "$aname" "$AGENTS_FILE" 2>/dev/null; then
          error "B2: Orphan agent file: $agent_file (agent '$aname' not in AGENTS.md)"
          b2_ok=false
        fi
        ;;
      *)
        # flat: сверяем по basename (как раньше — поведение не меняется)
        basename_file="$rel"
        [[ "$basename_file" == "INDEX.md" ]] && continue
        [[ "$basename_file" == "README.md" ]] && continue
        if ! grep -q "$basename_file" "$AGENTS_FILE" 2>/dev/null; then
          error "B2: Orphan agent file: $agent_file (not in AGENTS.md)"
          b2_ok=false
        fi
        ;;
    esac
  done < <(find "$AGENTS_DIR" -maxdepth 2 \( -name "*.md" -o -name "*.yml" \) 2>/dev/null)
  $b2_ok && pass "B2: No orphan agent files"
elif [ -n "$AGENTS_DIR" ]; then
  warn "B2: agents/ exists but no AGENTS.md to cross-check"
else
  pass "B2: No agents/ directory — skipped"
fi

# B3: Each agent has "НЕ отвечает" or "НЕ делает" section (WARNING)
if [ -n "$AGENTS_DIR" ]; then
  b3_ok=true
  # Оба layout'а: flat (agents/<name>.md) читаем сам файл; folder-per-agent
  # (agents/<name>/core.md) читаем core.md, а имя агента = папка (не «core»).
  while IFS= read -r agent_file; do
    rel="${agent_file#$AGENTS_DIR/}"
    case "$rel" in
      */*)
        case "$rel" in */core.md|*/CLAUDE.md) ;; *) continue ;; esac
        aname="${rel%%/*}"
        case "$aname" in _*) continue ;; esac
        [[ "$rel" == */CLAUDE.md && -f "$AGENTS_DIR/$aname/core.md" ]] && continue
        report_name="$aname"
        ;;
      *)
        basename_file="$rel"
        [[ "$basename_file" == "INDEX.md" ]] && continue
        [[ "$basename_file" == "README.md" ]] && continue
        report_name="${basename_file%.md}"
        ;;
    esac
    if ! grep -qiE '(НЕ отвечает|НЕ делает|не делает|не отвечает|NOT responsible|does NOT)' "$agent_file" 2>/dev/null; then
      warn "B3: Agent $report_name has no \"NOT responsible\" / \"НЕ делает\" section"
      b3_ok=false
    fi
  done < <(find "$AGENTS_DIR" -maxdepth 2 \( -name "*.md" -o -name "*.yml" \) 2>/dev/null)
  $b3_ok && pass "B3: All agents have boundary sections"
else
  pass "B3: No agents/ directory — skipped"
fi

# B4: Agent CLAUDE.md files <= 200 lines (WARNING)
b4_ok=true
while IFS= read -r claude_file; do
  # Skip root CLAUDE.md — this checks agent-level ones
  [[ "$claude_file" == "$TARGET/CLAUDE.md" ]] && continue
  lines=$(wc -l < "$claude_file" | tr -d ' ')
  if [ "$lines" -gt 200 ]; then
    warn "B4: $claude_file is $lines lines (limit: 200)"
    b4_ok=false
  fi
done < <(find "$TARGET" -name "CLAUDE.md" -not -path '*/.git/*' -not -path '*/node_modules/*' 2>/dev/null)
$b4_ok && pass "B4: All CLAUDE.md files <= 200 lines"

# B5: No empty CLAUDE.md files (ERROR)
b5_ok=true
while IFS= read -r claude_file; do
  lines=$(wc -l < "$claude_file" | tr -d ' ')
  if [ "$lines" -lt 3 ]; then
    error "B5: Empty CLAUDE.md: $claude_file ($lines lines)"
    b5_ok=false
  fi
done < <(find "$TARGET" -name "CLAUDE.md" -not -path '*/.git/*' -not -path '*/node_modules/*' 2>/dev/null)
$b5_ok && pass "B5: No empty CLAUDE.md files"

echo ""

# ============================================================
# C. CONNECTIONS & ROUTING (5 checks)
# ============================================================
echo -e "${CYAN}[C. Connections & Routing]${NC}"

ROOT_CLAUDE="$TARGET/CLAUDE.md"

# C1: Root CLAUDE.md has a routing table (BLOCKER)
if [ -f "$ROOT_CLAUDE" ]; then
  if grep -qE '\|.*\|.*\|' "$ROOT_CLAUDE" 2>/dev/null && grep -qiE '(роутинг|routing|задач|тип|agent|агент)' "$ROOT_CLAUDE" 2>/dev/null; then
    pass "C1: Root CLAUDE.md has a routing table"
  else
    blocker "C1: Root CLAUDE.md has no routing table"
  fi
else
  blocker "C1: Root CLAUDE.md missing — cannot check routing"
fi

# C2: All file references in .md files are valid — NO whitelist, check ALL paths (ERROR)
c2_ok=true
c2_checked=0
# Битая ссылка = ERROR только в НЕСУЩИХ файлах (корень, office/*.md, core.md агентов,
# SKILL.md ядра — то, что исполняется). В knowledge/, examples/, доках паков ссылки
# часто иллюстративные («projects/<имя>/…» из туториала) — там WARN, не красный.
c2_report() {
  local mdfile="$1" lineno="$2" link="$3" rel core=0
  rel="${mdfile#$TARGET/}"
  # Несущие: корень, верхний уровень office/, core.md агентов, SKILL.md скиллов.
  # (bash case-глоб * жрёт слэши — режем «глубокие» пути отдельными ветками ПЕРВЫМИ)
  case "$rel" in
    office/agents/*/core.md) core=1 ;;
    .claude/skills/*/SKILL.md) core=1 ;;
    office/*/*) core=0 ;;      # глубже одного уровня (knowledge, protocols, soul…)
    .claude/*) core=0 ;;
    CLAUDE.md|office/*.md) core=1 ;;
  esac
  if [ "$core" = 1 ]; then
    error "C2: Broken link in $rel:$lineno -> $link"; c2_ok=false
  else
    warn "C2: Broken link in $rel:$lineno -> $link"
  fi
}

# Резолв ссылки: от корня офиса → от папки файла → абсолютно → от office/ →
# от КОРНЯ АГЕНТА (доки внутри office/agents/<name>/ и _agent-packs/<name>/
# ссылаются относительно своего агента: knowledge/…, skills/… — это легально).
link_resolves() {
  local link="$1" mdfile="$2" d rel aname aroot
  # Плейсхолдер-паттерны («week-N.md», «module-N/…») — примеры, не ссылки
  case "$link" in *-N.md|*-N+1.md|*-N/*|*/N.md) return 0 ;; esac
  # Творимые зоны: файлы, которые СОЗДАЮТСЯ работой (проект пользователя, стратегия,
  # логи недель) — в шаблоне их нет по построению, ссылка на них легальна.
  case "$link" in
    brand/*|product/*|products/*|funnel/*|audience/*|financial/*|customers/*|weekly-logs/*|sessions/*) return 0 ;;
    office/strategy/session-plan.md|inbox/_questions.md|metrics.md|hypotheses.md|learnings.md) return 0 ;;
  esac
  { [ -f "$TARGET/$link" ] || [ -d "$TARGET/$link" ]; } && return 0
  d="$(dirname "$mdfile")"
  { [ -f "$d/$link" ] || [ -d "$d/$link" ]; } && return 0
  { [ -f "$link" ] || [ -d "$link" ]; } && return 0
  { [ -f "$TARGET/office/$link" ] || [ -d "$TARGET/office/$link" ]; } && return 0
  { [ -f "$TARGET/office/agents/$link" ] || [ -d "$TARGET/office/agents/$link" ]; } && return 0
  { [ -f "$TARGET/.claude/skills/$link" ] || [ -d "$TARGET/.claude/skills/$link" ]; } && return 0
  # build-скилл ядра — копия демиургового: его knowledge/-ссылки живут у Демиурга
  { [ -f "$TARGET/office/agents/demiurg/$link" ] || [ -d "$TARGET/office/agents/demiurg/$link" ]; } && return 0
  rel="${mdfile#$TARGET/}"
  case "$rel" in
    office/agents/*/*)
      aname="${rel#office/agents/}"; aname="${aname%%/*}"
      aroot="$TARGET/office/agents/$aname"
      { [ -f "$aroot/$link" ] || [ -d "$aroot/$link" ]; } && return 0 ;;
  esac
  case "$rel" in
    _agent-packs/*/*)
      aname="${rel#_agent-packs/}"; aname="${aname%%/*}"
      aroot="$TARGET/_agent-packs/$aname"
      { [ -f "$aroot/$link" ] || [ -d "$aroot/$link" ]; } && return 0 ;;
  esac
  return 1
}

while IFS= read -r mdfile; do
    # Extract backtick-quoted file refs `…ext` — one awk pass per file (lineno = FNR),
    # instead of echo|grep|sed per line. Skip rules + resolution below unchanged.
    while IFS=$'\t' read -r lineno link; do
      [ -z "$link" ] && continue
      # Skip URLs
      [[ "$link" == http* ]] && continue
      # Skip variables/templates/globs
      [[ "$link" == *'$'* ]] && continue
      [[ "$link" == *'<'* ]] && continue
      [[ "$link" == *'{'* ]] && continue
      [[ "$link" == *'*'* ]] && continue
      [[ "$link" == *'['* ]] && continue
      [[ "$link" == *'~'* ]] && continue
      # Skip example/template paths
      [[ "$link" == path/* ]] && continue
      [[ "$link" == */X.md ]] && continue
      # Skip command-like references
      [[ "$link" == bash* ]] && continue
      [[ "$link" == npm* ]] && continue
      [[ "$link" == git* ]] && continue
      [[ "$link" == ssh* ]] && continue
      [[ "$link" == cd\ * ]] && continue
      [[ "$link" == cat\ * ]] && continue
      [[ "$link" == grep* ]] && continue
      [[ "$link" == head\ * ]] && continue
      [[ "$link" == ls\ * ]] && continue
      [[ "$link" == GET\ * ]] && continue
      # Must contain at least one slash (path, not just a filename in text)
      [[ "$link" == *"/"* ]] || continue

      ((c2_checked++))

      if ! link_resolves "$link" "$mdfile"; then
        c2_report "$mdfile" "$lineno" "$link"
      fi
    done < <(awk '{ s = $0; while (match(s, /`[^`]+\.(md|sh|yml|yaml|json)`/)) { print FNR "\t" substr(s, RSTART + 1, RLENGTH - 2); s = substr(s, RSTART + RLENGTH) } }' "$mdfile" 2>/dev/null)

    # Also check markdown link syntax [text](path) — one awk pass per file.
    while IFS=$'\t' read -r lineno link; do
      [ -z "$link" ] && continue
      [[ "$link" == http* ]] && continue
      [[ "$link" == *'$'* ]] && continue
      [[ "$link" == *'<'* ]] && continue
      [[ "$link" == *'{'* ]] && continue
      [[ "$link" == *'*'* ]] && continue
      [[ "$link" == *'['* ]] && continue
      [[ "$link" == *'~'* ]] && continue
      [[ "$link" == path/* ]] && continue
      [[ "$link" == */X.md ]] && continue
      [[ "$link" == *"/"* ]] || continue
      [[ "$link" == "#"* ]] && continue

      ((c2_checked++))

      if ! link_resolves "$link" "$mdfile"; then
        c2_report "$mdfile" "$lineno" "$link"
      fi
    done < <(awk '{ s = $0; while (match(s, /\]\([^)]+\)/)) { tok = substr(s, RSTART + 2, RLENGTH - 3); if (tok ~ /\.(md|sh|yml|yaml|json)$/) print FNR "\t" tok; s = substr(s, RSTART + RLENGTH) } }' "$mdfile" 2>/dev/null)

done < <(find "$TARGET" -name "*.md" -not -path '*/.git/*' -not -path '*/node_modules/*' -not -path '*/archive/*' -not -path '*/ai-offices/*' -not -path '*/_archive/*' 2>/dev/null)
$c2_ok && pass "C2: All file references valid ($c2_checked checked)"

# C3: No duplicate content blocks (>5 identical consecutive lines across files) (WARNING)
c3_ok=true
dup_tmp=$(mktemp)
# Single awk pass over all .md files: emit "<file:startline>US<l1>US…US<l5>" for each
# non-overlapping full 5-line window whose normalized content (sans whitespace/|/#/-) > 20 chars.
# Field sep = US (\x1f): location first, then the 5 raw lines. US (not TAB) is used so a literal
# TAB inside a content line can't corrupt parsing — keeps the dedup key faithful to the raw block
# (как старый md5). Replaces the old per-window sed+md5 loop (~3 subprocesses × thousands of windows).
find "$TARGET" -name "*.md" -not -path '*/.git/*' -not -path '*/node_modules/*' -not -path '*/archive/*' -not -path '*/ai-offices/*' -not -path '*/_archive/*' -print0 2>/dev/null \
  | xargs -0 awk '
      BEGIN { US = sprintf("%c", 31) }
      function emit(   i, line, norm) {
        norm = b[1] b[2] b[3] b[4] b[5]; gsub(/[[:space:]|#-]/, "", norm)
        if (length(norm) <= 20) return
        line = FILENAME ":" start
        for (i = 1; i <= 5; i++) line = line US b[i]
        print line
      }
      FNR == 1 { n = 0 }
      { if (n == 0) start = FNR; b[++n] = $0; if (n == 5) { emit(); n = 0 } }
    ' 2>/dev/null | sort -t"$(printf '\037')" -k2 > "$dup_tmp"

# Sorted by body (fields 2+), identical bodies are adjacent. First adjacent pair from two DIFFERENT files = duplicate.
if [ -s "$dup_tmp" ]; then
  c3_hit=$(awk 'BEGIN { US = sprintf("%c", 31); FS = US }
    { loc = $1; body = substr($0, index($0, US) + 1) }
    body == pb { split(loc, a, ":"); split(pl, p, ":"); if (a[1] != p[1]) { print pl " " loc; exit } }
    { pb = body; pl = loc }
  ' "$dup_tmp")
  if [ -n "$c3_hit" ]; then
    warn "C3: Duplicate content block found in: $c3_hit"
    c3_ok=false
  fi
fi
rm -f "$dup_tmp"
$c3_ok && pass "C3: No duplicate content blocks"

# C4: knowledge/INDEX.md contains all files from subdirectories (WARNING)
if [ -f "$TARGET/knowledge/INDEX.md" ]; then
  c4_ok=true
  while IFS= read -r kfile; do
    basename_kfile=$(basename "$kfile")
    [[ "$basename_kfile" == "INDEX.md" ]] && continue
    if ! grep -q "$basename_kfile" "$TARGET/knowledge/INDEX.md" 2>/dev/null; then
      warn "C4: $kfile not listed in knowledge/INDEX.md"
      c4_ok=false
    fi
  done < <(find "$TARGET/knowledge" -name "*.md" -not -name "INDEX.md" -not -path '*/archive/*' 2>/dev/null)
  $c4_ok && pass "C4: knowledge/INDEX.md covers all files"
else
  if [ -d "$TARGET/knowledge" ]; then
    warn "C4: knowledge/INDEX.md missing — cannot verify coverage"
  else
    pass "C4: No knowledge/ directory — skipped"
  fi
fi

# C5: No circular references in "передай" / "forward to" / "delegate" (WARNING)
c5_ok=true
# Build a simple directed graph of agent references
graph_tmp=$(mktemp)
while IFS= read -r mdfile; do
  from=$(basename "$mdfile" .md)
  # Look for delegation patterns
  while IFS= read -r target; do
    target_clean=$(echo "$target" | sed 's/`//g; s/\.md//g' | xargs)
    [ -n "$target_clean" ] && echo "$from -> $target_clean" >> "$graph_tmp"
  done < <(grep -iE '(передай|forward|delegate|→|эскалируй)' "$mdfile" 2>/dev/null | grep -oE '`[^`]+\.md`' | sed 's/`//g' | sed 's/\.md//')
done < <(find "$TARGET" -name "*.md" -not -path '*/.git/*' -not -path '*/node_modules/*' -not -path '*/ai-offices/*' -not -path '*/_archive/*' 2>/dev/null)

if [ -f "$graph_tmp" ] && [ -s "$graph_tmp" ]; then
  # Simple cycle detection: for each node, follow edges up to depth 10
  while IFS= read -r start_node; do
    current="$start_node"
    visited="$start_node"
    depth=0
    cycle_found=false
    while [ $depth -lt 10 ]; do
      next=$(grep "^$current -> " "$graph_tmp" 2>/dev/null | head -1 | awk -F' -> ' '{print $2}')
      [ -z "$next" ] && break
      if echo "$visited" | grep -q "^${next}$"; then
        warn "C5: Circular reference detected: $visited -> $next"
        c5_ok=false
        cycle_found=true
        break
      fi
      visited="$visited
$next"
      current="$next"
      ((depth++))
    done
    $cycle_found && break
  done < <(awk -F' -> ' '{print $1}' "$graph_tmp" | sort -u)
fi
rm -f "$graph_tmp"
$c5_ok && pass "C5: No circular references detected"

echo ""

# ============================================================
# D. KNOWLEDGE & DATA (5 checks)
# ============================================================
echo -e "${CYAN}[D. Knowledge & Data]${NC}"

# D1: knowledge/ is not empty (>= 3 md files) (WARNING)
if [ -d "$TARGET/knowledge" ]; then
  k_count=$(find "$TARGET/knowledge" -name "*.md" -not -name "INDEX.md" 2>/dev/null | wc -l | tr -d ' ')
  if [ "$k_count" -ge 3 ]; then
    pass "D1: knowledge/ has $k_count md files"
  else
    warn "D1: knowledge/ has only $k_count md files (minimum: 3)"
  fi
else
  warn "D1: knowledge/ directory not found"
fi

# D2: No empty md files (ERROR)
d2_ok=true
while IFS= read -r mdfile; do
  lines=$(wc -l < "$mdfile" | tr -d ' ')
  if [ "$lines" -lt 2 ]; then
    rel="${mdfile#$TARGET/}"
    error "D2: Empty md file: $rel ($lines lines)"
    d2_ok=false
  fi
done < <(find "$TARGET" -name "*.md" -not -path '*/.git/*' -not -path '*/node_modules/*' -not -path '*/archive/*' -not -name "DEPRECATED*" 2>/dev/null)
$d2_ok && pass "D2: No empty md files"

# D3: No TODO stubs in md files (WARNING)
d3_ok=true
while IFS= read -r mdfile; do
  todo_count=$(grep -ciE '(TODO|FIXME|PLACEHOLDER|ЗАГЛУШКА)' "$mdfile" 2>/dev/null | head -1 || true)
  todo_count=${todo_count:-0}
  todo_count=$(echo "$todo_count" | tr -d '[:space:]')
  if [ "$todo_count" -gt 0 ] 2>/dev/null; then
    rel="${mdfile#$TARGET/}"
    warn "D3: $rel has $todo_count TODO/FIXME stubs"
    d3_ok=false
  fi
done < <(find "$TARGET" -name "*.md" -not -path '*/.git/*' -not -path '*/node_modules/*' -not -path '*/archive/*' -not -path '*/ai-offices/*' -not -path '*/_archive/*' 2>/dev/null)
$d3_ok && pass "D3: No TODO stubs found"

# D4: All md files <= 300 lines (WARNING, excluding walkthrough/guide files)
d4_ok=true
while IFS= read -r mdfile; do
  basename_file=$(basename "$mdfile")
  # Exclude walkthrough and guide files
  [[ "$basename_file" == *walkthrough* ]] && continue
  [[ "$basename_file" == *guide* ]] && continue
  [[ "$basename_file" == *tutorial* ]] && continue
  lines=$(wc -l < "$mdfile" | tr -d ' ')
  if [ "$lines" -gt 300 ]; then
    rel="${mdfile#$TARGET/}"
    warn "D4: $rel is $lines lines (limit: 300)"
    d4_ok=false
  fi
done < <(find "$TARGET" -name "*.md" -not -path '*/.git/*' -not -path '*/node_modules/*' -not -path '*/archive/*' -not -path '*/ai-offices/*' -not -path '*/_archive/*' 2>/dev/null)
$d4_ok && pass "D4: All md files <= 300 lines"

# D5: ops/ directory exists (WARNING) — в клиентском шаблоне живёт в office/ops
if [ -d "$TARGET/ops" ] || [ -d "$TARGET/office/ops" ]; then
  pass "D5: ops/ directory exists"
else
  warn "D5: ops/ directory not found"
fi

echo ""


# ============================================================
# E. CONTEXT BUDGET (wc-l лимиты — WARNING с путём починки, не ERROR)
# ============================================================
echo ""
echo -e "${CYAN}[E. Context budget]${NC}"

# E1: корневой CLAUDE.md ≤200
if [ -f "$TARGET/CLAUDE.md" ]; then
  root_lines=$(wc -l < "$TARGET/CLAUDE.md" | tr -d ' ')
  if [ "$root_lines" -le 200 ]; then
    pass "E1: root CLAUDE.md ${root_lines} строк (лимит 200)"
  else
    warn "E1: root CLAUDE.md ${root_lines} строк (>200). Что ужать: вынеси справочные таблицы в knowledge/, user-данные — в office/identity.md / map-файлы"
  fi
fi

# E2: core.md каждого агента ≤200
for core in "$TARGET"/office/agents/*/core.md; do
  [ -f "$core" ] || continue
  cl=$(wc -l < "$core" | tr -d ' ')
  if [ "$cl" -gt 200 ]; then
    warn "E2: $(echo "$core" | sed "s|$TARGET/||") — ${cl} строк (>200). Первым выносится справка в knowledge/ агента с указателем"
  fi
  e2_ok=${e2_ok:-true}
  [ "$cl" -gt 200 ] && e2_ok=false
done
${e2_ok:-true} && pass "E2: core.md агентов в лимите 200"

# E3: профиль ≤150
if [ -f "$TARGET/office/client-profile.md" ]; then
  pl=$(wc -l < "$TARGET/office/client-profile.md" | tr -d ' ')
  if [ "$pl" -le 150 ]; then
    pass "E3: client-profile.md ${pl} строк (лимит 150)"
  else
    warn "E3: client-profile.md ${pl} строк (>150). Историю изменений держи в memory.md Стратега, не в профиле"
  fi
fi

# E4: суммарный always-on — ФОРМУЛА, не константа: база 330 + 5×агентов в карте + 2×проектов
#     (при стартовых 4 агентах = 350, гейт плана). Офис растёт штатно — гейт не должен
#     краснеть от успеха. Жёсткий потолок 400 (порог деградации следования инструкциям).
if [ -f "$TARGET/CLAUDE.md" ]; then
  total=$(wc -l < "$TARGET/CLAUDE.md" | tr -d ' ')
  while IFS= read -r inc; do
    incfile="$TARGET/${inc#@}"
    [ -f "$incfile" ] && total=$((total + $(wc -l < "$incfile" | tr -d ' ')))
  done < <(grep -E '^@[a-zA-Z_./-]+' "$TARGET/CLAUDE.md" 2>/dev/null)
  # grep -c при нуле совпадений печатает «0» И выходит с кодом 1 — «|| echo 0»
  # давал бы «0\n0» и ронял арифметику. head -1 + дефолт закрывают оба случая.
  agents_n=$(grep -c '^- \*\*' "$TARGET/office/map-team.md" 2>/dev/null | head -1)
  agents_n=${agents_n:-0}
  projects_n=$(grep -c '^- \*\*' "$TARGET/office/map-projects.md" 2>/dev/null | head -1)
  projects_n=${projects_n:-0}
  allowed=$((330 + 5 * agents_n + 2 * projects_n))
  [ "$allowed" -gt 400 ] && allowed=400
  if [ "$total" -le "$allowed" ]; then
    pass "E4: always-on ${total} строк (формула допускает ${allowed}, потолок 400)"
  else
    warn "E4: always-on ${total} строк (> ${allowed} по формуле 330+5×${agents_n}агентов+2×${projects_n}проектов, потолок 400). Следование инструкциям падает после 400 — ужми корень/включённые файлы"
  fi
fi

# ============================================================
# F. REGISTRY & HOOKS (структурные — ERROR: дрейф ловится скриптом, не аудитом)
# ============================================================
echo ""
echo -e "${CYAN}[F. Registry & hooks]${NC}"

AGENTS_REG=""
for candidate in "$TARGET/office/AGENTS.md" "$TARGET/AGENTS.md"; do
  [ -f "$candidate" ] && AGENTS_REG="$candidate" && break
done

# F1: registry-lint — папка агента есть, строки в AGENTS.md нет → тихий сирота
if [ -n "$AGENTS_REG" ] && [ -d "$TARGET/office/agents" ]; then
  f1_ok=true
  for adir in "$TARGET"/office/agents/*/; do
    aname=$(basename "$adir")
    case "$aname" in _*) continue ;; esac  # _template/_templates — служебные, не агенты
    if ! grep -qi "$aname" "$AGENTS_REG"; then
      error "F1: агент '$aname' есть в office/agents/, но НЕ зарегистрирован в $(basename "$AGENTS_REG") (тихий сирота)"
      f1_ok=false
    fi
  done
  $f1_ok && pass "F1: registry-lint — все папки агентов зарегистрированы"
fi

# F2: обратный lint — карточка в map-team.md без папки агента
if [ -f "$TARGET/office/map-team.md" ]; then
  f2_ok=true
  while IFS= read -r cpath; do
    if [ ! -f "$TARGET/$cpath" ]; then
      error "F2: карта команды ссылается на '$cpath', но файла нет (агент в карте без входной точки)"
      f2_ok=false
    fi
  done < <(grep -oE 'office/agents/[a-z0-9_-]+/(core|CLAUDE)\.md' "$TARGET/office/map-team.md" 2>/dev/null | sort -u)
  $f2_ok && pass "F2: карта команды — все карточки ведут на существующих агентов"
fi

# F3: исполнимость хуков. Проверяем В ОБЕ стороны: файл есть → должен быть
# исполняем и зарегистрирован; зарегистрирован в settings.json → файл обязан
# существовать (самый опасный отказ — регистрация есть, файла нет: нервная
# система мертва, а валидатор молчит).
for hook in session-load.sh prompt-inject.sh; do
  hpath="$TARGET/.claude/hooks/$hook"
  registered=false
  grep -q "$hook" "$TARGET/.claude/settings.json" 2>/dev/null && registered=true
  if [ -f "$hpath" ]; then
    if [ -x "$hpath" ]; then
      if $registered; then
        pass "F3: $hook исполняем и зарегистрирован в settings.json"
      else
        error "F3: $hook существует, но НЕ зарегистрирован в .claude/settings.json — нервная система офиса не подключена"
      fi
    else
      error "F3: $hook не исполняемый (chmod +x .claude/hooks/$hook)"
    fi
  elif $registered; then
    error "F3: $hook зарегистрирован в settings.json, но файла .claude/hooks/$hook НЕТ — каждая сессия стартует с ошибкой хука"
  fi
done

# ============================================================
# SUMMARY
# ============================================================
TOTAL=$((PASS + WARN + ERROR + BLOCKER))
SCORE=$((100 - BLOCKER * 10 - ERROR * 5 - WARN * 2))
[ "$SCORE" -lt 0 ] && SCORE=0

echo -e "${BOLD}Summary:${NC} ${GREEN}$PASS PASS${NC} | ${YELLOW}$WARN WARN${NC} | ${RED}$ERROR ERROR${NC} | ${RED}${BOLD}$BLOCKER BLOCKER${NC}"
echo -e "${BOLD}Score: ${SCORE}/100${NC}"
echo ""

# Print issues
if [ "$BLOCKER" -gt 0 ]; then
  echo -e "${RED}${BOLD}BLOCKERS (must fix):${NC}"
  echo -e "$BLOCKER_LIST"
  echo ""
fi

if [ "$ERROR" -gt 0 ]; then
  echo -e "${RED}ERRORS (should fix):${NC}"
  echo -e "$ERROR_LIST"
  echo ""
fi

if [ "$WARN" -gt 0 ]; then
  echo -e "${YELLOW}WARNINGS (nice to fix):${NC}"
  echo -e "$WARN_LIST"
  echo ""
fi

# Exit code
if [ "$BLOCKER" -gt 0 ]; then
  exit 1
else
  exit 0
fi
