#!/usr/bin/env bats
# Движок инвентаря арсенала чужого офиса: какие скиллы/агенты/команды/хуки у него есть.
# READ-ONLY. Ни байта в чужой офис, не читает .env/secrets. JSON в stdout.
# Имена тестов латиницей: bats не переваривает кириллицу в @test.

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCAN="$REPO/engine/arsenal-scan.sh"
  OFFICES="$BATS_TEST_TMPDIR/offices"
  bash "$BATS_TEST_DIRNAME/fixtures/make-office-fixtures.sh" "$OFFICES"
  TARGET="$OFFICES/folder-per-agent"
}

# sha-манифест каталога — для проверки изоляции (ни байта записи).
manifest() { ( cd "$1" && find . -type f -exec shasum {} + | sort ); }

@test "folder-per-agent: skills inventory with description and broken-frontmatter fallback" {
  out="$(bash "$SCAN" --target "$TARGET")"
  # живой скилл: name из frontmatter, description считан
  jq -e '.skills | any(.name == "hormozi" and (.description | test("оффер")) and (.path | test("hormozi/SKILL.md")))' <<< "$out"
  # битый frontmatter не роняет движок: name = имя папки, description пустой
  jq -e '.skills | any(.name == "broken" and .description == "")' <<< "$out"
  # источник project-скиллов размечен
  jq -e '.skills | all(.source == "project")' <<< "$out"
}

@test "folder-per-agent: agents from office/agents layout with path" {
  out="$(bash "$SCAN" --target "$TARGET")"
  jq -e '.agents | any(.name == "director" and (.path | test("agents/director/core.md")))' <<< "$out"
  jq -e '.agents | any(.name == "rita" and (.path | test("agents/rita/core.md")))' <<< "$out"
}

@test "folder-per-agent: hooks listed by filename" {
  out="$(bash "$SCAN" --target "$TARGET")"
  jq -e '.hooks | index("x.sh")' <<< "$out"
}

@test "folder-per-agent: totals are correct" {
  out="$(bash "$SCAN" --target "$TARGET")"
  [ "$(jq -r '.skills_total' <<< "$out")" -eq 2 ]
  [ "$(jq -r '.agents_total' <<< "$out")" -eq 2 ]
}

@test "bare-claude office: empty arrays, exit 0, valid json" {
  run bash "$SCAN" --target "$OFFICES/bare-claude"
  [ "$status" -eq 0 ]
  jq -e '.' <<< "$output"                      # валидный JSON
  [ "$(jq -r '.skills | length' <<< "$output")" -eq 0 ]
  [ "$(jq -r '.agents | length' <<< "$output")" -eq 0 ]
  [ "$(jq -r '.hooks | length' <<< "$output")" -eq 0 ]
  [ "$(jq -r '.skills_total' <<< "$output")" -eq 0 ]
}

@test "empty office: empty arrays, exit 0, valid json" {
  run bash "$SCAN" --target "$OFFICES/empty"
  [ "$status" -eq 0 ]
  jq -e '.' <<< "$output"
  [ "$(jq -r '.skills | length' <<< "$output")" -eq 0 ]
  [ "$(jq -r '.agents | length' <<< "$output")" -eq 0 ]
}

# Пользовательские скиллы живут вне репо-офиса (его ~/.claude). Их надо уметь
# подмешивать и отличать по source, иначе арсенал неполон.
@test "claude-dir user skills mixed in and tagged source:user" {
  CDIR="$BATS_TEST_TMPDIR/userclaude"
  mkdir -p "$CDIR/skills/myuserskill"
  printf -- '---\nname: myuserskill\ndescription: личный скилл пользователя\n---\n# u\n' \
    > "$CDIR/skills/myuserskill/SKILL.md"
  out="$(bash "$SCAN" --target "$TARGET" --claude-dir "$CDIR")"
  jq -e '.skills | any(.name == "myuserskill" and .source == "user")' <<< "$out"
  jq -e '.skills | any(.name == "hormozi" and .source == "project")' <<< "$out"
}

# description обрезается до 300 символов, чтобы длинные простыни не раздували отчёт.
@test "long description truncated to 300 chars" {
  O="$BATS_TEST_TMPDIR/longoffice"
  mkdir -p "$O/.claude/skills/verbose"
  long="$(printf 'a%.0s' {1..500})"
  printf -- '---\nname: verbose\ndescription: %s\n---\n# v\n' "$long" > "$O/.claude/skills/verbose/SKILL.md"
  out="$(bash "$SCAN" --target "$O")"
  len="$(jq -r '.skills[] | select(.name=="verbose") | .description | length' <<< "$out")"
  [ "$len" -le 300 ]
  [ "$len" -gt 0 ]
}

# Многострочный YAML-блок (description: >-) обязан схлопнуться в одну строку,
# иначе JSON-строка порвёт построчный показ находок.
@test "multiline folded description collapsed to single line" {
  O="$BATS_TEST_TMPDIR/multioffice"
  mkdir -p "$O/.claude/skills/folded"
  printf -- '---\nname: folded\ndescription: >-\n  первая строка блока\n  вторая строка блока\nallowed-tools: Read\n---\n# f\n' \
    > "$O/.claude/skills/folded/SKILL.md"
  out="$(bash "$SCAN" --target "$O")"
  desc="$(jq -r '.skills[] | select(.name=="folded") | .description' <<< "$out")"
  # обе строки блока склеены, allowed-tools НЕ протёк в description
  [[ "$desc" == *"первая строка"* ]]
  [[ "$desc" == *"вторая строка"* ]]
  [[ "$desc" != *"allowed-tools"* ]]
  # ровно одна строка
  [ "$(printf '%s' "$desc" | wc -l | tr -d ' ')" -eq 0 ]
}

# Второй layout агентов: .claude/agents/*.md (basename = имя).
@test "agents from .claude/agents layout by basename" {
  O="$BATS_TEST_TMPDIR/flatagents"
  mkdir -p "$O/.claude/agents"
  printf -- '---\nname: scout\n---\nРазведчик рынка и трендов\n' > "$O/.claude/agents/scout.md"
  out="$(bash "$SCAN" --target "$O")"
  jq -e '.agents | any(.name == "scout" and (.path | test(".claude/agents/scout.md")))' <<< "$out"
}

# Команды проекта, если каталог есть.
@test "commands listed when directory exists" {
  O="$BATS_TEST_TMPDIR/cmdoffice"
  mkdir -p "$O/.claude/commands"
  printf '# deploy\n' > "$O/.claude/commands/deploy.md"
  out="$(bash "$SCAN" --target "$O")"
  jq -e '.commands | index("deploy")' <<< "$out"
}

@test "isolation: not a single byte written into target" {
  before="$(manifest "$TARGET")"
  bash "$SCAN" --target "$TARGET" >/dev/null
  after="$(manifest "$TARGET")"
  [ "$before" = "$after" ]
}

@test "idempotent: two runs produce identical output" {
  a="$(bash "$SCAN" --target "$TARGET")"
  b="$(bash "$SCAN" --target "$TARGET")"
  [ "$a" = "$b" ]
}

# .env чужого офиса не должен ни читаться, ни утекать в вывод.
@test "secrets are never read into output" {
  O="$BATS_TEST_TMPDIR/secretoffice"
  mkdir -p "$O/.claude/skills/plain"
  printf -- '---\nname: plain\ndescription: обычный скилл\n---\n# p\n' > "$O/.claude/skills/plain/SKILL.md"
  printf 'TOKEN=NEVER_READ_MARKER_FIT\n' > "$O/.env"
  printf 'pass=NEVER_READ_MARKER_FIT\n' > "$O/.claude/skills/plain/credentials.txt"
  out="$(bash "$SCAN" --target "$O")"
  ! grep -q "NEVER_READ_MARKER_FIT" <<< "$out"
}
