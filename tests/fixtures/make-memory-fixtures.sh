#!/usr/bin/env bash
# Генератор фикстур-офисов для модуля audit-memory (контур памяти чужого офиса).
# Три эталона: здоровый / дырявый / голый — каждый прицельно бьёт свой класс проверок.
# Read-only-скилл будет мерить их против канона memory-logic.md §6.
set -euo pipefail

DIR="${1:?usage: make-memory-fixtures.sh <outdir>}"
rm -rf "$DIR"

# Наполнитель: раздутый файл сверх мягкого лимита memory.md (500 строк, канон Риты).
bulk() { local n="$1"; local i; for ((i=1;i<=n;i++)); do echo "строка наполнителя $i"; done; }

# ---------------------------------------------------------------------------
# 1. ЗДОРОВЫЙ офис — весь контур памяти на месте, каждая проверка проходит.
# ---------------------------------------------------------------------------
H="$DIR/healthy"
mkdir -p "$H/office/agents/director" "$H/office/agents/rita" \
         "$H/office/ops" "$H/memory" "$H/.claude/hooks" "$H/knowledge/topic"

printf '# Office\n\nКанон офиса без датированного дневника.\n' > "$H/CLAUDE.md"

# Два агента: memory.md с секциями Decisions/Patterns/Context и ISO-датами, + failures.md
for a in director rita; do
  cat > "$H/office/agents/$a/core.md" <<EOF
# $a core
Роль агента. Императив: после задачи — 1-3 строки в memory.md.
EOF
  cat > "$H/office/agents/$a/memory.md" <<EOF
# память $a
## Decisions
- 2026-07-01 решили держать единый формат
## Patterns
- 2026-07-02 паттерн: сначала grep, потом задача
## Context
- 2026-07-03 контекст: офис на VPS
EOF
  cat > "$H/office/agents/$a/failures.md" <<EOF
2026-07-01 → предположил A → оказалось B → правило C
EOF
done

# Слой 2: MEMORY.md в лимите + archive рядом (M5)
{ echo "# Memory Index"; bulk 49; } > "$H/memory/MEMORY.md"       # 50 строк
printf '# Archive\n' > "$H/memory/MEMORY-archive.md"

# Слой 1: сессионный state-файл + хук, который его читает (M4)
printf '{"mit":"","mode":"work"}\n' > "$H/office/ops/focus-state.json"
cat > "$H/.claude/hooks/focus-inject.sh" <<'EOF'
#!/usr/bin/env bash
# читает office/ops/focus-state.json и инжектит [focus]
cat "$OFFICE/office/ops/focus-state.json" >/dev/null
EOF

# Enforcement записи памяти — хук грепается на memory.md/failures.md (M7)
cat > "$H/.claude/hooks/memory-check.sh" <<'EOF'
#!/usr/bin/env bash
# страховка: раз в N сессий проверяет mtime memory.md и failures.md, эскалирует
find "$OFFICE" -name memory.md -o -name failures.md >/dev/null
EOF

# Институтский слой lessons-learned + пишущий в него хук (M8)
printf '# Lessons\n- кросс-агентный урок\n' > "$H/office/ops/lessons-learned.md"
cat > "$H/.claude/hooks/lessons-writer.sh" <<'EOF'
#!/usr/bin/env bash
# дописывает кросс-агентные уроки в ops/lessons-learned.md
echo "$1" >> "$OFFICE/office/ops/lessons-learned.md"
EOF

# Антидубль: flock + session-notes (M9)
printf '2026-07-11 | drift-secondary | текст\n' > "$H/office/ops/session-notes.md"
cat > "$H/.claude/hooks/focus-note.sh" <<'EOF'
#!/usr/bin/env bash
# dedup-ключ + mkdir/flock-лок против гонок параллельных сессий
flock "$OFFICE/office/ops/session-notes.md" true
EOF

# Сырьё с признаком дистилляции: маленький лог + watermark (M11 pass)
printf '{"agent":"director","note":"x"}\n' > "$H/office/ops/captures.jsonl"
printf '2026-07-11T00:00:00Z\n' > "$H/office/ops/.distill-watermark"

# Вики: папка с 3 md имеет свой INDEX.md (M10)
printf '# Index\n' > "$H/knowledge/topic/INDEX.md"
printf '# a\n' > "$H/knowledge/topic/a.md"
printf '# b\n' > "$H/knowledge/topic/b.md"
printf '# c\n' > "$H/knowledge/topic/c.md"

# ---------------------------------------------------------------------------
# 2. ДЫРЯВЫЙ офис — каждый класс дефектов представлен ровно одним нарушителем.
# ---------------------------------------------------------------------------
L="$DIR/leaky"
mkdir -p "$L/office/agents/broke" "$L/office/agents/bloat" \
         "$L/office/ops" "$L/memory" "$L/knowledge/topic2"

# Датированный дневник в корневом CLAUDE.md — уроку тут не место (M12)
cat > "$L/CLAUDE.md" <<EOF
# Office
- 2026-01-01 сделал X руками
Канон.
EOF

# Агент broke: НЕТ failures.md; memory.md без дат, >5 строк, без секций.
# ПД-маркер посажен в ТЕЛО записи — он НЕ должен утечь в вывод скилла.
cat > "$L/office/agents/broke/core.md" <<EOF
# broke core
EOF
cat > "$L/office/agents/broke/memory.md" <<EOF
заметки по клиенту
телефон клиента и адрес
CLIENT_PD_MARKER_XYZZY встреча в четверг
обсудили бюджет
следующий шаг звонок
хвост записи
EOF

# Агент bloat: структура валидна, но memory.md раздут за мягкий лимит 500 строк (M1b).
cat > "$L/office/agents/bloat/core.md" <<EOF
# bloat core
EOF
{ echo "# память bloat"; echo "## Decisions"; echo "- 2026-07-01 X"; \
  echo "## Patterns"; echo "- 2026-07-02 Y"; echo "## Context"; \
  echo "- 2026-07-03 Z"; bulk 700; } > "$L/office/agents/bloat/memory.md"
cat > "$L/office/agents/bloat/failures.md" <<EOF
2026-07-01 → A → B → C
EOF

# Слой 2: MEMORY.md 250 строк — за жёстким потолком 200 (M5 → hard_violation), без archive.
{ echo "# Memory Index"; bulk 249; } > "$L/memory/MEMORY.md"

# Сырьё >500KB без признака дистилляции (M11): ~600KB.
# awk, а не `yes | head`: последний под pipefail роняет скрипт по SIGPIPE (141).
awk 'BEGIN{for(i=0;i<12000;i++)print "{\"agent\":\"x\",\"note\":\"padding padding padding padding padding pad\"}"}' \
  > "$L/office/ops/captures.jsonl"

# Вики: 4 md без INDEX.md (M10)
printf '# a\n' > "$L/knowledge/topic2/a.md"
printf '# b\n' > "$L/knowledge/topic2/b.md"
printf '# c\n' > "$L/knowledge/topic2/c.md"
printf '# d\n' > "$L/knowledge/topic2/d.md"

# ---------------------------------------------------------------------------
# 3. ГОЛЫЙ офис — только CLAUDE.md. Агентских слоёв нет: проверки должны скипаться, не падать.
# ---------------------------------------------------------------------------
B="$DIR/bare"
mkdir -p "$B"
printf '# Bare office\nбез датированного дневника\n' > "$B/CLAUDE.md"
