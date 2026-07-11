#!/usr/bin/env bash
# memory-scan.sh — детерминированный аудит контура памяти ЧУЖОГО AI-офиса.
# Эталон и логика проверок: docs/plans/2026-07-11-office-upgrade-track/_research2/memory-logic.md §6.
#
# READ-ONLY. Не пишет ни байта в --target. НИКОГДА не читает .env*/credentials*/secrets*.
# В вывод идут ТОЛЬКО пути и числа — тела строк памяти могут содержать ПД клиентов офиса.
#
#   memory-scan.sh --target DIR [--agents-glob 'office/agents/*']
#
# Выход — JSON в stdout: массив checks {id,weight,status,note,offenders} + memory_score + hard_violations.
# Generic-fallback: нет агентских слоёв → соответствующие проверки status:skip (не fail).
set -euo pipefail

TARGET=""
AGENTS_GLOB="office/agents/*"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)      TARGET="$2";      shift 2 ;;
    --agents-glob) AGENTS_GLOB="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$TARGET" && -d "$TARGET" ]] || { echo "no target dir: $TARGET" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Сбор проверок. Каждая проверка добавляется как одна JSON-строка в $CHECKS.
# offenders_raw — строки через \n; пустая строка = нет нарушителей.
# ---------------------------------------------------------------------------
CHECKS=""
add_check() {
  local id="$1" weight="$2" status="$3" note="$4" offenders_raw="${5:-}"
  local off_json='[]'
  if [[ -n "$offenders_raw" ]]; then
    off_json="$(printf '%s\n' "$offenders_raw" | grep -v '^$' | jq -R . | jq -s .)"
  fi
  local obj
  obj="$(jq -n --arg id "$id" --arg w "$weight" --arg s "$status" \
               --arg n "$note" --argjson off "$off_json" \
               '{id:$id, weight:$w, status:$s, note:$n, offenders:$off}')"
  CHECKS+="$obj"$'\n'
}

# --- Инвентаризация агентов: папки по glob, содержащие core.md ИЛИ CLAUDE.md ---
shopt -s nullglob
AGENTS=()
for d in "$TARGET"/$AGENTS_GLOB; do
  [[ -d "$d" ]] || continue
  [[ -f "$d/core.md" || -f "$d/CLAUDE.md" ]] || continue
  AGENTS+=("$d")
done
shopt -u nullglob

HOOKS_DIR="$TARGET/.claude/hooks"
has_hooks() { [[ -d "$HOOKS_DIR" ]] && compgen -G "$HOOKS_DIR/*.sh" >/dev/null 2>&1; }

# ===========================================================================
# M1 (high) — у каждого агента memory.md + failures.md; секции Decisions/Patterns/Context
# ===========================================================================
if [[ ${#AGENTS[@]} -eq 0 ]]; then
  add_check M1 high skip "агентских папок не найдено (glob: $AGENTS_GLOB) — контур памяти агентов отсутствует" ""
else
  m1_off=""
  for a in "${AGENTS[@]}"; do
    reason=()
    [[ -f "$a/memory.md" ]]   || reason+=("no memory.md")
    [[ -f "$a/failures.md" ]] || reason+=("no failures.md")
    if [[ -f "$a/memory.md" ]]; then
      # Секция = markdown-заголовок (^#..) или жирная строка (^**Context**), а не слово в прозе.
      for sec in Decisions Patterns Context; do
        grep -qiE "^#{1,6}.*${sec}|^\*{1,2}${sec}" "$a/memory.md" || reason+=("no $sec")
      done
    fi
    [[ ${#reason[@]} -gt 0 ]] && m1_off+="$a ($(IFS=,; echo "${reason[*]}"))"$'\n'
  done
  if [[ -n "$m1_off" ]]; then
    add_check M1 high fail "агенты с неполной памятью (нет файла или секции)" "$m1_off"
  else
    add_check M1 high pass "у всех ${#AGENTS[@]} агентов есть memory.md + failures.md с секциями" ""
  fi
fi

# ===========================================================================
# M1b (medium) — размер memory.md агента: soft 500 / hard 1000 строк (канон Риты
# office-cleaner/core.md; house-style, а не жёсткий потолок Anthropic — грейд не режет).
# ===========================================================================
if [[ ${#AGENTS[@]} -eq 0 ]]; then
  add_check M1b medium skip "нет агентов — нечего мерить" ""
else
  m1b_off=""
  for a in "${AGENTS[@]}"; do
    [[ -f "$a/memory.md" ]] || continue
    lines=$(wc -l < "$a/memory.md" | tr -d ' ')
    if [[ "$lines" -gt 1000 ]]; then
      m1b_off+="$a/memory.md ($lines строк, за жёстким 1000)"$'\n'
    elif [[ "$lines" -gt 500 ]]; then
      m1b_off+="$a/memory.md ($lines строк, за мягким 500)"$'\n'
    fi
  done
  if [[ -n "$m1b_off" ]]; then
    add_check M1b medium fail "memory.md сверх лимита строк — нужна самоконсолидация/archive" "$m1b_off"
  else
    add_check M1b medium pass "все memory.md в пределах мягкого лимита 500 строк" ""
  fi
fi

# ===========================================================================
# M2 (medium) — записи memory.md датированы ISO (файл >5 строк без 20XX- → кандидат)
# ===========================================================================
if [[ ${#AGENTS[@]} -eq 0 ]]; then
  add_check M2 medium skip "нет агентов — нет memory.md для проверки дат" ""
else
  m2_off=""
  for a in "${AGENTS[@]}"; do
    [[ -f "$a/memory.md" ]] || continue
    lines=$(wc -l < "$a/memory.md" | tr -d ' ')
    [[ "$lines" -gt 5 ]] || continue
    grep -qE '20[0-9][0-9]-' "$a/memory.md" || m2_off+="$a/memory.md"$'\n'
  done
  if [[ -n "$m2_off" ]]; then
    add_check M2 medium fail "memory.md с контентом, но без единой ISO-даты — записи недатированы" "$m2_off"
  else
    add_check M2 medium pass "записи memory.md датированы ISO" ""
  fi
fi

# ===========================================================================
# M4 (medium) — сессионный/фокус-слой: файл состояния + хук, который его читает/пишет.
# Не хардкодим today.md: ищем ЛЮБОЙ механизм (*state*.json / today.md / context.md / session-notes.md).
# ===========================================================================
sess_files="$(find "$TARGET/office/ops" "$TARGET/ops" "$TARGET/office" -maxdepth 1 -type f \
  \( -name '*state*.json' -o -name 'today.md' -o -name 'context.md' -o -name 'session-notes.md' \) \
  2>/dev/null | sort || true)"
sess_hook=""
if has_hooks; then
  sess_hook="$(grep -lEi 'state|focus|today|context|session' "$HOOKS_DIR"/*.sh 2>/dev/null || true)"
fi
if [[ -z "$sess_files" && -z "$sess_hook" ]]; then
  add_check M4 medium skip "ни файла сессионного слоя, ни хука к нему — слой не заведён" ""
elif [[ -n "$sess_files" && -n "$sess_hook" ]]; then
  add_check M4 medium pass "есть живой сессионный слой (файл состояния + читающий его хук)" ""
else
  add_check M4 medium fail "сессионный слой неполон: есть файл ИЛИ хук, но не связка (вывеска без контура)" ""
fi

# ===========================================================================
# M5 (high) — auto-memory MEMORY.md ≤200 строк И ≤25KB.
# hard_violation ТОЛЬКО если за потолком И рядом НЕТ archive-файла: split
# MEMORY.md + MEMORY-archive.md — правильный hot/cold-паттерн, а не нарушение.
# ===========================================================================
mem_files="$(find "$TARGET" -type f -name 'MEMORY.md' 2>/dev/null | sort || true)"
if [[ -z "$mem_files" ]]; then
  add_check M5 high skip "MEMORY.md (auto-memory) не найден — эпизодический слой отсутствует" ""
else
  m5_off=""; split_note=""
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    lines=$(wc -l < "$f" | tr -d ' ')
    bytes=$(wc -c < "$f" | tr -d ' ')
    kb=$(( (bytes + 1023) / 1024 ))
    over=0
    [[ "$lines" -gt 200 || "$bytes" -gt 25600 ]] && over=1
    # archive рядом = cold-хранилище (hot/cold сплит) — снимает нарушение.
    has_archive=0
    compgen -G "$(dirname "$f")/*archive*" >/dev/null 2>&1 && has_archive=1
    if [[ "$over" -eq 1 && "$has_archive" -eq 0 ]]; then
      m5_off+="$f ($lines строк, ${kb}KB — за потолком 200/25KB, archive рядом нет)"$'\n'
    elif [[ "$over" -eq 1 && "$has_archive" -eq 1 ]]; then
      split_note="; MEMORY.md за 200/25KB, но рядом archive — здоровый hot/cold-split"
    fi
  done <<< "$mem_files"
  if [[ -n "$m5_off" ]]; then
    add_check M5 high fail "MEMORY.md за потолком без archive рядом — хвост невидим агенту" "$m5_off"
  else
    add_check M5 high pass "MEMORY.md в пределах 200 строк/25KB${split_note}" ""
  fi
fi

# ===========================================================================
# M7 (high) — enforcement записи памяти: хук, реально грепающийся на memory/failures
# (контур, а не декларация «пиши в memory.md» в core.md).
# ===========================================================================
if ! has_hooks; then
  add_check M7 high skip ".claude/hooks отсутствует — enforcement памяти проверять негде" ""
else
  m7_hooks="$(grep -lE 'memory\.md|failures\.md|/memory|memory/' "$HOOKS_DIR"/*.sh 2>/dev/null || true)"
  if [[ -n "$m7_hooks" ]]; then
    add_check M7 high pass "есть хук-enforcement, ссылающийся на memory.md/failures.md" ""
  else
    add_check M7 high fail "хуки есть, но ни один не страхует запись памяти — только вывеска в core.md" ""
  fi
fi

# ===========================================================================
# M8 (medium) — институтский кросс-агентный слой lessons-learned + пишущий механизм
# ===========================================================================
lessons="$(find "$TARGET/office" "$TARGET/ops" "$TARGET/office/ops" -maxdepth 2 -type f \
  \( -name 'lessons-learned*' -o -name 'lessons*' \) 2>/dev/null | sort || true)"
lessons_writer=""
if has_hooks; then
  lessons_writer="$(grep -lEi 'lessons-learned|lessons' "$HOOKS_DIR"/*.sh 2>/dev/null || true)"
fi
if [[ -z "$lessons" ]]; then
  add_check M8 medium skip "институтского lessons-learned нет — кросс-агентные уроки негде копить" ""
elif [[ -n "$lessons_writer" ]]; then
  add_check M8 medium pass "lessons-learned есть и в него пишет механизм" ""
else
  add_check M8 medium fail "lessons-learned существует, но пишущего механизма нет — файл-вывеска" "$lessons"
fi

# ===========================================================================
# M9 (medium) — антидубль между сессиями: lock/dedup примитив (flock/session-notes/dedup)
# ===========================================================================
m9_hit=""
if has_hooks; then
  m9_hit="$(grep -lEi 'flock|session-notes|dedup|mkdir.*lock' "$HOOKS_DIR"/*.sh 2>/dev/null || true)"
fi
if [[ -z "$m9_hit" ]] && ! has_hooks; then
  add_check M9 medium skip "хуков нет — примитив антидубля искать негде" ""
elif [[ -n "$m9_hit" ]]; then
  add_check M9 medium pass "есть примитив синхронизации/дедупа (flock/session-notes/dedup)" ""
else
  add_check M9 medium fail "хуки есть, но реального lock/dedup-примитива нет — полагаются на «не должно повториться»" ""
fi

# ===========================================================================
# M10 (medium) — вики-гигиена: в knowledge/* с ≥3 md есть INDEX.md
# ===========================================================================
if [[ ! -d "$TARGET/knowledge" ]]; then
  add_check M10 medium skip "knowledge/ отсутствует — вики-слоя нет" ""
else
  m10_off=""
  while IFS= read -r dir; do
    [[ -n "$dir" ]] || continue
    # md без учёта самого INDEX.md
    n=$(find "$dir" -maxdepth 1 -type f -name '*.md' ! -iname 'INDEX.md' 2>/dev/null | wc -l | tr -d ' ')
    [[ "$n" -ge 3 ]] || continue
    if [[ ! -f "$dir/INDEX.md" && ! -f "$dir/index.md" ]]; then
      m10_off+="$dir ($n md, нет INDEX.md)"$'\n'
    fi
  done < <(find "$TARGET/knowledge" -type d 2>/dev/null | sort)
  if [[ -n "$m10_off" ]]; then
    add_check M10 medium fail "папки вики с ≥3 md без INDEX.md — навигация проседает" "$m10_off"
  else
    add_check M10 medium pass "во всех папках вики с ≥3 md есть INDEX.md" ""
  fi
fi

# ===========================================================================
# M11 (high) — сырьевые *.jsonl в office/ops|ops >500KB без признака дистилляции
# ===========================================================================
big_jsonl="$(find "$TARGET/office/ops" "$TARGET/ops" -type f -name '*.jsonl' -size +500k 2>/dev/null | sort || true)"
any_jsonl="$(find "$TARGET/office/ops" "$TARGET/ops" -type f -name '*.jsonl' 2>/dev/null || true)"
# Признак дистилляции: watermark-файл, скилл distill, или хук, ссылающийся на distill.
distill_sign=""
compgen -G "$TARGET/office/ops/*watermark*" >/dev/null 2>&1 && distill_sign="watermark"
compgen -G "$TARGET/office/ops/.*watermark*" >/dev/null 2>&1 && distill_sign="watermark"
[[ -z "$distill_sign" ]] && compgen -G "$TARGET/.claude/skills/*distill*" >/dev/null 2>&1 && distill_sign="skill"
if [[ -z "$distill_sign" ]] && has_hooks; then
  grep -lqiE 'distill' "$HOOKS_DIR"/*.sh 2>/dev/null && distill_sign="hook"
fi
if [[ -z "$any_jsonl" ]]; then
  add_check M11 high skip "сырьевых *.jsonl в ops не найдено" ""
elif [[ -n "$big_jsonl" && -z "$distill_sign" ]]; then
  m11_off=""
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    kb=$(( ($(wc -c < "$f" | tr -d ' ') + 1023) / 1024 ))
    m11_off+="$f (${kb}KB)"$'\n'
  done <<< "$big_jsonl"
  add_check M11 high fail "сырьё >500KB копится без триггера дистилляции — переработка не поспевает" "$m11_off"
else
  note="сырьё в пределах порога"
  [[ -n "$distill_sign" ]] && note="есть признак дистилляции ($distill_sign)"
  add_check M11 high pass "$note" ""
fi

# ===========================================================================
# M12 (medium) — нет датированного дневника в корневом CLAUDE.md и core.md агентов
# ===========================================================================
m12_off=""
m12_targets=""
[[ -f "$TARGET/CLAUDE.md" ]] && m12_targets+="$TARGET/CLAUDE.md"$'\n'
if [[ ${#AGENTS[@]} -gt 0 ]]; then
  for a in "${AGENTS[@]}"; do
    [[ -f "$a/core.md" ]] && m12_targets+="$a/core.md"$'\n'
  done
fi
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  # grep -c печатает 0 при отсутствии совпадений и выходит 1 — гасим `|| true`,
  # иначе к «0» подклеится второй «0» и арифметика [[ ]] споткнётся.
  cnt=$(grep -cE '^- 20[0-9]{2}-' "$f" 2>/dev/null || true)
  cnt=${cnt:-0}
  [[ "$cnt" -gt 0 ]] && m12_off+="$f ($cnt датированных строк)"$'\n'
done <<< "$m12_targets"
if [[ -n "$m12_off" ]]; then
  add_check M12 medium fail "датированный дневник в always-on правилах — место урока в memory, не в CLAUDE/core" "$m12_off"
else
  add_check M12 medium pass "в CLAUDE.md/core.md нет датированного дневника" ""
fi

# ===========================================================================
# Финальная сборка: score (high=2, medium=1; skip вне знаменателя) + hard_violations (M5 fail).
# Пол insufficient_data: <3 оценённых (non-skip) проверок → голый 100 обманчив
# (всё-skip = «идеальное здоровье» на пустоте), отдаём memory_score:null + пометку.
# assessed_checks/skipped_checks идут рядом, чтобы LLM-слой видел базу оценки.
# Никаких timestamp/рандома в выводе — прогон идемпотентен.
# ===========================================================================
MIN_ASSESSED=3
printf '%s' "$CHECKS" | grep -v '^$' | jq -s --arg target "$TARGET" --argjson min "$MIN_ASSESSED" '
  def w: if .weight == "high" then 2 else 1 end;
  . as $checks
  | ([ $checks[] | select(.status != "skip") ] | length) as $assessed
  | ([ $checks[] | select(.status == "skip") ] | length) as $skipped
  | ([ $checks[] | select(.status != "skip") | w ] | add // 0) as $den
  | ([ $checks[] | select(.status == "pass") | w ] | add // 0) as $num
  | ($assessed < $min or $den == 0) as $insufficient
  | {
      target: $target,
      checks: $checks,
      assessed_checks: $assessed,
      skipped_checks: $skipped,
      score_status: (if $insufficient then "insufficient_data" else "ok" end),
      memory_score: (if $insufficient then null else (($num / $den) * 100 | floor) end),
      hard_violations: [ $checks[] | select(.id == "M5" and .status == "fail") | .offenders[] ]
    }
'
