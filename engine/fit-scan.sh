#!/usr/bin/env bash
# fit-scan.sh — снятие картины «что человек реально делал руками» из транскриптов Claude Code.
#
# READ-ONLY. Не пишет ни байта в каталог транскриптов. Не читает .env/secrets.
# Источник универсален: ~/.claude/projects/*/*.jsonl есть у ЛЮБОГО пользователя Claude Code.
#
#   fit-scan.sh --transcripts <dir> [--days 30] [--cwd-filter <substr>]
#
# Выход — JSON в stdout (агрегаты + живые реплики человека).
set -euo pipefail

TRANSCRIPTS="${HOME}/.claude/projects"
DAYS=30
CWD_FILTER=""
MAX_TEXT=280   # обрезка реплики: в отчёт не должны утекать простыни с ПД третьих лиц

while [[ $# -gt 0 ]]; do
  case "$1" in
    --transcripts) TRANSCRIPTS="$2"; shift 2 ;;
    --days)        DAYS="$2";        shift 2 ;;
    --cwd-filter)  CWD_FILTER="$2";  shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -d "$TRANSCRIPTS" ]] || { echo "no transcripts dir: $TRANSCRIPTS" >&2; exit 1; }

# Граница окна в ISO-UTC. ISO-строки сравниваются лексикографически — этого достаточно.
if date -v-1d >/dev/null 2>&1; then
  CUTOFF="$(date -u -v-"${DAYS}"d +"%Y-%m-%dT%H:%M:%S.000Z")"
else
  CUTOFF="$(date -u -d "${DAYS} days ago" +"%Y-%m-%dT%H:%M:%S.000Z")"
fi

# Предфильтр по mtime: файл, не тронутый N дней, не может содержать свежих строк.
# Обратное невозможно, поэтому свежие данные не теряются. Точный отсев — по timestamp ниже.
# +2 дня запаса на часовые пояса.
FILES=$(find "$TRANSCRIPTS" -type f -name '*.jsonl' -mtime -"$((DAYS + 2))" 2>/dev/null || true)
[[ -n "$FILES" ]] || { echo '{"sessions":0,"human_prompts":[],"slash_commands":{},"tools":{},"subagents":{},"manual_ops":0,"tooled_ops":0}'; exit 0; }

# Проход 1 (потоковый): сырые строки -> компактные события. Битый JSON глотается через fromjson?.
# Держим память ровной: в поток уходят только маленькие события, не тела транскриптов.
events() {
  echo "$FILES" | tr '\n' '\0' | xargs -0 cat 2>/dev/null | jq -R -c --arg cutoff "$CUTOFF" --arg cwdf "$CWD_FILTER" --argjson maxtext "$MAX_TEXT" '
    # Живой человек сидит в терминале/IDE. sdk-* и headless — это боты, CI, смоук-тесты.
    # Считать их задачами человека = наврать ему в лицо.
    ["cli", "claude-vscode", "claude-desktop"] as $HUMAN_ENTRY
    | (fromjson? // empty) as $r
    | select(($r.timestamp // "") >= $cutoff)
    | select(($r.isSidechain // false) != true)          # работа субагента — не задача человека
    # Сегментный матч, не голый substring: 'office' не должен ловить 'office-upgrade'.
    # Оборачиваем и путь, и фильтр в слеши — совпадение только по границе сегмента пути.
    | select($cwdf == "" or (("/" + ($r.cwd // "") + "/") | contains("/" + $cwdf + "/")))
    # Машина/человек решается на уровне СЕССИИ (агрегация ниже выкинет ВСЕ строки машинных сессий,
    # включая assistant-строки с tool_use). entrypoint sdk-*/headless — это бот/CI/крон.
    # ОТСУТСТВИЕ entrypoint трактуем консервативно как человека: часть клиентов его не шлёт, а
    # пометка machine обнулила бы всю реальную историю такого пользователя (хуже редкого шума).
    | if ($r.type == "user") and (($r.entrypoint // "") != "") and ($r.entrypoint | IN($HUMAN_ENTRY[]) | not)
      then {k: "machine", s: ($r.sessionId // "")}
      else
    ($r.message.content // null) as $c

    # Текст реплики: content бывает строкой ИЛИ массивом блоков.
    | (if ($c | type) == "string" then $c
       elif ($c | type) == "array" then ([$c[] | select(.type == "text") | .text] | join("\n"))
       else "" end) as $text

    # tool_result приходит как user-строка — это ответ машины, не речь человека.
    | (($c | type) == "array" and (any($c[]; .type == "tool_result"))) as $is_result

    | if $r.type == "user" and ($text | length) > 0 and ($is_result | not) then
        # Слэш-команда лежит внутри <command-name>/skill</command-name>
        if ($text | test("<command-name>")) then
          {k: "slash", v: ($text | capture("<command-name>/?(?<n>[a-zA-Z0-9:_-]+)</command-name>").n // "?"), s: ($r.sessionId // "")}
        # Служебные полезные нагрузки, которые Claude Code подаёт как user-строки:
        # тело вызванного скилла, картинки, компакт-саммари, прерывания, межагентные сообщения.
        # Это не речь человека — считать их задачами значит наврать.
        elif ($text | test("^<(local-command|system-reminder|command-)")
              or (. | test("^Base directory for this skill:"))
              or (. | test("^\\[Image:"))
              or (. | test("^\\[Request interrupted"))
              or (. | test("^This session is being continued"))
              or (. | test("^Another Claude session sent a message:"))
              or (. | test("^Continue from where you left off"))
              or (. | test("^Caveat:"))) then empty
        else
          {k: "prompt", s: ($r.sessionId // ""), ts: $r.timestamp, cwd: ($r.cwd // ""),
           # Control-символы U+0000..U+001F в тексте роняют строгий downstream-jq
           # («control characters must be escaped»). jq-regex \u00xx их не ловит, поэтому
           # чистим по кодпоинтам через explode: всё < 32 (вкл. \n \t) → пробел.
           text: ($text | gsub("<system-reminder>[\\s\\S]*?</system-reminder>"; "")
                  | explode | map(if . < 32 then 32 else . end) | implode | .[0:$maxtext])}
        end
      elif $r.type == "assistant" and (($c | type) == "array") then
        $c[] | select(.type == "tool_use")
        | {k: "tool", v: .name, sub: (.input.subagent_type // null), s: ($r.sessionId // "")}
      else empty end
      end
  ' 2>/dev/null || true
}

# Проход 2: агрегация. Событий на порядки меньше сырья — слурп здесь безопасен.
events | jq -s -c '
  # Служебные команды Claude Code: управление сессией, а не вызов инструмента.
  ["clear","model","compact","login","logout","effort","rename","help","config","statusline",
   "fast","resume","exit","doctor","init","cost","status","vim","memory","plugin","agents","export"] as $CTL
  # Множество машинных сессий: где встретилась хоть одна machine-строка (нечеловеческий entrypoint).
  # ВСЕ строки этих сессий (в т.ч. assistant/tool_use) — активность бота, не работа человека.
  | (map(select(.k == "machine"))) as $machine_rows
  | ($machine_rows | map(.s) | unique) as $mset
  | (map(select(.k == "prompt" and (.text | test("^\\s*$") | not) and (.s as $s | ($s | IN($mset[])) | not)))) as $prompts
  | (map(select(.k == "tool" and (.s as $s | ($s | IN($mset[])) | not)))) as $tools
  | (map(select(.k == "slash" and (.s as $s | ($s | IN($mset[])) | not)))) as $slash
  # excluded = машинные user-строки + любые tool/slash/prompt-строки машинных сессий (их тоже выкинули),
  # чтобы фраза «машинные прогоны отсечены» была правдой и по tool-метрикам.
  | (($machine_rows | length)
     + (map(select((.k == "tool" or .k == "slash" or .k == "prompt") and (.s as $s | ($s | IN($mset[]))))) | length)) as $machine
  | {
      window_days: '"$DAYS"',
      sessions: ([($prompts[] | .s), ($slash[] | .s)] | unique | length),
      excluded_machine_rows: $machine,
      human_prompts: $prompts | map({ts, session: .s, cwd, text}),
      # Один текст, прогнанный N раз, — одна процедура с частотой N, а не N разных задач.
      unique_prompts: ($prompts
        | group_by(.text | ascii_downcase | gsub("\\s+"; " ") | .[0:120])
        | map({text: .[0].text, count: length, sessions: (map(.s) | unique | length), cwd: .[0].cwd})
        | sort_by(-.count)),
      slash_commands: ($slash | group_by(.v) | map({key: .[0].v, value: length}) | from_entries),
      # Управление сессией — не работа скиллом. Мешать их вместе = польстить человеку ложной цифрой.
      skills_called: ($slash | map(select(.v | IN($CTL[]) | not)) | group_by(.v) | map({key: .[0].v, value: length}) | from_entries),
      session_control: ($slash | map(select(.v | IN($CTL[]))) | group_by(.v) | map({key: .[0].v, value: length}) | from_entries),
      tools: ($tools | group_by(.v) | map({key: .[0].v, value: length}) | from_entries),
      subagents: ($tools | map(select(.sub != null)) | group_by(.sub) | map({key: .[0].sub, value: length}) | from_entries),
      manual_ops: ($tools | map(select(.v == "Bash" or .v == "Edit" or .v == "Write" or .v == "NotebookEdit")) | length),
      # Agent — нынешнее имя делегирования (бывший Task). Ловить только Task = недосчитать всё делегирование.
      tooled_ops: ($tools | map(select(.v == "Skill" or .v == "Task" or .v == "Agent")) | length),

      # ГЛАВНАЯ МЕТРИКА — по сессиям, не по tool-calls.
      # Bash/Edit внутри вызванного скилла — работа инструмента, а не «руками».
      # Инструментальная сессия = в ней хотя бы раз позвали Skill/Agent/Task.
      tooled_sessions: ($tools | map(select(.v == "Skill" or .v == "Task" or .v == "Agent")) | map(.s) | unique | length),
      manual_sessions: (
        ($tools | map(select(.v == "Skill" or .v == "Task" or .v == "Agent")) | map(.s) | unique) as $tooled
        | ($tools | map(select(.v == "Bash" or .v == "Edit" or .v == "Write")) | map(.s) | unique)
        | map(select(. as $s | ($tooled | index($s)) | not)) | length)
    }
'
