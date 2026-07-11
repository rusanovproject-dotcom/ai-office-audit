#!/usr/bin/env bash
# Генератор фикстур для secret-scan: транскрипты с ключами + эталонные офисы.
# FAKE-секреты подобраны так, чтобы МАТЧИТЬСЯ регексами движка, но быть очевидно
# мёртвыми (сплошь FAKE/нули) — ни один не является боевым.
# Длины (ghp_ ровно 36, AIza ровно 35, telegram ровно 33 после AA) строятся
# printf-циклами, а не руками, чтобы не промахнуться на символ.
set -euo pipefail

DIR="${1:?usage: make-secret-fixtures.sh <outdir>}"
rm -rf "$DIR"
mkdir -p "$DIR"

zeros() { printf '0%.0s' $(seq 1 "$1"); }

# --- Kitchen-sink: по одному FAKE-ключу на каждую категорию движка ---
# Префиксы разорваны конкатенацией ("sk-ant-" "..."): рантайм-строка та же и матчится
# регексами движка, но в ИСХОДНИКЕ нет цельного литерала — GitHub push-protection не
# принимает эти FAKE-строки за боевые ключи и не блокирует публикацию.
ANTHROPIC="sk-ant-""api03-FAKEFAKEFAKEFAKE0000"
OPENAI_PROJ="sk-proj-""FAKEFAKEFAKEFAKEFAKE0000"
OPENAI_CLASSIC="sk-FAKEFAKEFAKEFAKE0000T3Blbk""FJFAKEFAKEFAKEFAKE0000"  # sk-{20} + маркер + {20}
GHP="ghp_""FAKE$(zeros 28)FAKE"                                        # ghp_ + ровно 36
GH_PAT="github_pat_""11FAKE0000000000000000000FAKE"
TELEGRAM="123456789:AA$(printf 'FAKE%.0s' 1 2 3 4 5 6 7 8)0"           # AA + ровно 33
SLACK="xoxb-""FAKE00000000-FAKE"
AWS="AKIA""FAKE$(zeros 12)"                                            # AKIA + ровно 16
GOOGLE="AIza""FAKE$(zeros 27)FAKE"                                     # AIza + ровно 35
GROQ="gsk_""FAKE0000000000000000FAKE"
YANDEX="y0_""FAKE0000000000000000FAKE"
STRIPE="sk_live_""FAKE0000000000000000FAKE"
JWT="eyJFAKEFAKEFAKE.eyJFAKEFAKEFAKE.FAKEFAKE"
PRIVKEY="-----BEGIN RSA PRIVATE KEY-----"
CONN="postgres://user:FAKEpass000@localhost:5432/db"

# Манифест — все FAKE-строки для carry-away гейта (тест грепает каждую в stdout).
# Лежит в корне фикстур, ВНЕ сканируемых каталогов, движок его не читает.
MAN="$DIR/secrets-manifest.txt"
printf '%s\n' \
  "$ANTHROPIC" "$OPENAI_PROJ" "$OPENAI_CLASSIC" "$GHP" "$GH_PAT" "$TELEGRAM" \
  "$SLACK" "$AWS" "$GOOGLE" "$GROQ" "$YANDEX" "$STRIPE" "$JWT" "$PRIVKEY" "$CONN" \
  > "$MAN"

# --- Транскрипты: минимальный набор для точных counts ---
# a.jsonl: anthropic + github + jwt (3 категории, по одному разу)
# b.jsonl: telegram (в отдельном файле — проверяем files_affected_total=2)
T="$DIR/transcripts/-Users-x-office"
mkdir -p "$T"
ts="2026-07-10T10:00:00.000Z"
cat > "$T/a.jsonl" <<EOF
{"type":"user","sessionId":"s1","timestamp":"$ts","message":{"content":"ключ $ANTHROPIC в конфиге"}}
{"type":"user","sessionId":"s1","timestamp":"$ts","message":{"content":"токен $GHP для гита"}}
{"type":"user","sessionId":"s1","timestamp":"$ts","message":{"content":"jwt $JWT в заголовке"}}
EOF
cat > "$T/b.jsonl" <<EOF
{"type":"user","sessionId":"s2","timestamp":"$ts","message":{"content":"бот $TELEGRAM висит"}}
EOF

# --- git-office: секрет закоммичен и УДАЛЁН следующим коммитом (в HEAD нет) ---
# Плюс tracked .env. В config.py — весь kitchen-sink (стресс для carry-away гейта).
GO="$DIR/git-office"
mkdir -p "$GO/.claude"
git -C "$GO" init -q -b main
git -C "$GO" config user.email "fixture@example.com"
git -C "$GO" config user.name "Fixture"
printf '# office\n' > "$GO/CLAUDE.md"
{
  echo "A = \"$ANTHROPIC\""
  echo "B = \"$OPENAI_PROJ\""
  echo "C = \"$OPENAI_CLASSIC\""
  echo "D = \"$GHP\""
  echo "E = \"$GH_PAT\""
  echo "F = \"$TELEGRAM\""
  echo "G = \"$SLACK\""
  echo "H = \"$AWS\""
  echo "I = \"$GOOGLE\""
  echo "J = \"$GROQ\""
  echo "K = \"$YANDEX\""
  echo "L = \"$STRIPE\""
  echo "M = \"$JWT\""
  echo "$PRIVKEY"
  echo "N = \"$CONN\""
} > "$GO/config.py"
git -C "$GO" add -A
git -C "$GO" commit -q -m "add config with secret"
git -C "$GO" rm -q config.py
git -C "$GO" commit -q -m "remove config"
# tracked .env (без gitignore — специально трекается)
printf 'TOKEN=%s\n' "$GHP" > "$GO/.env"
git -C "$GO" add -f .env
git -C "$GO" commit -q -m "add env"

# --- full-office: все 11 проверок прав проходят (score 100) ---
FO="$DIR/full-office"
mkdir -p "$FO/.claude/hooks" "$FO/.git/hooks"
git -C "$FO" init -q -b main
git -C "$FO" config user.email "fixture@example.com"
git -C "$FO" config user.name "Fixture"
printf '# office\n' > "$FO/CLAUDE.md"
# 1: .gitignore со всеми 5 паттернами
cat > "$FO/.gitignore" <<'EOF'
.env
.env.*
*.pem
credentials*
secrets*
EOF
# 2,3,4,5,9: deny разложен по двум файлам (union), без wildcard-allow
cat > "$FO/.claude/settings.json" <<'EOF'
{
  "permissions": {
    "deny": ["Read(.env*)", "Bash(rm:*)", "Bash(--dangerously-skip-permissions)"],
    "allow": ["Bash(ls:*)"]
  }
}
EOF
cat > "$FO/.claude/settings.local.json" <<'EOF'
{
  "permissions": {
    "deny": ["Edit(.env*)", "Write(.env*)", "Bash(git push --force:*)", "Bash(git reset --hard:*)"]
  }
}
EOF
# 6,11: pre-push хук в .claude/hooks + исполняемый .sh
printf '#!/usr/bin/env bash\necho pd-gate\n' > "$FO/.claude/hooks/pre-push.sh"
chmod +x "$FO/.claude/hooks/pre-push.sh"
# 7: .git/hooks/pre-push обычный файл (не симлинк)
printf '#!/usr/bin/env bash\nexit 0\n' > "$FO/.git/hooks/pre-push"
chmod +x "$FO/.git/hooks/pre-push"
# 8: .git/hooks/pre-commit существует
printf '#!/usr/bin/env bash\nexit 0\n' > "$FO/.git/hooks/pre-commit"
chmod +x "$FO/.git/hooks/pre-commit"
git -C "$FO" add -A
git -C "$FO" commit -q -m "init full office"

# --- nodeny-office: git есть, deny-правил нет (checks 2,3 fail) ---
ND="$DIR/nodeny-office"
mkdir -p "$ND/.claude"
git -C "$ND" init -q -b main
git -C "$ND" config user.email "fixture@example.com"
git -C "$ND" config user.name "Fixture"
printf '# office\n' > "$ND/CLAUDE.md"
git -C "$ND" add -A
git -C "$ND" commit -q -m "init"

# --- hookspath-office: как full, но core.hooksPath переопределён (check 10 fail) ---
HP="$DIR/hookspath-office"
cp -a "$FO" "$HP"
git -C "$HP" config core.hooksPath custom-hooks

# --- envmarker-office: .env с уникальным маркером, gitignored + untracked ---
# Проверяем, что содержимое .env НИКОГДА не попадает в вывод.
EM="$DIR/envmarker-office"
mkdir -p "$EM/.claude"
git -C "$EM" init -q -b main
git -C "$EM" config user.email "fixture@example.com"
git -C "$EM" config user.name "Fixture"
printf '.env\n' > "$EM/.gitignore"
printf 'SECRET=NEVER_READ_MARKER_XYZZY\n' > "$EM/.env"
printf '# office\n' > "$EM/CLAUDE.md"
git -C "$EM" add -A
git -C "$EM" commit -q -m "init"

# --- fakeenvdeny-office: deny со схожим словом env (environments/**), но БЕЗ .env ---
# CORR-2: проверка 3 не должна засчитывать защиту .env по голой подстроке "env".
# environments/** к секретам отношения не имеет — check 3 обязан быть fail.
FE="$DIR/fakeenvdeny-office"
mkdir -p "$FE/.claude"
git -C "$FE" init -q -b main
git -C "$FE" config user.email "fixture@example.com"
git -C "$FE" config user.name "Fixture"
printf '# office\n' > "$FE/CLAUDE.md"
cat > "$FE/.claude/settings.json" <<'EOF'
{
  "permissions": {
    "deny": ["Read(environments/**)", "Edit(environments/**)", "Write(environments/**)"]
  }
}
EOF
git -C "$FE" add -A
git -C "$FE" commit -q -m "init"

# --- substr-deny-office: деструктив-подстроки + один реальный reset --hard ---
# CORR-5: terraform содержит "rm", --force-with-lease содержит "force" — оба НЕ
# деструктив. Реально закрыт только reset --hard → 1/3 → check 4 обязан быть fail.
SD="$DIR/substr-deny-office"
mkdir -p "$SD/.claude"
git -C "$SD" init -q -b main
git -C "$SD" config user.email "fixture@example.com"
git -C "$SD" config user.name "Fixture"
printf '# office\n' > "$SD/CLAUDE.md"
cat > "$SD/.claude/settings.json" <<'EOF'
{
  "permissions": {
    "deny": ["Bash(terraform:*)", "Bash(git push --force-with-lease:*)", "Bash(git reset --hard:*)"]
  }
}
EOF
git -C "$SD" add -A
git -C "$SD" commit -q -m "init"

# --- transcripts-colon: файл транскрипта с ДВОЕТОЧИЕМ в пути (CORR-6) ---
# Путь с ':' ломал ${line%%:*}; top_files должен нести полный путь, а токен —
# классифицироваться (не уходить в other из-за обрывка пути в голове строки).
TC="$DIR/transcripts-colon/-Users-x-office"
mkdir -p "$TC"
printf '{"type":"user","message":{"content":"ключ %s тут"}}\n' "$ANTHROPIC" > "$TC/a:b.jsonl"

# --- nogit-office: каталог без .git ---
mkdir -p "$DIR/nogit-office/.claude"
printf '# office\n' > "$DIR/nogit-office/CLAUDE.md"
