#!/usr/bin/env bash
# secret-scan.sh — сканер секретов чужого AI-офиса. Три зоны, JSON в stdout, READ-ONLY.
#
# ЖЕЛЕЗНОЕ ПРАВИЛО: тела секретов НИКОГДА не попадают в вывод — только категории,
# счётчики и пути файлов. Совпавшие токены живут лишь в конвейере (classify) и
# отбрасываются до сборки JSON. Ключ в отчёте = провал всего продукта.
#
#   secret-scan.sh [--transcripts DIR] [--target DIR] [--zones transcripts,git,rights]
#
# Зона 1 — транскрипты (*.jsonl рекурсивно): категория -> {hits, files} + top_files (пути).
# Зона 2 — git-история (--target): git log -p --all в тот же матчер -> {category:{hits}}.
# Зона 3 — права/хуки (--target): 11 проверок из канона + core.hooksPath (мёртвые хуки).
#
# .env/*.pem/credentials*/secrets* НЕ читаются: зона 1 берёт только *.jsonl,
# зона 3 проверяет лишь существование/gitignore, содержимого не касается.
set -euo pipefail

TRANSCRIPTS="${HOME}/.claude/projects"
TARGET=""
ZONES="transcripts,git,rights"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --transcripts) TRANSCRIPTS="$2"; shift 2 ;;
    --target)      TARGET="$2";      shift 2 ;;
    --zones)       ZONES="$2";       shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

GENERATED="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

# --- Таблица паттернов: category<TAB>regex. Категории повторяются (несколько паттернов). ---
# jwt требует ТРИ base64-сегмента: голый eyJ даёт лавину ложных.
# conn_string ловит только строки С паролем (:...@), голый URL не секрет.
read -r -d '' PATTERNS <<'EOF' || true
anthropic	sk-ant-[A-Za-z0-9_-]{10,}
openai	sk-proj-[A-Za-z0-9_-]{20,}
openai	sk-[A-Za-z0-9]{20}T3BlbkFJ[A-Za-z0-9]{20}
github	ghp_[A-Za-z0-9]{36}
github	github_pat_[A-Za-z0-9_]{22,}
telegram_bot	[0-9]{8,10}:AA[A-Za-z0-9_-]{33}
slack	xox[bpoas]-[0-9A-Za-z-]{10,}
aws	AKIA[0-9A-Z]{16}
google	AIza[A-Za-z0-9_-]{35}
groq	gsk_[A-Za-z0-9]{20,}
yandex_oauth	y0_[A-Za-z0-9_-]{20,}
stripe_live	sk_live_[A-Za-z0-9]{20,}
jwt	eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{5,}
private_key	-----BEGIN [A-Z ]*PRIVATE KEY-----
conn_string_with_password	(postgres|postgresql|mysql|mongodb(\+srv)?|redis|amqp)://[^ "']+:[^ "'@]+@
EOF

# Общий OR-регекс для одного потокового прохода (память ровная на файлах в гигабайты).
COMBINED=""
while IFS=$'\t' read -r cat regex; do
  [[ -z "$cat" ]] && continue
  COMBINED="${COMBINED:+$COMBINED|}($regex)"
done <<< "$PATTERNS"

# classify: совпавший токен -> имя категории. Анкер ^(...)$ на весь токен, порядок как в таблице.
# Работает in-process через bash [[ =~ ]] — без subprocess на каждый токен.
classify() {
  local tok="$1" cat regex
  while IFS=$'\t' read -r cat regex; do
    [[ -z "$cat" ]] && continue
    if [[ "$tok" =~ ^(${regex})$ ]]; then printf '%s' "$cat"; return; fi
  done <<< "$PATTERNS"
  printf 'other'
}

# Ядер для параллельного префильтра (portable: nproc → sysctl → 4).
NPROC="$( (command -v nproc >/dev/null 2>&1 && nproc) || sysctl -n hw.ncpu 2>/dev/null || echo 4 )"

# =========================== ЗОНА 1: транскрипты ===========================
zone_transcripts() {
  if [[ ! -d "$TRANSCRIPTS" ]]; then
    echo '{"skipped":"no transcripts dir"}'; return
  fi
  local files candidates rows
  files="$(find "$TRANSCRIPTS" -type f -name '*.jsonl' 2>/dev/null || true)"
  if [[ -z "$files" ]]; then
    echo '{"by_category":{},"files_affected_total":0,"top_files":[]}'; return
  fi
  # Префильтр: дешёвый grep -l (стоп на первом совпадении в файле, параллельно по ядрам)
  # отбирает файлы-кандидаты. Дорогой -o гоняем ТОЛЬКО по ним — файлы без секретов
  # (в реальном офисе их большинство) не доходят до извлечения и classify вовсе.
  # LC_ALL=C: паттсекретов ASCII — grep кратно быстрее на гигабайтах UTF-8.
  candidates="$(printf '%s\n' "$files" | tr '\n' '\0' \
    | LC_ALL=C xargs -0 -P "$NPROC" grep -lE -e "$COMBINED" 2>/dev/null || true)"
  [[ -z "$candidates" ]] && { echo '{"by_category":{},"files_affected_total":0,"top_files":[]}'; return; }
  # Извлечение по одному файлу: grep без -H, путь берём из переменной цикла — двоеточия
  # в пути НЕ мешают (CORR-6). Тела токенов уходят в classify и НЕ попадают в stdout.
  # awk-хэш схлопывает повторяющиеся токены в файле за ОДИН проход (без сортировки —
  # sort миллионов совпадений сам стал бы горлышком) → один ключ, залогированный тысячи
  # раз, классифицируется один раз. Портируемо (только ассоц-массив awk, без интервалов/
  # regex → любой awk). Счётчик $n хранит точные hits. Строка: category\tpath\tN.
  rows="$(
    export LC_ALL=C
    while IFS= read -r f; do
      [[ -n "$f" ]] || continue
      { grep -oE -e "$COMBINED" -- "$f" 2>/dev/null || true; } \
        | awk '{c[$0]++} END{for(k in c) printf "%d\t%s\n", c[k], k}' \
        | while IFS=$'\t' read -r n tok; do
            [[ -n "$tok" ]] || continue
            printf '%s\t%s\t%s\n' "$(classify "$tok")" "$f" "$n"
          done
    done <<< "$candidates"
  )"
  printf '%s' "$rows" | jq -R -s -c '
    [ split("\n")[] | select(length>0) | split("\t") | {category:.[0], path:.[1], n:(.[2]|tonumber)} ] as $rows
    | { by_category: ($rows | group_by(.category)
          | map({key:.[0].category, value:{hits:(map(.n)|add), files:(map(.path)|unique|length)}}) | from_entries),
        files_affected_total: ($rows | map(.path) | unique | length),
        top_files: ($rows | group_by(.path)
          | map({path:.[0].path, hits:(map(.n)|add)}) | sort_by(-.hits) | .[0:10]) }'
}

# =========================== ЗОНА 2: git-история ===========================
zone_git() {
  if [[ -z "$TARGET" ]]; then echo '{"skipped":"no target"}'; return; fi
  if ! git -C "$TARGET" --no-optional-locks rev-parse --git-dir >/dev/null 2>&1; then
    echo '{"skipped":"no git repo"}'; return
  fi
  local rows tracked env_ignore
  rows="$(git -C "$TARGET" --no-optional-locks log -p --all --no-color -- . 2>/dev/null \
    | grep -oE -e "$COMBINED" 2>/dev/null \
    | while IFS= read -r token; do classify "$token"; echo; done || true)"
  # grep без совпадений возвращает 1 — глотаем через { ...; || true; }, иначе jq получит пусто → [].
  tracked="$(git -C "$TARGET" --no-optional-locks ls-files 2>/dev/null | { grep -E '(^|/)\.env' 2>/dev/null || true; } | jq -R -s -c 'split("\n")|map(select(length>0))')"
  if git -C "$TARGET" --no-optional-locks check-ignore -q .env 2>/dev/null; then env_ignore=true; else env_ignore=false; fi
  printf '%s' "$rows" | jq -R -s -c --argjson tracked "$tracked" --argjson ei "$env_ignore" '
    [ split("\n")[] | select(length>0) ] as $rows
    | { by_category: ($rows | group_by(.) | map({key:.[0], value:{hits:length}}) | from_entries),
        tracked_env_files: $tracked,
        env_in_gitignore: $ei }'
}

# =========================== ЗОНА 3: права/хуки ===========================
CHECKS_JSON="[]"
add_check() { # id weight status note
  CHECKS_JSON="$(jq -c --argjson id "$1" --argjson w "$2" --arg st "$3" --arg note "$4" \
    '. + [{id:$id, weight:$w, status:$st, note:$note}]' <<< "$CHECKS_JSON")"
}

zone_rights() {
  if [[ -z "$TARGET" ]]; then echo '{"skipped":"no target"}'; return; fi
  CHECKS_JSON="[]"
  local S1="$TARGET/.claude/settings.json" S2="$TARGET/.claude/settings.local.json"
  read_json() { if [[ -f "$1" ]]; then cat "$1"; else echo '{}'; fi; }
  local DENY ALLOW broken=0
  DENY="$(jq -s -c '(.[0].permissions.deny//[])+(.[1].permissions.deny//[])' <(read_json "$S1") <(read_json "$S2") 2>/dev/null || echo BROKEN)"
  ALLOW="$(jq -s -c '(.[0].permissions.allow//[])+(.[1].permissions.allow//[])' <(read_json "$S1") <(read_json "$S2") 2>/dev/null || echo BROKEN)"
  [[ "$DENY" == "BROKEN" ]] && broken=1

  local has_git=0
  git -C "$TARGET" --no-optional-locks rev-parse --git-dir >/dev/null 2>&1 && has_git=1

  # 1 (10): .gitignore закрывает все 5 паттернов
  local gi="$TARGET/.gitignore" ok=1 pat
  for pat in '.env' '.env.*' '*.pem' 'credentials*' 'secrets*'; do
    grep -qxF -- "$pat" "$gi" 2>/dev/null || ok=0
  done
  if [[ $ok -eq 1 ]]; then add_check 1 10 pass ".gitignore закрывает .env/.pem/credentials/secrets"
  else add_check 1 10 fail ".gitignore не закрывает все 5 паттернов секретов"; fi

  # 2 (9): permissions.deny непуст (union) — битый JSON = fail invalid json
  if [[ $broken -eq 1 ]]; then add_check 2 9 fail "invalid json в .claude/settings*"
  elif [[ "$(jq 'length' <<< "$DENY")" -gt 0 ]]; then add_check 2 9 pass "deny-правила заданы"
  else add_check 2 9 fail "permissions.deny пуст"; fi

  # 3 (8): в deny закрыты Read И Edit И Write для .env*
  if [[ $broken -eq 1 ]]; then add_check 3 8 skip "union недоступен (invalid json)"
  else
    # Якорим на литеральный \.env — иначе deny вроде Read(environments/**) (к секретам
    # отношения не имеет) ложно засчитывался защитой .env по голой подстроке "env" (CORR-2).
    local t all3=1
    for t in Read Edit Write; do
      jq -e --arg t "$t" 'any(.[]; test("^"+$t+"\\(.*\\.env"))' <<< "$DENY" >/dev/null 2>&1 || all3=0
    done
    if [[ $all3 -eq 1 ]]; then add_check 3 8 pass "Read/Edit/Write для .env закрыты"
    else add_check 3 8 fail "не все из Read/Edit/Write закрыты для .env"; fi
  fi

  # 4 (7): деструктив в deny — rm, --force-push, reset --hard (>=3)
  if [[ $broken -eq 1 ]]; then add_check 4 7 skip "union недоступен (invalid json)"
  else
    # Границы токенов: rm как отдельное слово (не terraform/platform/charm), --force
    # только не --force-with-lease (безопасный вариант), reset --hard литералом (CORR-5).
    local cnt
    cnt="$(jq '[ (any(.[];test("\\brm\\b"))), (any(.[];test("--force([^-]|$)"))), (any(.[];test("reset --hard"))) ]|map(select(.))|length' <<< "$DENY")"
    if [[ "$cnt" -ge 3 ]]; then add_check 4 7 pass "деструктив (rm/force/reset) закрыт"
    else add_check 4 7 fail "деструктив закрыт частично ($cnt/3)"; fi
  fi

  # 5 (5): нет wildcard-allow вида Tool(*)
  if [[ "$ALLOW" == "BROKEN" ]]; then add_check 5 5 skip "union недоступен (invalid json)"
  elif jq -e 'any(.[]; test("^\\w+\\(\\*+\\)$"))' <<< "$ALLOW" >/dev/null 2>&1; then
    add_check 5 5 fail "есть wildcard-allow Tool(*)"
  else add_check 5 5 pass "wildcard-allow отсутствует"; fi

  # 6 (5): файл pre-push* в .claude/hooks/
  if compgen -G "$TARGET/.claude/hooks/pre-push*" >/dev/null 2>&1; then
    add_check 6 5 pass "pre-push хук лежит в .claude/hooks"
  else add_check 6 5 fail "нет pre-push в .claude/hooks"; fi

  # 7 (9): .git/hooks/pre-push установлен и НЕ симлинк
  if [[ $has_git -eq 0 ]]; then add_check 7 9 skip "нет git-репо"
  else
    local pp="$TARGET/.git/hooks/pre-push"
    if [[ -f "$pp" && ! -L "$pp" ]]; then add_check 7 9 pass ".git/hooks/pre-push установлен (не симлинк)"
    else add_check 7 9 fail ".git/hooks/pre-push не установлен или симлинк"; fi
  fi

  # 8 (6): .git/hooks/pre-commit существует (content-сканер установлен)
  if [[ $has_git -eq 0 ]]; then add_check 8 6 skip "нет git-репо"
  elif [[ -e "$TARGET/.git/hooks/pre-commit" ]]; then add_check 8 6 pass ".git/hooks/pre-commit установлен"
  else add_check 8 6 fail ".git/hooks/pre-commit отсутствует"; fi

  # 9 (4): dangerously-skip-permissions упомянут в deny/хуках .claude
  if grep -rqI 'dangerously-skip-permissions' "$TARGET/.claude" 2>/dev/null; then
    add_check 9 4 pass "dangerously-skip-permissions под контролем"
  else add_check 9 4 fail "dangerously-skip-permissions нигде не упомянут"; fi

  # 10 (5, сверх чеклиста): core.hooksPath пуст ИЛИ .git/hooks — иначе хуки мертвы
  if [[ $has_git -eq 0 ]]; then add_check 10 5 skip "нет git-репо"
  else
    local hp; hp="$(git -C "$TARGET" --no-optional-locks config core.hooksPath 2>/dev/null || true)"
    if [[ -z "$hp" || "$hp" == ".git/hooks" ]]; then add_check 10 5 pass "core.hooksPath не уводит хуки"
    else add_check 10 5 fail "хуки в .git/hooks мертвы (core.hooksPath=$hp)"; fi
  fi

  # 11 (3, сверх чеклиста): все .claude/hooks/*.sh исполняемы
  local shfiles=() f x_ok=1
  while IFS= read -r f; do [[ -n "$f" ]] && shfiles+=("$f"); done < <(find "$TARGET/.claude/hooks" -maxdepth 1 -name '*.sh' 2>/dev/null || true)
  if [[ ${#shfiles[@]} -eq 0 ]]; then add_check 11 3 skip "нет .sh в .claude/hooks"
  else
    for f in "${shfiles[@]}"; do [[ -x "$f" ]] || x_ok=0; done
    if [[ $x_ok -eq 1 ]]; then add_check 11 3 pass "все хуки .sh исполняемы"
    else add_check 11 3 fail "есть неисполняемые .sh в .claude/hooks"; fi
  fi

  # rights_score = сумма весов pass / сумма весов не-skip * 100 (компонент pro_grade, отдельно от зон 1-2)
  jq -c '
    (map(select(.status!="skip"))|map(.weight)|add // 0) as $den
    | (map(select(.status=="pass"))|map(.weight)|add // 0) as $num
    | {checks:., rights_score: (if $den==0 then 0 else (($num*100)/$den)|round end)}' <<< "$CHECKS_JSON"
}

# =========================== Сборка вывода ===========================
want() { [[ ",$ZONES," == *",$1,"* ]]; }

if want transcripts; then T_JSON="$(zone_transcripts)"; else T_JSON='{"skipped":"not requested"}'; fi
if want git;         then G_JSON="$(zone_git)";         else G_JSON='{"skipped":"not requested"}'; fi
if want rights;      then R_JSON="$(zone_rights)";      else R_JSON='{"skipped":"not requested"}'; fi

jq -n --argjson t "$T_JSON" --argjson g "$G_JSON" --argjson r "$R_JSON" --arg gen "$GENERATED" \
  '{zones:{transcripts:$t, git_history:$g, rights:$r}, generated:$gen}'
