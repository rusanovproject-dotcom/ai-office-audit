#!/usr/bin/env bats
# Резолвер корня пака: /audit-* находят engine/ из ДОВЕРЕННОГО клона, из любой рабочей папки,
# и НЕ дают недоверенному чужому офису подсунуть свой engine/ (marker-spoofing → RCE).
# Канон — tests/fixtures/resolve-root.sh; исполняемые строки дословно вшиты в каждый SKILL.md.
# Имена тестов латиницей: bats не переваривает кириллицу в @test.

bats_require_minimum_version 1.5.0

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SKILLS="$REPO/.claude/skills"
  RESOLVER="$REPO/tests/fixtures/resolve-root.sh"
  # pwd -P снимает /var→/private/var симлинк macOS, иначе сравнение путей врёт.
  TMP="$(cd "$(mktemp -d)" && pwd -P)"
  export HOME="$TMP/home"
  mkdir -p "$HOME"
}

teardown() {
  [ -n "${TMP:-}" ] && rm -rf "$TMP"
}

# Легитимный клон пака в $1: маркер + engine + git origin = наш ai-office-audit.
make_pack() {
  local root="$1"
  mkdir -p "$root/engine" "$root/.claude/skills/audit-security"
  : > "$root/.ai-office-audit"
  printf '#!/usr/bin/env bash\necho ok\n' > "$root/engine/secret-scan.sh"
  chmod +x "$root/engine/secret-scan.sh"
  ( cd "$root" && git init -q && git config remote.origin.url \
      "https://github.com/rusanovproject-dotcom/ai-office-audit.git" )
}

# Недоверенный «чужой офис» в $1: подделанный маркер + троянский engine + ЧУЖОЙ git origin.
make_evil() {
  local root="$1"
  mkdir -p "$root/engine"
  : > "$root/.ai-office-audit"
  printf '#!/usr/bin/env bash\necho PWNED\n' > "$root/engine/secret-scan.sh"
  chmod +x "$root/engine/secret-scan.sh"
  ( cd "$root" && git init -q && git config remote.origin.url \
      "https://github.com/attacker/totally-legit-office.git" )
}

# Извлечь первый ```bash-блок (это Шаг 0) из SKILL.md.
extract_block() {
  awk '/^```bash$/{f=1;next} f&&/^```$/{exit} f{print}' "$1"
}
# Оставить только исполняемые строки (без комментариев и пустых).
norm() { grep -vE '^[[:space:]]*#' | grep -vE '^[[:space:]]*$'; }

# --- маркер и канон на месте ---

@test "pack root marker .ai-office-audit exists and is tracked" {
  [ -f "$REPO/.ai-office-audit" ]
  run git -C "$REPO" ls-files --error-unmatch .ai-office-audit
  [ "$status" -eq 0 ]
}

@test "canonical resolver fixture exists" {
  [ -f "$RESOLVER" ]
}

# --- логика: резолвится из доверенного клона, из любой папки внутри него ---

@test "resolves from pack root (git origin verified)" {
  make_pack "$TMP/pack"
  run bash -c "cd '$TMP/pack' && source '$RESOLVER' >/dev/null 2>&1 && pwd -P"
  [ "$status" -eq 0 ]
  [ "$output" = "$TMP/pack" ]
}

@test "resolves from a deep subdir of the clone" {
  make_pack "$TMP/pack"
  run bash -c "cd '$TMP/pack/.claude/skills/audit-security' && source '$RESOLVER' >/dev/null 2>&1 && pwd -P"
  [ "$status" -eq 0 ]
  [ "$output" = "$TMP/pack" ]
}

@test "resolves from the engine subdir of the clone" {
  make_pack "$TMP/pack"
  run bash -c "cd '$TMP/pack/engine' && source '$RESOLVER' >/dev/null 2>&1 && pwd -P"
  [ "$status" -eq 0 ]
  [ "$output" = "$TMP/pack" ]
}

@test "resolves via trusted HOME clone when cwd is unrelated" {
  make_pack "$HOME/ai-office-audit"
  mkdir -p "$TMP/elsewhere"
  run bash -c "cd '$TMP/elsewhere' && source '$RESOLVER' >/dev/null 2>&1 && pwd -P"
  [ "$status" -eq 0 ]
  [ "$output" = "$HOME/ai-office-audit" ]
}

# --- adversarial: недоверенный офис не должен победить ---

@test "SECURITY: trusted HOME clone wins over a spoofed marker in cwd (evil office)" {
  make_pack "$HOME/ai-office-audit"
  make_evil "$TMP/evil-office"
  run bash -c "cd '$TMP/evil-office' && source '$RESOLVER' >/dev/null 2>&1 && pwd -P"
  [ "$status" -eq 0 ]
  [ "$output" = "$HOME/ai-office-audit" ]      # НЕ evil-office
  [ "$output" != "$TMP/evil-office" ]
}

@test "SECURITY: refuses a spoofed marker with foreign git origin (no trusted clone)" {
  make_evil "$TMP/evil-office"                 # $HOME пуст — доверенного клона нет
  run bash -c "cd '$TMP/evil-office' && source '$RESOLVER'"
  [ "$status" -ne 0 ]                          # не запустился
  echo "$output" | grep -qi "не найден"
}

@test "SECURITY: refuses a spoofed marker in a non-git directory" {
  mkdir -p "$TMP/evil-nogit"
  : > "$TMP/evil-nogit/.ai-office-audit"
  printf '#!/usr/bin/env bash\necho PWNED\n' > "$TMP/evil-nogit/secret-scan.sh"
  run bash -c "cd '$TMP/evil-nogit' && source '$RESOLVER'"
  [ "$status" -ne 0 ]
}

@test "fails clearly from a bare directory with no pack anywhere" {
  mkdir -p "$TMP/bare"
  run bash -c "cd '$TMP/bare' && source '$RESOLVER'"
  [ "$status" -ne 0 ]
}

# --- drift-guard: вшитый блок ПОБАЙТОВО == канон (исполняемые строки) ---

@test "each audit skill embeds the canonical resolver verbatim (executable lines)" {
  local fix blk
  fix="$(norm < "$RESOLVER")"
  for s in audit-security audit-fit audit-dev audit-memory; do
    blk="$(extract_block "$SKILLS/$s/SKILL.md" | norm)"
    if [ "$blk" != "$fix" ]; then
      echo "DRIFT between fixture and $s:"
      diff <(printf '%s\n' "$fix") <(printf '%s\n' "$blk") || true
      return 1
    fi
  done
}

# --- поведение РЕАЛЬНО вшитого блока (не только фикстуры) ---

@test "the block shipped inside audit-security SKILL.md actually resolves" {
  make_pack "$TMP/pack"
  extract_block "$SKILLS/audit-security/SKILL.md" > "$TMP/shipped.sh"
  run bash -c "cd '$TMP/pack' && source '$TMP/shipped.sh' >/dev/null 2>&1 && pwd -P"
  [ "$status" -eq 0 ]
  [ "$output" = "$TMP/pack" ]
}
