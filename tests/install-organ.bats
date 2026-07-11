#!/usr/bin/env bats
# Встройка «органа» (skill-pack forge) в чужой ~/.claude: install + verify.
# Пишет ТОЛЬКО в --claude-dir, никогда в офис клиента. Не читает .env/secrets.
# Имена тестов латиницей: bats не переваривает кириллицу в @test.
# --separate-stderr: JSON органа идёт в stdout ($output), прогресс — в stderr ($stderr).

bats_require_minimum_version 1.5.0

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  INSTALL="$REPO/engine/install-organ.sh"
  MANIFEST="$REPO/organs/forge-pack/manifest.json"
  SRC="$BATS_TEST_TMPDIR/src"
  bash "$BATS_TEST_DIRNAME/fixtures/make-organ-fixtures.sh" "$SRC"
  CLAUDE="$BATS_TEST_TMPDIR/claude"
  mkdir -p "$CLAUDE"
}

# Пишет installed_plugins.json с указанными идентификаторами плагинов (grep-совместимо).
plugins_file() {
  local dir="$1"; shift
  mkdir -p "$dir/plugins"
  {
    printf '{\n'
    local p
    for p in "$@"; do printf '  "%s": {},\n' "$p"; done
    printf '  "_": {}\n}\n'
  } > "$dir/plugins/installed_plugins.json"
}

@test "install into empty claude-dir places files and reports installed" {
  run --separate-stderr bash "$INSTALL" --organ "$MANIFEST" --claude-dir "$CLAUDE" --source "$SRC"
  [ "$status" -eq 0 ]
  [ -s "$CLAUDE/skills/forge/SKILL.md" ]
  [ -s "$CLAUDE/skills/forge/references/code-cycle.md" ]
  [ -s "$CLAUDE/skills/forge/references/swarm.md" ]
  [ "$(jq -r '.installed' <<< "$output")" = "true" ]
  [ "$(jq -r '.verify.files_ok' <<< "$output")" = "true" ]
  [ "$(jq -r '.verify.frontmatter_ok' <<< "$output")" = "true" ]
}

# Идемпотентность с бэкапом: повторная установка не молчаливо перезаписывает,
# а прячет старое в forge.bak-<ts> рядом — откат клиента возможен.
@test "reinstall over existing forge backs up and stays green" {
  bash "$INSTALL" --organ "$MANIFEST" --claude-dir "$CLAUDE" --source "$SRC" >/dev/null
  run --separate-stderr bash "$INSTALL" --organ "$MANIFEST" --claude-dir "$CLAUDE" --source "$SRC"
  [ "$status" -eq 0 ]
  ls "$CLAUDE/skills/forge.bak-"* >/dev/null
  [ "$(jq -r '.backup' <<< "$output")" != "null" ]
}

# Оба плагина на месте — установка полная, ручных шагов нет.
@test "both plugins present marks plugins_ok and empty manual_steps" {
  plugins_file "$CLAUDE" "superpowers@superpowers-marketplace" "compound-engineering@compound-engineering-plugin"
  run --separate-stderr bash "$INSTALL" --organ "$MANIFEST" --claude-dir "$CLAUDE" --source "$SRC"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.verify.plugins_ok' <<< "$output")" = "true" ]
  [ "$(jq -r '.manual_steps | length' <<< "$output")" -eq 0 ]
}

# Нет файла плагинов — файлы органа всё равно стоят (не фейл), но человеку
# отдаём оба install_hint, чтобы он доставил плагины сам.
@test "missing plugins file yields plugins_ok false and both hints" {
  run --separate-stderr bash "$INSTALL" --organ "$MANIFEST" --claude-dir "$CLAUDE" --source "$SRC"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.installed' <<< "$output")" = "true" ]
  [ "$(jq -r '.verify.plugins_ok' <<< "$output")" = "false" ]
  [ "$(jq -r '.manual_steps | length' <<< "$output")" -eq 2 ]
  jq -e '.manual_steps | any(test("superpowers"))' <<< "$output"
  jq -e '.manual_steps | any(test("compound-engineering"))' <<< "$output"
}

# Один плагин из двух — ровно один install_hint.
@test "one plugin present yields exactly one hint" {
  plugins_file "$CLAUDE" "superpowers@superpowers-marketplace"
  run --separate-stderr bash "$INSTALL" --organ "$MANIFEST" --claude-dir "$CLAUDE" --source "$SRC"
  [ "$(jq -r '.verify.plugins_ok' <<< "$output")" = "false" ]
  [ "$(jq -r '.manual_steps | length' <<< "$output")" -eq 1 ]
  jq -e '.manual_steps | any(test("compound-engineering"))' <<< "$output"
}

# Битый source (нет SKILL.md) — файлы неполные, орган НЕ установлен, exit 1.
@test "broken source without SKILL.md fails install" {
  rm "$SRC/skills/forge/SKILL.md"
  run --separate-stderr bash "$INSTALL" --organ "$MANIFEST" --claude-dir "$CLAUDE" --source "$SRC"
  [ "$status" -eq 1 ]
  [ "$(jq -r '.installed' <<< "$output")" = "false" ]
  [ "$(jq -r '.verify.files_ok' <<< "$output")" = "false" ]
}

# --verify-only не ставит, только проверяет: здоров → 0, после утраты файла → 1.
@test "verify-only passes on healthy install and fails after file removed" {
  bash "$INSTALL" --organ "$MANIFEST" --claude-dir "$CLAUDE" --source "$SRC" >/dev/null
  run --separate-stderr bash "$INSTALL" --verify-only --organ "$MANIFEST" --claude-dir "$CLAUDE"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.verify.files_ok' <<< "$output")" = "true" ]
  rm "$CLAUDE/skills/forge/references/code-cycle.md"
  run --separate-stderr bash "$INSTALL" --verify-only --organ "$MANIFEST" --claude-dir "$CLAUDE"
  [ "$status" -eq 1 ]
  [ "$(jq -r '.verify.files_ok' <<< "$output")" = "false" ]
  jq -e '.verify.missing_files | any(test("code-cycle"))' <<< "$output"
}

# Read-only на уровне поведения: ни байта в офис клиента, только в --claude-dir.
@test "isolation: install writes nothing into target office" {
  office="$BATS_TEST_TMPDIR/target-office"
  mkdir -p "$office/agents/rita"
  printf 'клиентские данные, орган их не трогает\n' > "$office/agents/rita/core.md"
  before="$(find "$office" -type f -exec shasum {} + | shasum)"
  bash "$INSTALL" --organ "$MANIFEST" --claude-dir "$CLAUDE" --source "$SRC" >/dev/null
  after="$(find "$office" -type f -exec shasum {} + | shasum)"
  [ "$before" = "$after" ]
}

@test "output is valid json" {
  out="$(bash "$INSTALL" --organ "$MANIFEST" --claude-dir "$CLAUDE" --source "$SRC")"
  jq -e . <<< "$out"
}

# --- Гейты безопасности (path traversal + git RCE + grep-регекс) ---

# CRIT-2: installs_to с '..' уводит DEST наружу. Source лежит на уровень глубже,
# чтобы SRC_DIR ('../pwned') был РЕАЛЬНЫМ — тогда без гейта эксплойт воспроизводим
# (файл ложится в $BATS_TEST_TMPDIR/pwned вне claude-dir).
@test "relative installs_to with .. is rejected and writes nothing outside claude-dir" {
  srcbase="$BATS_TEST_TMPDIR/deep/src"
  mkdir -p "$srcbase" "$BATS_TEST_TMPDIR/deep/pwned"
  printf 'x\n' > "$BATS_TEST_TMPDIR/deep/pwned/marker"
  man="$BATS_TEST_TMPDIR/evil-rel.json"
  cat > "$man" <<EOF
{ "organ_id":"evil", "installs_to":"../pwned",
  "required_files":["marker"], "source":{}, "required_plugins":[] }
EOF
  run --separate-stderr bash "$INSTALL" --organ "$man" --claude-dir "$CLAUDE" --source "$srcbase"
  [ "$status" -ne 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/pwned" ]
}

# CRIT-2: абсолютный installs_to тоже под запретом (внятная ошибка про installs_to).
@test "absolute installs_to is rejected" {
  planted="$BATS_TEST_TMPDIR/abs-planted"
  man="$BATS_TEST_TMPDIR/evil-abs.json"
  cat > "$man" <<EOF
{ "organ_id":"evil", "installs_to":"$planted",
  "required_files":["SKILL.md"], "source":{}, "required_plugins":[] }
EOF
  run --separate-stderr bash "$INSTALL" --organ "$man" --claude-dir "$CLAUDE" --source "$SRC"
  [ "$status" -ne 0 ]
  [ ! -e "$planted" ]
  [[ "$stderr" == *installs_to* ]]
}

# CRIT-3: враждебный source.git = RCE. ext::-транспорт исполняет код при clone.
# Гейт обязан отказать ДО clone: marker не создан, exit != 0.
@test "ext:: git source is rejected without executing (no RCE)" {
  marker="$BATS_TEST_TMPDIR/pwned-git"
  man="$BATS_TEST_TMPDIR/evil-git.json"
  cat > "$man" <<EOF
{ "organ_id":"evil", "installs_to":"skills/forge",
  "required_files":["SKILL.md"],
  "source":{ "git":"ext::sh -c touch $marker" },
  "required_plugins":[] }
EOF
  run --separate-stderr bash "$INSTALL" --organ "$man" --claude-dir "$CLAUDE"
  [ "$status" -ne 0 ]
  [ ! -e "$marker" ]
}

# Мелкое: grep по installed_plugins.json трактовал grep-строку как regex.
# 'super.powers@' не должен ложно матчить 'superXpowers@' (точка = любой символ).
@test "plugin grep with regex metachar does not falsely match" {
  mkdir -p "$CLAUDE/plugins"
  printf '{ "superXpowers@marketplace": {} }\n' > "$CLAUDE/plugins/installed_plugins.json"
  man="$BATS_TEST_TMPDIR/meta.json"
  cat > "$man" <<EOF
{ "organ_id":"forge-pack", "installs_to":"skills/forge",
  "required_files":["SKILL.md","references/code-cycle.md","references/swarm.md"],
  "source":{}, "required_plugins":[
    { "grep":"super.powers@", "install_hint":"install superpowers" } ] }
EOF
  run --separate-stderr bash "$INSTALL" --organ "$man" --claude-dir "$CLAUDE" --source "$SRC"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.verify.plugins_ok' <<< "$output")" = "false" ]
  [ "$(jq -r '.manual_steps | length' <<< "$output")" -eq 1 ]
}

# L2: source.local с ведущим '~' раскрывается в $HOME (шипабельный манифест без хардкода).
@test "source.local with ~ is expanded to HOME" {
  home="$BATS_TEST_TMPDIR/home"
  mkdir -p "$home"
  cp -R "$SRC" "$home/mypack"
  man="$BATS_TEST_TMPDIR/tilde.json"
  cat > "$man" <<EOF
{ "organ_id":"forge-pack", "installs_to":"skills/forge",
  "required_files":["SKILL.md","references/code-cycle.md","references/swarm.md"],
  "source":{ "local":"~/mypack" }, "required_plugins":[] }
EOF
  run --separate-stderr env HOME="$home" bash "$INSTALL" --organ "$man" --claude-dir "$CLAUDE"
  [ "$status" -eq 0 ]
  [ -s "$CLAUDE/skills/forge/SKILL.md" ]
}
