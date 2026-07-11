#!/usr/bin/env bash
# Генератор фейкового source-пака (мини-копия структуры forge-pack).
# НЕ копируем реальный контент forge — verify проверяет НАЛИЧИЕ файлов и `name:` во
# frontmatter, поэтому трёх строк-заглушек достаточно и тест не зависит от живого пака.
set -euo pipefail

DIR="${1:?usage: make-organ-fixtures.sh <src-dir>}"
rm -rf "$DIR"
mkdir -p "$DIR/skills/forge/references"

# SKILL.md с валидным frontmatter (есть name:) — этого ждёт ветка verify
cat > "$DIR/skills/forge/SKILL.md" <<'EOF'
---
name: forge
description: fake forge skill for tests
---
# forge (stub)
EOF

printf 'code-cycle stub\n' > "$DIR/skills/forge/references/code-cycle.md"
printf 'swarm stub\n'      > "$DIR/skills/forge/references/swarm.md"
