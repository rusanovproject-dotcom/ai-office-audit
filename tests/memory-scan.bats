#!/usr/bin/env bats
# Аудит контура памяти чужого офиса (memory-logic.md §6, детерминированная часть).
# Read-only. Пути и числа в вывод — да; тела строк памяти (ПД клиентов) — никогда.
# Имена тестов латиницей: bats не переваривает кириллицу в @test.

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCAN="$REPO/engine/memory-scan.sh"
  FIX="$BATS_TEST_TMPDIR/offices"
  bash "$BATS_TEST_DIRNAME/fixtures/make-memory-fixtures.sh" "$FIX"
  HEALTHY="$(bash "$SCAN" --target "$FIX/healthy")"
  LEAKY="$(bash "$SCAN" --target "$FIX/leaky")"
  BARE="$(bash "$SCAN" --target "$FIX/bare")"
}

# Хелпер: статус проверки по id
status_of() { jq -r --arg id "$1" '.checks[] | select(.id==$id) | .status' <<< "$2"; }

# --- ЗДОРОВЫЙ ОФИС ---

@test "healthy: M1 M5 M7 pass" {
  [ "$(status_of M1 "$HEALTHY")" = "pass" ]
  [ "$(status_of M5 "$HEALTHY")" = "pass" ]
  [ "$(status_of M7 "$HEALTHY")" = "pass" ]
}

@test "healthy: memory_score high" {
  score="$(jq -r '.memory_score' <<< "$HEALTHY")"
  [ "$score" -ge 80 ]
}

@test "healthy: no hard violations" {
  [ "$(jq -r '.hard_violations | length' <<< "$HEALTHY")" -eq 0 ]
}

# --- ДЫРЯВЫЙ ОФИС ---

@test "leaky: M1 fails and offender names the agent" {
  [ "$(status_of M1 "$LEAKY")" = "fail" ]
  jq -e '.checks[] | select(.id=="M1") | .offenders | any(test("broke"))' <<< "$LEAKY"
}

@test "leaky: M2 fails on undated memory" {
  [ "$(status_of M2 "$LEAKY")" = "fail" ]
}

@test "leaky: M5 fails and hard_violations non-empty" {
  [ "$(status_of M5 "$LEAKY")" = "fail" ]
  [ "$(jq -r '.hard_violations | length' <<< "$LEAKY")" -ge 1 ]
}

@test "leaky: M11 fails with path and size in offender" {
  [ "$(status_of M11 "$LEAKY")" = "fail" ]
  jq -e '.checks[] | select(.id=="M11") | .offenders | any(test("captures.jsonl"))' <<< "$LEAKY"
  # размер (число + KB) присутствует в строке нарушителя
  jq -e '.checks[] | select(.id=="M11") | .offenders | any(test("[0-9]+"))' <<< "$LEAKY"
}

@test "leaky: M12 fails on dated diary in CLAUDE.md" {
  [ "$(status_of M12 "$LEAKY")" = "fail" ]
}

@test "leaky: M1b offenders list the bloated memory.md" {
  [ "$(status_of M1b "$LEAKY")" = "fail" ]
  [ "$(jq -r '.checks[] | select(.id=="M1b") | .offenders | length' <<< "$LEAKY")" -ge 1 ]
  jq -e '.checks[] | select(.id=="M1b") | .offenders | any(test("bloat"))' <<< "$LEAKY"
}

# --- ГОЛЫЙ ОФИС (generic fallback) ---

@test "bare: agent checks skip, engine survives" {
  [ "$(status_of M1 "$BARE")" = "skip" ]
  [ "$(status_of M2 "$BARE")" = "skip" ]
  [ "$(status_of M1b "$BARE")" = "skip" ]
}

@test "bare: exit 0 and valid JSON" {
  run bash "$SCAN" --target "$FIX/bare"
  [ "$status" -eq 0 ]
  jq -e . <<< "$output" >/dev/null
}

# --- ПД-ГЕЙТ: тела строк памяти чужого офиса не утекают ---

@test "pd gate: record body marker never appears in output" {
  # Маркер сидит в теле memory.md дырявого офиса — в отчёт должны попасть только пути.
  ! grep -q "CLIENT_PD_MARKER_XYZZY" <<< "$LEAKY"
}

# --- ИНВАРИАНТЫ ДВИЖКА ---

@test "isolation: engine writes nothing into target" {
  before="$(find "$FIX/leaky" -type f -exec shasum {} + | shasum)"
  bash "$SCAN" --target "$FIX/leaky" >/dev/null
  after="$(find "$FIX/leaky" -type f -exec shasum {} + | shasum)"
  [ "$before" = "$after" ]
}

@test "idempotent: two runs produce identical JSON" {
  a="$(bash "$SCAN" --target "$FIX/healthy")"
  b="$(bash "$SCAN" --target "$FIX/healthy")"
  [ "$a" = "$b" ]
}

@test "output is valid JSON for every fixture" {
  jq -e . <<< "$HEALTHY" >/dev/null
  jq -e . <<< "$LEAKY" >/dev/null
  jq -e . <<< "$BARE" >/dev/null
}

# --- Явный агент-глоб override работает ---
@test "custom agents-glob is honoured" {
  out="$(bash "$SCAN" --target "$FIX/healthy" --agents-glob 'office/agents/*')"
  [ "$(status_of M1 "$out")" = "pass" ]
}

# --- CORR-3: почти-пустой офис не читается как «100 = здорово» ---

@test "bare: score is insufficient_data, not a misleading 100" {
  [ "$(jq -r '.memory_score' <<< "$BARE")" = "null" ]
  [ "$(jq -r '.score_status' <<< "$BARE")" = "insufficient_data" ]
  [ "$(jq -r '.assessed_checks' <<< "$BARE")" -lt 3 ]
}

@test "healthy: score_status ok and counters exposed" {
  [ "$(jq -r '.score_status' <<< "$HEALTHY")" = "ok" ]
  [ "$(jq -r '.assessed_checks' <<< "$HEALTHY")" -ge 3 ]
  [ "$(jq -r '.skipped_checks' <<< "$HEALTHY")" -ge 0 ]
}

# --- CORR-4: секция памяти = markdown-заголовок, не слово в прозе ---

@test "M1: prose mentioning section words is not a real section" {
  O="$BATS_TEST_TMPDIR/prose"
  mkdir -p "$O/office/agents/a"
  printf '# a\n' > "$O/office/agents/a/core.md"
  printf '2026-07-01 -> A -> B -> C\n' > "$O/office/agents/a/failures.md"
  cat > "$O/office/agents/a/memory.md" <<'EOF'
# память
в этом context мы приняли решения по проекту
наши patterns устоялись за неделю
все decisions залогированы где-то ещё
2026-07-01 запись
хвост
EOF
  out="$(bash "$SCAN" --target "$O")"
  [ "$(status_of M1 "$out")" = "fail" ]
}

@test "M1: markdown headings count as real sections" {
  O="$BATS_TEST_TMPDIR/heads"
  mkdir -p "$O/office/agents/a"
  printf '# a\n' > "$O/office/agents/a/core.md"
  printf '2026-07-01 -> A -> B -> C\n' > "$O/office/agents/a/failures.md"
  cat > "$O/office/agents/a/memory.md" <<'EOF'
# память
## Decisions
- 2026-07-01 x
## Patterns
- 2026-07-02 y
## Context
- 2026-07-03 z
EOF
  out="$(bash "$SCAN" --target "$O")"
  [ "$(status_of M1 "$out")" = "pass" ]
}

# --- MED-5: пороги в каноне ЭТОГО офиса (Рита: memory.md soft 500 / hard 1000) ---

@test "M1b: soft limit is 500 (400-line memory.md is fine)" {
  O="$BATS_TEST_TMPDIR/soft"
  mkdir -p "$O/office/agents/a"
  printf '# a\n' > "$O/office/agents/a/core.md"
  printf '2026-07-01 -> A -> B -> C\n' > "$O/office/agents/a/failures.md"
  { printf '# память\n## Decisions\n- 2026-07-01 x\n## Patterns\n- 2026-07-02 y\n## Context\n- 2026-07-03 z\n'; \
    for i in $(seq 1 400); do echo "строка $i"; done; } > "$O/office/agents/a/memory.md"
  out="$(bash "$SCAN" --target "$O")"
  [ "$(status_of M1b "$out")" = "pass" ]
}

@test "M5: MEMORY.md over 200 lines WITH archive nearby is healthy split" {
  O="$BATS_TEST_TMPDIR/split"
  mkdir -p "$O/memory"
  { echo "# Index"; for i in $(seq 1 250); do echo "row $i"; done; } > "$O/memory/MEMORY.md"
  printf '# Archive\n' > "$O/memory/MEMORY-archive.md"
  out="$(bash "$SCAN" --target "$O")"
  [ "$(status_of M5 "$out")" = "pass" ]
  [ "$(jq -r '.hard_violations | length' <<< "$out")" -eq 0 ]
}

@test "M5: MEMORY.md over 200 lines WITHOUT archive is a hard violation" {
  O="$BATS_TEST_TMPDIR/nosplit"
  mkdir -p "$O/memory"
  { echo "# Index"; for i in $(seq 1 250); do echo "row $i"; done; } > "$O/memory/MEMORY.md"
  out="$(bash "$SCAN" --target "$O")"
  [ "$(status_of M5 "$out")" = "fail" ]
  [ "$(jq -r '.hard_violations | length' <<< "$out")" -ge 1 ]
}

# --- Идемпотентность: порядок offenders стабилен между прогонами ---

@test "idempotent: offenders order identical across runs (leaky)" {
  a="$(bash "$SCAN" --target "$FIX/leaky")"
  b="$(bash "$SCAN" --target "$FIX/leaky")"
  [ "$a" = "$b" ]
}
