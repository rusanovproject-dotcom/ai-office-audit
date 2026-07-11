#!/usr/bin/env bats
# CRIT-1 проводка защиты: гейт реально зарегистрирован, скиллы прошиты протоколом
# безопасности, аудит-скиллы больше не носят голый Bash в allowed-tools.
# Имена тестов латиницей: bats не переваривает кириллицу в @test.

bats_require_minimum_version 1.5.0

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SETTINGS="$REPO/.claude/settings.json"
  SKILLS="$REPO/.claude/skills"
}

# --- settings.json: гейт зарегистрирован как PreToolUse-хук ---

@test "settings.json exists and is valid json" {
  [ -f "$SETTINGS" ]
  run jq -e . "$SETTINGS"
  [ "$status" -eq 0 ]
}

@test "settings.json registers readonly-gate as a PreToolUse hook" {
  run jq -e '.hooks.PreToolUse | map(.hooks[].command) | flatten
             | any(test("readonly-gate\\.sh"))' "$SETTINGS"
  [ "$status" -eq 0 ]
}

@test "settings.json PreToolUse matcher covers write and bash tools" {
  local m
  m="$(jq -r '.hooks.PreToolUse[].matcher' "$SETTINGS")"
  echo "$m" | grep -q "Write"
  echo "$m" | grep -q "Edit"
  echo "$m" | grep -q "NotebookEdit"
  echo "$m" | grep -q "Bash"
}

# --- каждый из 4 SKILL.md прошит протоколом безопасности ---

@test "each audit skill wires backup-target before mutation" {
  for s in audit-security audit-fit audit-dev audit-memory; do
    grep -q "backup-target" "$SKILLS/$s/SKILL.md" \
      || { echo "no backup-target in $s"; return 1; }
    grep -q "mutation-unlocked" "$SKILLS/$s/SKILL.md" \
      || { echo "no mutation-unlocked in $s"; return 1; }
  done
}

# --- аудит-скиллы больше не носят голый Bash в allowed-tools ---

@test "audit-security/fit/dev drop bare Bash from allowed-tools" {
  for s in audit-security audit-fit audit-dev; do
    local line
    line="$(grep '^allowed-tools:' "$SKILLS/$s/SKILL.md")"
    # голый Bash = токен Bash, за которым идёт запятая или конец строки (не "(")
    if echo "$line" | grep -Eq 'Bash([[:space:]]*,|[[:space:]]*$)'; then
      echo "bare Bash still present in $s: $line"
      return 1
    fi
    # scoped Bash к движкам обязан присутствовать
    echo "$line" | grep -q 'Bash(' || { echo "no scoped Bash in $s"; return 1; }
  done
}
