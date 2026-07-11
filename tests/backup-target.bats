#!/usr/bin/env bats
# Контентный слепок чужого офиса: cp -a содержимого (НЕ git-ветка), потому что
# git-ветка пишет в чужой .git и не ловит незакоммиченное. Слепок обязан
# восстанавливать офис включая незакоммиченные правки и untracked-файлы.
# Имена тестов латиницей: bats не переваривает кириллицу в @test.

bats_require_minimum_version 1.5.0   # для run --separate-stderr

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  BACKUP="$REPO/engine/backup-target.sh"
  OFFICES="$BATS_TEST_TMPDIR/offices"
  bash "$BATS_TEST_DIRNAME/fixtures/make-office-fixtures.sh" "$OFFICES"
  TARGET="$OFFICES/folder-per-agent"
  SNAPROOT="$BATS_TEST_TMPDIR/snaps"
}

# sha-манифест каталога: пути относительно корня, чтобы можно было сравнивать
# и «до/после» (изоляция), и «target vs tree» (восстановление один-в-один).
manifest() { ( cd "$1" && find . -type f -exec shasum {} + | sort ); }

@test "backup creates snapshot tree and meta, path on stdout" {
  run bash "$BACKUP" --target "$TARGET" --snapshots-root "$SNAPROOT"
  [ "$status" -eq 0 ]
  snap="$(echo "$output" | tail -n1)"
  [ -d "$snap/tree" ]
  [ -f "$snap/meta.json" ]
  [ -f "$snap/tree/CLAUDE.md" ]
  # .git обязан попасть в слепок целиком
  [ -d "$snap/tree/.git" ]
  run jq -r '.source' "$snap/meta.json"
  [ "$output" = "$(cd "$TARGET" && pwd -P)" ]
}

# Изоляция на уровне поведения: ни байта в чужой офис. Ловушка — git status,
# который по умолчанию рефрешит .git/index. Движок обязан этого избежать.
@test "isolation: not a single byte written into target during backup" {
  before="$(manifest "$TARGET")"
  bash "$BACKUP" --target "$TARGET" --snapshots-root "$SNAPROOT" >/dev/null
  after="$(manifest "$TARGET")"
  [ "$before" = "$after" ]
}

@test "dirty git warns on stderr but still snapshots uncommitted and untracked" {
  run --separate-stderr bash "$BACKUP" --target "$TARGET" --snapshots-root "$SNAPROOT"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *грязн* ]]
  snap="$(echo "$output" | tail -n1)"
  run jq -r '.git_dirty' "$snap/meta.json"
  [ "$output" = "true" ]
  # незакоммиченная дописка отслеживаемого файла попала в слепок
  grep -q "Дописка" "$snap/tree/CLAUDE.md"
  # untracked-файл попал в слепок
  [ -f "$snap/tree/office/notes.md" ]
}

@test "no git in target is not an error" {
  run bash "$BACKUP" --target "$OFFICES/bare-claude" --snapshots-root "$SNAPROOT"
  [ "$status" -eq 0 ]
  snap="$(echo "$output" | tail -n1)"
  run jq -r '.git_dirty' "$snap/meta.json"
  [ "$output" = "false" ]
}

# Восстановление на грязном дереве: возвращает изменённое, восстанавливает
# незакоммиченное и удаляет всё, что появилось после слепка (rsync --delete).
@test "restore returns target byte-for-byte to snapshot including deletions" {
  snap="$(bash "$BACKUP" --target "$TARGET" --snapshots-root "$SNAPROOT" | tail -n1)"
  before="$(manifest "$TARGET")"
  echo "порча" >> "$TARGET/CLAUDE.md"
  rm "$TARGET/office/agents/rita/core.md"
  echo "лишний" > "$TARGET/office/garbage.md"
  bash "$BACKUP" --restore "$snap" --target "$TARGET"
  after="$(manifest "$TARGET")"
  [ "$before" = "$after" ]
  # добавленный после слепка файл исчез
  [ ! -f "$TARGET/office/garbage.md" ]
  # незакоммиченная правка восстановлена: Дописка есть, порчи нет
  grep -q "Дописка" "$TARGET/CLAUDE.md"
  ! grep -q "порча" "$TARGET/CLAUDE.md"
  # удалённый файл вернулся
  [ -f "$TARGET/office/agents/rita/core.md" ]
}

@test "restore refuses when meta source differs from target unless forced" {
  snap="$(bash "$BACKUP" --target "$TARGET" --snapshots-root "$SNAPROOT" | tail -n1)"
  other="$OFFICES/bare-claude"
  run bash "$BACKUP" --restore "$snap" --target "$other"
  [ "$status" -ne 0 ]
  run bash "$BACKUP" --restore "$snap" --target "$other" --force
  [ "$status" -eq 0 ]
}

@test "restore refuses when snapshot has no tree" {
  mkdir -p "$SNAPROOT/bogus"
  printf '{"source":"%s"}\n' "$(cd "$TARGET" && pwd -P)" > "$SNAPROOT/bogus/meta.json"
  run bash "$BACKUP" --restore "$SNAPROOT/bogus" --target "$TARGET"
  [ "$status" -ne 0 ]
}

@test "two backups in a row produce two distinct snapshot dirs" {
  s1="$(bash "$BACKUP" --target "$TARGET" --snapshots-root "$SNAPROOT" | tail -n1)"
  s2="$(bash "$BACKUP" --target "$TARGET" --snapshots-root "$SNAPROOT" | tail -n1)"
  [ "$s1" != "$s2" ]
  [ -d "$s1/tree" ]
  [ -d "$s2/tree" ]
}

@test "restore is idempotent: running twice yields the same state" {
  snap="$(bash "$BACKUP" --target "$TARGET" --snapshots-root "$SNAPROOT" | tail -n1)"
  echo "порча" >> "$TARGET/CLAUDE.md"
  bash "$BACKUP" --restore "$snap" --target "$TARGET"
  a="$(manifest "$TARGET")"
  bash "$BACKUP" --restore "$snap" --target "$TARGET"
  b="$(manifest "$TARGET")"
  [ "$a" = "$b" ]
}

# Сокеты/fifo в target: cp -a может ругаться. Движок не должен из-за них падать.
@test "backup does not fail on a fifo in target" {
  mkfifo "$TARGET/pipe"
  run bash "$BACKUP" --target "$TARGET" --snapshots-root "$SNAPROOT"
  [ "$status" -eq 0 ]
  snap="$(echo "$output" | tail -n1)"
  [ -d "$snap/tree" ]
  [ -f "$snap/tree/CLAUDE.md" ]
}

# HIGH-4: пустой tree/ при restore. Это путь ОТКАТА после сорванной мутации —
# худший момент для wipe. Пустой слепок (cp ничего не скопировал / подделка) не
# должен стереть офис через rsync --delete. Отказ, target не тронут.
@test "restore refuses empty snapshot tree and does not wipe target" {
  before="$(manifest "$TARGET")"
  mkdir -p "$SNAPROOT/empty-snap/tree"
  printf '{"source":"%s"}\n' "$(cd "$TARGET" && pwd -P)" > "$SNAPROOT/empty-snap/meta.json"
  run bash "$BACKUP" --restore "$SNAPROOT/empty-snap" --target "$TARGET"
  [ "$status" -ne 0 ]
  # офис на месте — ни один файл не стёрт
  [ -f "$TARGET/CLAUDE.md" ]
  after="$(manifest "$TARGET")"
  [ "$before" = "$after" ]
}

# HIGH-4: sanity — снапшот с одним файлом против «полного» target. Абсурдно
# полупустой слепок → отказ (подозрение на порчу). --force продавливает.
@test "restore refuses snapshot drastically smaller than target unless forced" {
  snap="$(bash "$BACKUP" --target "$TARGET" --snapshots-root "$SNAPROOT" | tail -n1)"
  # имитируем порчу слепка: оставляем в tree один файл
  find "$snap/tree" -mindepth 1 -maxdepth 1 ! -name CLAUDE.md -exec rm -rf {} +
  run bash "$BACKUP" --restore "$snap" --target "$TARGET"
  [ "$status" -ne 0 ]
  [ -f "$TARGET/office/AGENTS.md" ]   # офис не тронут
  # но с --force оператор может продавить
  run bash "$BACKUP" --restore "$snap" --target "$TARGET" --force
  [ "$status" -eq 0 ]
}

# HIGH-3: симлинк внутри офиса, указывающий ЗА пределы офиса (карточки клиентов →
# ~/office-data). cp -a копирует ссылку, а не данные — они вне слепка. Движок
# обязан ГРОМКО предупредить и записать список в meta.json.external_symlinks.
@test "backup warns and records external symlinks in meta" {
  external="$BATS_TEST_TMPDIR/office-data"
  mkdir -p "$external"
  printf 'секретные карточки клиентов\n' > "$external/clients.md"
  ln -s "$external" "$TARGET/client-data"
  run --separate-stderr bash "$BACKUP" --target "$TARGET" --snapshots-root "$SNAPROOT"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *симлинк* || "$stderr" == *symlink* ]]
  snap="$(echo "$output" | tail -n1)"
  run jq -r '.external_symlinks | length' "$snap/meta.json"
  [ "$output" -ge 1 ]
  run jq -e '.external_symlinks | any(. == "client-data" or endswith("client-data"))' "$snap/meta.json"
  [ "$status" -eq 0 ]
}

# MED-6: перед cp -a всего дерева (incl .git) движок оценивает размер target и
# свободное место. Если места мало — внятный отказ, а не битый частичный слепок.
# Порог свободного места переопределяем через env для детерминированного теста.
@test "backup refuses when free disk space is insufficient" {
  run env BACKUP_MIN_FREE_KB=999999999999 bash "$BACKUP" --target "$TARGET" --snapshots-root "$SNAPROOT"
  [ "$status" -ne 0 ]
  [[ "$output$stderr" == *мест* || "$output" == *space* ]]
  # частичный слепок не оставлен
  [ -z "$(ls -A "$SNAPROOT" 2>/dev/null || true)" ]
}

# Симлинк ВНУТРИ офиса (относительный, резолвится внутри target) — это норма,
# не должен попадать в external_symlinks и не должен поднимать тревогу.
@test "backup does not flag internal symlinks as external" {
  mkdir -p "$TARGET/office/real"
  printf 'данные\n' > "$TARGET/office/real/data.md"
  ln -s "real/data.md" "$TARGET/office/link.md"
  run bash "$BACKUP" --target "$TARGET" --snapshots-root "$SNAPROOT"
  [ "$status" -eq 0 ]
  snap="$(echo "$output" | tail -n1)"
  run jq -r '.external_symlinks | length' "$snap/meta.json"
  [ "$output" -eq 0 ]
}
