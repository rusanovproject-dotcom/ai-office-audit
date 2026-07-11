#!/usr/bin/env bats
# Движок снятия картины: что человек РЕАЛЬНО делал (транскрипты Claude Code).
# Read-only. Окно — по timestamp внутри строки, не по mtime файла.
# Имена тестов латиницей: bats не переваривает кириллицу в @test.

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCAN="$REPO/engine/fit-scan.sh"
  FIX="$BATS_TEST_TMPDIR/projects"
  bash "$BATS_TEST_DIRNAME/fixtures/make-fixtures.sh" "$FIX"
  OUT="$(bash "$SCAN" --transcripts "$FIX" --days 30)"
}

# Живые реплики человека отделяются от шума (tool_result, caveat, system-reminder)
@test "human prompts: real speech only, noise dropped" {
  [ "$(jq -r '.human_prompts | length' <<< "$OUT")" -eq 2 ]
  jq -e '.human_prompts | any(.text | test("КП для Олега"))' <<< "$OUT"
  jq -e '.human_prompts | all(.text | test("system-reminder|command-caveat|tool_result") | not)' <<< "$OUT"
}

# Слэш-команды спрятаны в <command-name> — их надо доставать
@test "slash commands extracted from command-name tag" {
  [ "$(jq -r '.slash_commands.hormozi' <<< "$OUT")" -eq 1 ]
}

@test "tools and subagents counted" {
  [ "$(jq -r '.tools.Bash' <<< "$OUT")" -eq 1 ]
  [ "$(jq -r '.tools.Edit' <<< "$OUT")" -eq 1 ]
  [ "$(jq -r '.tools.Task' <<< "$OUT")" -eq 1 ]
  [ "$(jq -r '.subagents.equalizer' <<< "$OUT")" -eq 1 ]
}

# Работа субагента — не задача человека
@test "isSidechain rows are not human work" {
  jq -e '.human_prompts | all(.text | test("я субагент") | not)' <<< "$OUT"
  [ "$(jq -r '.tools.Bash' <<< "$OUT")" -eq 1 ]
}

# Окно — по timestamp внутри строки, mtime файла врёт
@test "window uses row timestamp not file mtime" {
  jq -e '.human_prompts | all(.text | test("древняя задача") | not)' <<< "$OUT"
  [ "$(jq -r '.sessions' <<< "$OUT")" -eq 2 ]
}

# Руками (Bash/Edit) против инструмента (Skill/Task/Agent) — ядро метрики
@test "manual vs tooled ops ratio" {
  [ "$(jq -r '.manual_ops' <<< "$OUT")" -eq 2 ]
  [ "$(jq -r '.tooled_ops' <<< "$OUT")" -eq 1 ]
}

# Делегирование в свежем Claude Code зовётся Agent, а не Task.
# Ловить только Task = недосчитать всю делегированную работу.
@test "Agent tool counts as tooled work, same as Task" {
  fix="$BATS_TEST_TMPDIR/agentproj"; mkdir -p "$fix/p"
  ts="$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")"
  printf '%s\n' \
    "{\"type\":\"assistant\",\"sessionId\":\"s1\",\"timestamp\":\"$ts\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"Agent\",\"input\":{\"subagent_type\":\"designer\"}}]}}" \
    > "$fix/p/s.jsonl"
  out="$(bash "$SCAN" --transcripts "$fix" --days 30)"
  [ "$(jq -r '.tooled_ops' <<< "$out")" -eq 1 ]
  [ "$(jq -r '.subagents.designer' <<< "$out")" -eq 1 ]
}

# /clear, /model, /compact — управление сессией, а не работа скиллом.
# Смешать их со скиллами = соврать человеку, будто он пользуется инструментами.
@test "session-control commands separated from real skills" {
  fix="$BATS_TEST_TMPDIR/slashproj"; mkdir -p "$fix/p"
  ts="$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")"
  printf '%s\n' \
    "{\"type\":\"user\",\"entrypoint\":\"cli\",\"sessionId\":\"s1\",\"timestamp\":\"$ts\",\"message\":{\"content\":\"<command-name>/clear</command-name>\"}}" \
    "{\"type\":\"user\",\"entrypoint\":\"cli\",\"sessionId\":\"s1\",\"timestamp\":\"$ts\",\"message\":{\"content\":\"<command-name>/forge</command-name>\"}}" \
    > "$fix/p/s.jsonl"
  out="$(bash "$SCAN" --transcripts "$fix" --days 30)"
  [ "$(jq -r '.skills_called.forge' <<< "$out")" -eq 1 ]
  jq -e '.skills_called | has("clear") | not' <<< "$out"
  [ "$(jq -r '.session_control.clear' <<< "$out")" -eq 1 ]
}

# Транскрипты содержат не только живого человека: SDK/headless-прогоны, смоук-тесты ботов, CI.
# Посчитать их как задачи = наврать клиенту в лицо («ты 300 раз спрашивал про X»).
@test "machine runs (sdk entrypoint) excluded from human work" {
  fix="$BATS_TEST_TMPDIR/mixproj"; mkdir -p "$fix/p"
  ts="$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")"
  printf '%s\n' \
    "{\"type\":\"user\",\"entrypoint\":\"cli\",\"sessionId\":\"live\",\"timestamp\":\"$ts\",\"message\":{\"content\":\"живая задача человека\"}}" \
    "{\"type\":\"user\",\"entrypoint\":\"sdk-py\",\"sessionId\":\"bot\",\"timestamp\":\"$ts\",\"message\":{\"content\":\"смоук-тест бота\"}}" \
    "{\"type\":\"user\",\"entrypoint\":\"sdk-cli\",\"sessionId\":\"bot2\",\"timestamp\":\"$ts\",\"message\":{\"content\":\"ещё прогон\"}}" \
    > "$fix/p/s.jsonl"
  out="$(bash "$SCAN" --transcripts "$fix" --days 30)"
  [ "$(jq -r '.human_prompts | length' <<< "$out")" -eq 1 ]
  jq -e '.human_prompts[0].text | test("живая задача")' <<< "$out"
  [ "$(jq -r '.excluded_machine_rows' <<< "$out")" -eq 2 ]
}

# Один и тот же текст, прогнанный 5 раз, — это одна процедура, а не 5 разных задач.
@test "repeated identical prompts collapse into one task with count" {
  fix="$BATS_TEST_TMPDIR/dupproj"; mkdir -p "$fix/p"
  ts="$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")"
  : > "$fix/p/s.jsonl"
  for i in 1 2 3 4 5; do
    printf '%s\n' "{\"type\":\"user\",\"entrypoint\":\"cli\",\"sessionId\":\"s$i\",\"timestamp\":\"$ts\",\"message\":{\"content\":\"проверь оффер на жирность\"}}" >> "$fix/p/s.jsonl"
  done
  out="$(bash "$SCAN" --transcripts "$fix" --days 30)"
  [ "$(jq -r '.unique_prompts | length' <<< "$out")" -eq 1 ]
  [ "$(jq -r '.unique_prompts[0].count' <<< "$out")" -eq 5 ]
}

# Claude Code подаёт как user-строки кучу служебного: тело вызванного скилла, картинки,
# компакт-саммари, прерывания, межагентные сообщения. Это не речь человека.
@test "injected system payloads are not human speech" {
  fix="$BATS_TEST_TMPDIR/injproj"; mkdir -p "$fix/p"
  ts="$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")"
  printf '%s\n' \
    "{\"type\":\"user\",\"entrypoint\":\"cli\",\"sessionId\":\"s1\",\"timestamp\":\"$ts\",\"message\":{\"content\":\"Base directory for this skill: /Users/x/.claude/skills/forge\"}}" \
    "{\"type\":\"user\",\"entrypoint\":\"cli\",\"sessionId\":\"s1\",\"timestamp\":\"$ts\",\"message\":{\"content\":\"[Image: original 3456x2234, displayed at 2000x1293]\"}}" \
    "{\"type\":\"user\",\"entrypoint\":\"cli\",\"sessionId\":\"s1\",\"timestamp\":\"$ts\",\"message\":{\"content\":\"[Request interrupted by user]\"}}" \
    "{\"type\":\"user\",\"entrypoint\":\"cli\",\"sessionId\":\"s1\",\"timestamp\":\"$ts\",\"message\":{\"content\":\"This session is being continued from a previous conversation that ran out of context.\"}}" \
    "{\"type\":\"user\",\"entrypoint\":\"cli\",\"sessionId\":\"s1\",\"timestamp\":\"$ts\",\"message\":{\"content\":\"Another Claude session sent a message: hi\"}}" \
    "{\"type\":\"user\",\"entrypoint\":\"cli\",\"sessionId\":\"s1\",\"timestamp\":\"$ts\",\"message\":{\"content\":\"Continue from where you left off.\"}}" \
    "{\"type\":\"user\",\"entrypoint\":\"cli\",\"sessionId\":\"s1\",\"timestamp\":\"$ts\",\"message\":{\"content\":\"собери лендинг для психолога\"}}" \
    > "$fix/p/s.jsonl"
  out="$(bash "$SCAN" --transcripts "$fix" --days 30)"
  [ "$(jq -r '.human_prompts | length' <<< "$out")" -eq 1 ]
  jq -e '.human_prompts[0].text | test("лендинг для психолога")' <<< "$out"
}

# ГЛАВНАЯ МЕТРИКА. Bash/Edit ВНУТРИ вызванного скилла — это работа инструмента, а не «руками».
# Считать tool-calls = соврать: у любого, кто зовёт скиллы, Bash всё равно будет тысячи.
# Честная единица — СЕССИЯ: прошла через Skill/Agent или человек делал всё голыми руками.
@test "throughput counted per session, not per tool call" {
  fix="$BATS_TEST_TMPDIR/thruproj"; mkdir -p "$fix/p"
  ts="$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")"
  # Сессия A: инструментальная — вызван Skill, а Bash/Edit внутри него не делают её «ручной»
  printf '%s\n' \
    "{\"type\":\"user\",\"entrypoint\":\"cli\",\"sessionId\":\"A\",\"timestamp\":\"$ts\",\"message\":{\"content\":\"собери фичу\"}}" \
    "{\"type\":\"assistant\",\"sessionId\":\"A\",\"timestamp\":\"$ts\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"Skill\",\"input\":{}}]}}" \
    "{\"type\":\"assistant\",\"sessionId\":\"A\",\"timestamp\":\"$ts\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"Bash\",\"input\":{}}]}}" \
    "{\"type\":\"assistant\",\"sessionId\":\"A\",\"timestamp\":\"$ts\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"Edit\",\"input\":{}}]}}" \
    "{\"type\":\"user\",\"entrypoint\":\"cli\",\"sessionId\":\"B\",\"timestamp\":\"$ts\",\"message\":{\"content\":\"поправь текст\"}}" \
    "{\"type\":\"assistant\",\"sessionId\":\"B\",\"timestamp\":\"$ts\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"Edit\",\"input\":{}}]}}" \
    > "$fix/p/s.jsonl"
  out="$(bash "$SCAN" --transcripts "$fix" --days 30)"
  [ "$(jq -r '.sessions' <<< "$out")" -eq 2 ]
  [ "$(jq -r '.tooled_sessions' <<< "$out")" -eq 1 ]
  [ "$(jq -r '.manual_sessions' <<< "$out")" -eq 1 ]
}

@test "broken json line does not crash engine" {
  run bash "$SCAN" --transcripts "$FIX" --days 30
  [ "$status" -eq 0 ]
}

# Read-only на уровне поведения: ни байта в чужой каталог
@test "isolation: engine writes nothing into transcripts dir" {
  before="$(find "$FIX" -type f -exec shasum {} + | shasum)"
  bash "$SCAN" --transcripts "$FIX" --days 30 >/dev/null
  after="$(find "$FIX" -type f -exec shasum {} + | shasum)"
  [ "$before" = "$after" ]
}
