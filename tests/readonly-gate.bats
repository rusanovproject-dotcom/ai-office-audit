#!/usr/bin/env bats
# PreToolUse-хук: блокирует запись в аудируемый чужой офис (target).
# Контракт хука: на stdin JSON {"tool_name":"Write","tool_input":{...}}.
# Блок = exit 2 + причина в stderr (её видит модель). Разрешить = exit 0.
# Цена ошибки = порча чужого офиса, поэтому композитные/пишущие Bash — блокируем.
# Имена тестов латиницей: bats не переваривает кириллицу в @test.

bats_require_minimum_version 1.5.0   # для run --separate-stderr

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  GATE="$REPO/hooks/readonly-gate.sh"
  OFFICES="$BATS_TEST_TMPDIR/offices"
  bash "$BATS_TEST_DIRNAME/fixtures/make-office-fixtures.sh" "$OFFICES"
  TARGET="$(cd "$OFFICES/folder-per-agent" && pwd -P)"
  # state/-файлы — во временный каталог: скрипт берёт их из OU_STATE_DIR.
  export OU_STATE_DIR="$BATS_TEST_TMPDIR/state"
  mkdir -p "$OU_STATE_DIR"
}

# гейт получает JSON вызова инструмента на stdin
gate() { printf '%s' "$1" | bash "$GATE"; }
# активировать защиту: записать путь target в state
activate() { printf '%s\n' "$TARGET" > "$OU_STATE_DIR/target.path"; }

@test "no target path file means gate is inactive and allows" {
  json='{"tool_name":"Write","tool_input":{"file_path":"'"$TARGET"'/CLAUDE.md"}}'
  run gate "$json"
  [ "$status" -eq 0 ]
}

@test "write inside target is blocked with a reason on stderr" {
  activate
  json='{"tool_name":"Write","tool_input":{"file_path":"'"$TARGET"'/office/AGENTS.md"}}'
  run --separate-stderr gate "$json"
  [ "$status" -eq 2 ]
  [ -n "$stderr" ]
}

@test "write outside target is allowed" {
  activate
  json='{"tool_name":"Write","tool_input":{"file_path":"'"$BATS_TEST_TMPDIR"'/elsewhere.md"}}'
  run gate "$json"
  [ "$status" -eq 0 ]
}

@test "edit inside target is blocked" {
  activate
  json='{"tool_name":"Edit","tool_input":{"file_path":"'"$TARGET"'/CLAUDE.md"}}'
  run gate "$json"
  [ "$status" -eq 2 ]
}

@test "notebook edit inside target is blocked" {
  activate
  json='{"tool_name":"NotebookEdit","tool_input":{"file_path":"'"$TARGET"'/nb.ipynb"}}'
  run gate "$json"
  [ "$status" -eq 2 ]
}

@test "bash rm inside target is blocked" {
  activate
  json='{"tool_name":"Bash","tool_input":{"command":"rm -rf '"$TARGET"'/office"}}'
  run gate "$json"
  [ "$status" -eq 2 ]
}

@test "bash ls of target is allowed by read-only allowlist" {
  activate
  json='{"tool_name":"Bash","tool_input":{"command":"ls '"$TARGET"'"}}'
  run gate "$json"
  [ "$status" -eq 0 ]
}

@test "bash read with redirect is blocked even inside allowlist command" {
  activate
  json='{"tool_name":"Bash","tool_input":{"command":"cat '"$TARGET"'/CLAUDE.md > /tmp/x"}}'
  run gate "$json"
  [ "$status" -eq 2 ]
}

@test "bash git status of target is allowed" {
  activate
  json='{"tool_name":"Bash","tool_input":{"command":"git -C '"$TARGET"' status"}}'
  run gate "$json"
  [ "$status" -eq 0 ]
}

# git remote -v — read-only, но git remote add пишет в чужой .git/config → блок
@test "bash git remote add inside target is blocked" {
  activate
  json='{"tool_name":"Bash","tool_input":{"command":"git -C '"$TARGET"' remote add up http://x"}}'
  run gate "$json"
  [ "$status" -eq 2 ]
}

@test "bash git remote -v is allowed" {
  activate
  json='{"tool_name":"Bash","tool_input":{"command":"git -C '"$TARGET"' remote -v"}}'
  run gate "$json"
  [ "$status" -eq 0 ]
}

# default-deny: при активном гейте тур read-only целиком. Любая не-доказуемо-readonly
# Bash-команда блокируется, даже если пишет вне офиса — разблокировка снимает гейт целиком.
@test "bash non-readonly command is blocked even when target not referenced" {
  activate
  json='{"tool_name":"Bash","tool_input":{"command":"echo hi > /tmp/whatever"}}'
  run gate "$json"
  [ "$status" -eq 2 ]
}

# --- Обходы allowlist (все были read-only-ложно-положительными в старой версии) ---

# запись через симлинк-алиас на target: сырой строки target в команде нет
@test "bash write via symlink alias to target is blocked" {
  activate
  ALIAS="$BATS_TEST_TMPDIR/alias"
  ln -s "$TARGET" "$ALIAS"
  json='{"tool_name":"Bash","tool_input":{"command":"cat /etc/hostname > '"$ALIAS"'/pwn"}}'
  run gate "$json"
  [ "$status" -eq 2 ]
}

# относительная запись через интерпретатор (cwd внутри офиса, target в строке нет)
@test "bash interpreter invocation is blocked" {
  activate
  json='{"tool_name":"Bash","tool_input":{"command":"python3 write_file.py"}}'
  run gate "$json"
  [ "$status" -eq 2 ]
}

# подстановка команд $(...)
@test "bash command substitution is blocked" {
  activate
  json='{"tool_name":"Bash","tool_input":{"command":"cat $(printf %s /tmp/x)"}}'
  run gate "$json"
  [ "$status" -eq 2 ]
}

# backticks
@test "bash backtick substitution is blocked" {
  activate
  json='{"tool_name":"Bash","tool_input":{"command":"cat `printf %s /tmp/x`"}}'
  run gate "$json"
  [ "$status" -eq 2 ]
}

# "|tee" без пробела обходил правило "| tee"
@test "bash pipe to tee without space is blocked" {
  activate
  json='{"tool_name":"Bash","tool_input":{"command":"cat /etc/hostname |tee '"$TARGET"'/pwn"}}'
  run gate "$json"
  [ "$status" -eq 2 ]
}

# пайп в интерпретатор
@test "bash pipe into interpreter is blocked" {
  activate
  json='{"tool_name":"Bash","tool_input":{"command":"cat '"$TARGET"'/CLAUDE.md | python3 -c pass"}}'
  run gate "$json"
  [ "$status" -eq 2 ]
}

# find с пишущим действием -fprintf (блокировались только -exec/-delete)
@test "bash find with -fprintf writer action is blocked" {
  activate
  json='{"tool_name":"Bash","tool_input":{"command":"find '"$TARGET"' -fprintf '"$TARGET"'/pwn x"}}'
  run gate "$json"
  [ "$status" -eq 2 ]
}

# перевод строки как разделитель команд
@test "bash newline as command separator is blocked" {
  activate
  json='{"tool_name":"Bash","tool_input":{"command":"ls '"$TARGET"'\nrm -rf '"$TARGET"'/office"}}'
  run gate "$json"
  [ "$status" -eq 2 ]
}

# косвенность через переменную: сырой строки target в команде нет
@test "bash readonly-looking command with var indirection is blocked" {
  activate
  json='{"tool_name":"Bash","tool_input":{"command":"cat $OFFICE/CLAUDE.md"}}'
  run gate "$json"
  [ "$status" -eq 2 ]
}

# read-only find (без пишущих действий) остаётся разрешён
@test "bash find read-only of target is allowed" {
  activate
  json='{"tool_name":"Bash","tool_input":{"command":"find '"$TARGET"' -name README.md"}}'
  run gate "$json"
  [ "$status" -eq 0 ]
}

# --- Неизвестные инструменты (в т.ч. файловые MCP) ---

# MCP-write с file_path внутри target — раньше проходил через дефолтный exit 0
@test "unknown mcp write tool with file_path in target is blocked" {
  activate
  json='{"tool_name":"mcp__fs__write_file","tool_input":{"file_path":"'"$TARGET"'/CLAUDE.md","content":"x"}}'
  run gate "$json"
  [ "$status" -eq 2 ]
}

# чтение файла в target неизвестным read-инструментом не должно блокироваться (тур = чтение)
@test "unknown read tool with path in target is allowed" {
  activate
  json='{"tool_name":"Read","tool_input":{"file_path":"'"$TARGET"'/CLAUDE.md"}}'
  run gate "$json"
  [ "$status" -eq 0 ]
}

# неизвестный инструмент вне target — разрешён
@test "unknown tool outside target is allowed" {
  activate
  json='{"tool_name":"mcp__fs__write_file","tool_input":{"file_path":"/tmp/x","content":"y"}}'
  run gate "$json"
  [ "$status" -eq 0 ]
}

@test "valid unlock file lets writes into target through" {
  activate
  mkdir -p "$BATS_TEST_TMPDIR/snap-xyz/tree"
  printf '%s\n' "$BATS_TEST_TMPDIR/snap-xyz" > "$OU_STATE_DIR/mutation-unlocked"
  json='{"tool_name":"Write","tool_input":{"file_path":"'"$TARGET"'/CLAUDE.md"}}'
  run gate "$json"
  [ "$status" -eq 0 ]
}

@test "unlock file pointing to a missing dir still blocks" {
  activate
  printf '%s\n' "$BATS_TEST_TMPDIR/does-not-exist" > "$OU_STATE_DIR/mutation-unlocked"
  json='{"tool_name":"Write","tool_input":{"file_path":"'"$TARGET"'/CLAUDE.md"}}'
  run gate "$json"
  [ "$status" -eq 2 ]
}

@test "broken json on stdin does not crash the session" {
  activate
  run --separate-stderr gate '{"tool_name":'
  [ "$status" -eq 0 ]
  [ -n "$stderr" ]
}
