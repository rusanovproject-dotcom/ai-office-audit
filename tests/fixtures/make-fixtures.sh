#!/usr/bin/env bash
# Генератор фикстур-транскриптов. Даты считаются от «сегодня», чтобы окно --days
# тестировалось честно и фикстуры не протухали со временем.
set -euo pipefail

DIR="${1:?usage: make-fixtures.sh <outdir>}"
rm -rf "$DIR"
mkdir -p "$DIR/-Users-someone-office"

# ISO-дата N дней назад (BSD date на macOS, GNU date на Linux)
ago() {
  if date -v-1d >/dev/null 2>&1; then date -u -v-"$1"d +"%Y-%m-%dT%H:%M:%S.000Z"
  else date -u -d "$1 days ago" +"%Y-%m-%dT%H:%M:%S.000Z"; fi
}

RECENT=$(ago 3)
OLD=$(ago 90)

# --- Сессия 1: человек руками собирает КП (Bash+Edit, ни одного Skill/Task) ---
cat > "$DIR/-Users-someone-office/sess-a.jsonl" <<EOF
{"type":"user","entrypoint":"cli","isSidechain":false,"sessionId":"sess-a","cwd":"/Users/someone/office","timestamp":"$RECENT","message":{"role":"user","content":"собери КП для Олега по вчерашнему звонку"}}
{"type":"assistant","isSidechain":false,"sessionId":"sess-a","timestamp":"$RECENT","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":"ls"}}]}}
{"type":"assistant","isSidechain":false,"sessionId":"sess-a","timestamp":"$RECENT","message":{"role":"assistant","content":[{"type":"tool_use","name":"Edit","input":{}}]}}
{"type":"user","entrypoint":"cli","isSidechain":false,"sessionId":"sess-a","timestamp":"$RECENT","message":{"role":"user","content":[{"type":"tool_result","content":"ok"}]}}
{"type":"user","entrypoint":"cli","isSidechain":false,"sessionId":"sess-a","timestamp":"$RECENT","message":{"role":"user","content":"<local-command-caveat>Caveat: ignore me</local-command-caveat>"}}
{"type":"user","entrypoint":"cli","isSidechain":false,"sessionId":"sess-a","timestamp":"$RECENT","message":{"role":"user","content":"<system-reminder>noise</system-reminder>"}}
EOF

# --- Сессия 2: слэш-команда + субагент (инструментальная работа) ---
cat > "$DIR/-Users-someone-office/sess-b.jsonl" <<EOF
{"type":"user","entrypoint":"cli","isSidechain":false,"sessionId":"sess-b","cwd":"/Users/someone/office","timestamp":"$RECENT","message":{"role":"user","content":"<command-name>/hormozi</command-name>\n<command-args>--review</command-args>"}}
{"type":"user","entrypoint":"cli","isSidechain":false,"sessionId":"sess-b","timestamp":"$RECENT","message":{"role":"user","content":"проверь оффер на жирность"}}
{"type":"assistant","isSidechain":false,"sessionId":"sess-b","timestamp":"$RECENT","message":{"role":"assistant","content":[{"type":"tool_use","name":"Task","input":{"subagent_type":"equalizer"}}]}}
{"type":"assistant","isSidechain":true,"sessionId":"sess-b","timestamp":"$RECENT","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{}}]}}
{"type":"user","entrypoint":"cli","isSidechain":true,"sessionId":"sess-b","timestamp":"$RECENT","message":{"role":"user","content":"я субагент, меня не считать за задачу человека"}}
EOF

# --- Сессия 3: ВНЕ окна (90 дней назад), mtime файла при этом свежий ---
cat > "$DIR/-Users-someone-office/sess-old.jsonl" <<EOF
{"type":"user","entrypoint":"cli","isSidechain":false,"sessionId":"sess-old","cwd":"/Users/someone/office","timestamp":"$OLD","message":{"role":"user","content":"древняя задача которую не надо считать"}}
{"type":"assistant","isSidechain":false,"sessionId":"sess-old","timestamp":"$OLD","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{}}]}}
EOF

# --- Битая строка: движок не должен падать ---
printf '{"type":"user","broken\n' >> "$DIR/-Users-someone-office/sess-a.jsonl"
