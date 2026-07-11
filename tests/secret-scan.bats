#!/usr/bin/env bats
# Движок сканера секретов: три зоны (транскрипты / git-история / права).
# ЖЕЛЕЗНОЕ ПРАВИЛО продукта: тела секретов НИКОГДА не в выводе — только категории,
# счётчики и пути. Отдельный carry-away гейт грепает каждый FAKE-ключ в stdout.
# Имена тестов латиницей: bats не переваривает кириллицу в @test.

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCAN="$REPO/engine/secret-scan.sh"
  FIX="$BATS_TEST_TMPDIR/fix"
  bash "$BATS_TEST_DIRNAME/fixtures/make-secret-fixtures.sh" "$FIX"
  TRANS="$FIX/transcripts"
  MAN="$FIX/secrets-manifest.txt"
}

# --- Зона 1: транскрипты ---

@test "transcripts: exact hits and files per category" {
  out="$(bash "$SCAN" --transcripts "$TRANS")"
  [ "$(jq -r '.zones.transcripts.by_category.anthropic.hits' <<< "$out")" -eq 1 ]
  [ "$(jq -r '.zones.transcripts.by_category.anthropic.files' <<< "$out")" -eq 1 ]
  [ "$(jq -r '.zones.transcripts.by_category.github.hits' <<< "$out")" -eq 1 ]
  [ "$(jq -r '.zones.transcripts.by_category.jwt.hits' <<< "$out")" -eq 1 ]
  [ "$(jq -r '.zones.transcripts.by_category.telegram_bot.hits' <<< "$out")" -eq 1 ]
  [ "$(jq -r '.zones.transcripts.by_category.telegram_bot.files' <<< "$out")" -eq 1 ]
}

@test "transcripts: files_affected_total counts distinct files" {
  out="$(bash "$SCAN" --transcripts "$TRANS")"
  [ "$(jq -r '.zones.transcripts.files_affected_total' <<< "$out")" -eq 2 ]
}

@test "transcripts: top_files carries paths only" {
  out="$(bash "$SCAN" --transcripts "$TRANS")"
  [ "$(jq -r '.zones.transcripts.top_files | length' <<< "$out")" -ge 1 ]
  jq -e '.zones.transcripts.top_files[0] | has("path") and has("hits")' <<< "$out"
}

# CORR-6: двоеточие в пути транскрипта не должно рвать разбор path:token.
@test "transcripts: colon in file path keeps path and category intact" {
  out="$(bash "$SCAN" --transcripts "$FIX/transcripts-colon")"
  [ "$(jq -r '.zones.transcripts.files_affected_total' <<< "$out")" -eq 1 ]
  [ "$(jq -r '.zones.transcripts.by_category.anthropic.hits' <<< "$out")" -eq 1 ]
  p="$(jq -r '.zones.transcripts.top_files[0].path' <<< "$out")"
  [[ "$p" == *"a:b.jsonl" ]]
}

# --- CARRY-AWAY GATE (критический): тело секрета не должно утекать ---

@test "carry-away gate: no fake secret body in full stdout" {
  out="$(bash "$SCAN" --target "$FIX/git-office" --transcripts "$TRANS" --zones transcripts,git,rights)"
  while IFS= read -r secret; do
    [ -n "$secret" ] || continue
    run grep -F -- "$secret" <<< "$out"
    [ "$status" -ne 0 ]   # grep не нашёл — тела секрета в выводе НЕТ
  done < "$MAN"
}

@test "carry-away gate: no fake secret body with zones=git" {
  out="$(bash "$SCAN" --target "$FIX/git-office" --zones git)"
  while IFS= read -r secret; do
    [ -n "$secret" ] || continue
    run grep -F -- "$secret" <<< "$out"
    [ "$status" -ne 0 ]
  done < "$MAN"
}

@test "carry-away gate: no fake secret body with zones=rights" {
  out="$(bash "$SCAN" --target "$FIX/full-office" --zones rights)"
  while IFS= read -r secret; do
    [ -n "$secret" ] || continue
    run grep -F -- "$secret" <<< "$out"
    [ "$status" -ne 0 ]
  done < "$MAN"
}

# --- Зона 2: git-история ---

@test "git history: finds secret deleted in a later commit" {
  out="$(bash "$SCAN" --target "$FIX/git-office" --zones git)"
  [ "$(jq -r '.zones.git_history.by_category.anthropic.hits' <<< "$out")" -ge 1 ]
}

@test "git history: tracked .env listed in tracked_env_files" {
  out="$(bash "$SCAN" --target "$FIX/git-office" --zones git)"
  jq -e '.zones.git_history.tracked_env_files | any(test("\\.env"))' <<< "$out"
}

@test "git history: skipped when target has no git repo" {
  out="$(bash "$SCAN" --target "$FIX/nogit-office" --zones git)"
  jq -e '.zones.git_history | has("skipped")' <<< "$out"
}

# --- Зона 3: права/хуки ---

@test "rights: nodeny office fails deny checks 2 and 3" {
  out="$(bash "$SCAN" --target "$FIX/nodeny-office" --zones rights)"
  [ "$(jq -r '.zones.rights.checks[] | select(.id==2) | .status' <<< "$out")" = "fail" ]
  [ "$(jq -r '.zones.rights.checks[] | select(.id==3) | .status' <<< "$out")" = "fail" ]
}

@test "rights: full office passes all checks with score 100" {
  out="$(bash "$SCAN" --target "$FIX/full-office" --zones rights)"
  [ "$(jq -r '.zones.rights.rights_score' <<< "$out")" -eq 100 ]
  [ "$(jq -r '.zones.rights.checks[] | select(.id==1) | .status' <<< "$out")" = "pass" ]
  [ "$(jq -r '.zones.rights.checks[] | select(.id==7) | .status' <<< "$out")" = "pass" ]
}

# CORR-2: environments/** содержит "env", но к .env-секретам не относится → check 3 fail.
@test "rights: deny with environments/** (no real .env) fails check 3" {
  out="$(bash "$SCAN" --target "$FIX/fakeenvdeny-office" --zones rights)"
  [ "$(jq -r '.zones.rights.checks[] | select(.id==3) | .status' <<< "$out")" = "fail" ]
}

# CORR-5: terraform/--force-with-lease — не деструктив; закрыт только reset --hard → check 4 fail.
@test "rights: substring destructive (terraform/force-with-lease) fails check 4" {
  out="$(bash "$SCAN" --target "$FIX/substr-deny-office" --zones rights)"
  [ "$(jq -r '.zones.rights.checks[] | select(.id==4) | .status' <<< "$out")" = "fail" ]
}

@test "rights: core.hooksPath override fails check 10" {
  out="$(bash "$SCAN" --target "$FIX/hookspath-office" --zones rights)"
  [ "$(jq -r '.zones.rights.checks[] | select(.id==10) | .status' <<< "$out")" = "fail" ]
}

@test "rights: broken settings json marks check 2 fail with invalid json note" {
  broke="$BATS_TEST_TMPDIR/broke"; mkdir -p "$broke/.claude"
  printf '# office\n' > "$broke/CLAUDE.md"
  printf '{ this is not json' > "$broke/.claude/settings.json"
  out="$(bash "$SCAN" --target "$broke" --zones rights)"
  [ "$(jq -r '.zones.rights.checks[] | select(.id==2) | .status' <<< "$out")" = "fail" ]
  jq -e '.zones.rights.checks[] | select(.id==2) | .note | test("invalid json")' <<< "$out"
}

# --- Приватность: .env не читается ---

@test "env file body is never read into output" {
  out="$(bash "$SCAN" --target "$FIX/envmarker-office" --transcripts "$TRANS")"
  run grep -F -- "NEVER_READ_MARKER_XYZZY" <<< "$out"
  [ "$status" -ne 0 ]
}

# --- Read-only / изоляция ---

@test "isolation: engine writes nothing into target or transcripts" {
  # Манифест включает путь + контент + mtime — ловит и новые файлы, и mtime-only
  # записи (optional locks / refresh index в .git при не-read-only git-вызовах).
  manifest() {
    find "$1" -type f 2>/dev/null | sort | while IFS= read -r f; do
      printf '%s ' "$f"
      shasum "$f" 2>/dev/null | awk '{print $1}'
      stat -f '%m' "$f" 2>/dev/null || stat -c '%Y' "$f" 2>/dev/null
      printf '\n'
    done | shasum
  }
  gitlist() { find "$1/.git" -type f 2>/dev/null | sort | shasum; }
  bt="$(manifest "$FIX/full-office")"; bs="$(manifest "$TRANS")"; bg="$(gitlist "$FIX/full-office")"
  bash "$SCAN" --target "$FIX/full-office" --transcripts "$TRANS" >/dev/null
  at="$(manifest "$FIX/full-office")"; as="$(manifest "$TRANS")"; ag="$(gitlist "$FIX/full-office")"
  [ "$bt" = "$at" ]
  [ "$bs" = "$as" ]
  [ "$bg" = "$ag" ]   # никаких новых/удалённых файлов в .git
}

@test "idempotent: two runs identical except generated field" {
  a="$(bash "$SCAN" --target "$FIX/full-office" --transcripts "$TRANS" | jq 'del(.generated)')"
  b="$(bash "$SCAN" --target "$FIX/full-office" --transcripts "$TRANS" | jq 'del(.generated)')"
  [ "$a" = "$b" ]
}

# --- Пропуски зон и валидность вывода ---

@test "no target: git and rights zones skipped, exit 0" {
  run bash "$SCAN" --transcripts "$TRANS"
  [ "$status" -eq 0 ]
  jq -e '.zones.git_history | has("skipped")' <<< "$output"
  jq -e '.zones.rights | has("skipped")' <<< "$output"
}

@test "target without git: git zone skipped, exit 0" {
  run bash "$SCAN" --target "$FIX/nogit-office" --transcripts "$TRANS"
  [ "$status" -eq 0 ]
  jq -e '.zones.git_history | has("skipped")' <<< "$output"
}

@test "output is always valid json" {
  bash "$SCAN" --target "$FIX/full-office" --transcripts "$TRANS" | jq . >/dev/null
}
