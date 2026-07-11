#!/usr/bin/env bash
# Генератор фикстур-офисов для модулей бэкапа и readonly-гейта.
# Три эталонных офиса, которые понадобятся и следующим модулям.
# Живой офис почти всегда грязный — поэтому folder-per-agent специально
# оставляется с незакоммиченной правкой и untracked-файлом: слепок ОБЯЗАН
# уметь их восстанавливать.
set -euo pipefail

DIR="${1:?usage: make-office-fixtures.sh <outdir>}"
rm -rf "$DIR"
mkdir -p "$DIR"

# --- 1. folder-per-agent: папка-на-агента + живой (грязный) git ---
O="$DIR/folder-per-agent"
mkdir -p "$O/office/agents/director" "$O/office/agents/rita"
printf '# Office\n\nКанон офиса.\n' > "$O/CLAUDE.md"
printf '# Agents\n\ndirector, rita\n' > "$O/office/AGENTS.md"
printf '# Director core\n' > "$O/office/agents/director/core.md"
printf '# Rita core\n' > "$O/office/agents/rita/core.md"

# Арсенал офиса: скиллы и хук. Нужны модулю инвентаря арсенала (arsenal-scan).
# Кладём ДО коммита — это канон офиса, а не грязь.
mkdir -p "$O/.claude/skills/hormozi" "$O/.claude/skills/broken" "$O/.claude/hooks"
printf -- '---\nname: hormozi\ndescription: Конструктор офферов от которых невозможно отказаться\nallowed-tools: Read\n---\n\n# hormozi\n' \
  > "$O/.claude/skills/hormozi/SKILL.md"
# Битый frontmatter: нет name, нет description. Движок обязан не упасть и дать
# name=имя папки (broken), description="".
printf -- '---\nallowed-tools: Read\n# незакрытый и без name\n\n# broken skill\n' \
  > "$O/.claude/skills/broken/SKILL.md"
printf '#!/usr/bin/env bash\necho hook\n' > "$O/.claude/hooks/x.sh"
chmod +x "$O/.claude/hooks/x.sh"

git -C "$O" init -q -b main
# user.email/name — локально в репо, чтобы не зависеть от глобального git-конфига машины
git -C "$O" config user.email "fixture@example.com"
git -C "$O" config user.name "Fixture Office"
git -C "$O" add -A
git -C "$O" commit -q -m "init office"

# Незакоммиченная правка отслеживаемого файла — маркер, который слепок обязан сохранить.
printf '\nДописка, которую слепок обязан сохранить.\n' >> "$O/CLAUDE.md"
# Untracked-файл — git-ветка бы его не поймала, а cp -a ловит.
printf 'черновые заметки\n' > "$O/office/notes.md"

# --- 2. bare-claude: только CLAUDE.md, без git ---
B="$DIR/bare-claude"
mkdir -p "$B"
printf '# Bare office\n' > "$B/CLAUDE.md"

# --- 3. empty: пустой каталог ---
mkdir -p "$DIR/empty"
