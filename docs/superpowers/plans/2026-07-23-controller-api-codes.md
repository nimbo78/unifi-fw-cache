# Controller API Device Codes — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Опциональное подключение `unifi-fw-cache.sh` к API UniFi-контроллера для получения кодов моделей только adopted-устройств (multi-site) и кэширования прошивок для них.

**Architecture:** Единый блок функций «Controller API» внутри существующего однофайлового скрипта; новые флаги включают выборку кодов, которая вливается в существующий конвейер `--from-catalog`. Автоопределение self-hosted (`/api/login`) vs UniFi OS (`/api/auth/login` + `/proxy/network`). Спек: `docs/superpowers/specs/2026-07-23-controller-codes-design.md`. План прошёл devil's-advocate-ревью; исправления вшиты в код задач.

**Tech Stack:** bash 4+, curl (только для новых флагов), jq, mongosh/mongo (только для `--codes-from-db`).

## Global Constraints

- Один файл: весь код добавляется в `unifi-fw-cache.sh`; новых файлов кода не создавать.
- Комментарии и сообщения — на русском, echo-сообщения с emoji в стиле существующих (`❌`, `⚠️`, `🔐`, `📟`, `🏢`).
- curl НЕ добавлять в общий цикл проверки зависимостей (строка 221: `for cmd in jq wget ...`) — он обязателен только при использовании новых флагов.
- Все вызовы curl к контроллеру: `-k -s --noproxy <host> --connect-timeout 10 --max-time 60`.
- Фильтр adopted обязателен в обоих источниках: jq `select(.adopted==true)`, mongo `{adopted: true}`.
- Успех classic-API-ответов проверяется по `meta.rc == "ok"` (ошибки приходят с `"data": []`).
- Пароль не попадает в argv ни одного процесса: jq читает его из окружения (`env.UNIFI_API_PASS`), не через `--arg`.
- Приоритет кредов: флаги > env > файл кредов.
- ВАЖНО (set -e): все новые функции вызываются в контексте `|| exit 1`, где errexit подавлен, — поэтому каждый статус пайпа/команды проверяется явно; никакой `grep` не должен стоять последним в пайплайне, который легитимно может дать пустой результат (использовать `sed '/^$/d'`).
- Тестового фреймворка в проекте нет, runtime (контроллер) недоступен на dev-хосте (Windows). TDD-цикл заменён на: `bash -n` после каждого изменения + smoke-проверка `--help` + shellcheck (если установлен) + финальный чек-лист runtime-проверки пользователем на виртуалке.
- Коммит в конце каждой задачи; ветка `feat/controller-api-codes`.
- Нумерация строк ниже — по состоянию файла на коммит `af84f76`; после Task 1 строки съедут — ориентироваться на якорные фрагменты кода, а не на номера.

---

### Task 1: Конфигурация, CLI-флаги, usage, cleanup

**Files:**
- Modify: `unifi-fw-cache.sh` — блок переменных (~строки 25–48), `usage()` (~строка 72), парсер аргументов (~строка 203), `cleanup()` (строка 47)

**Interfaces:**
- Produces: глобальные переменные `CODES_FROM_CONTROLLER`, `LIST_CONTROLLER_CODES`, `CODES_FROM_DB`, `API_CREDS_FILE`, `UNIFI_API_URL`, `UNIFI_API_USER`, `UNIFI_API_PASS`, `API_COOKIE_JAR`, `API_CSRF_TOKEN`, `API_BASE`, массив `API_CURL_ARGS` — используются задачами 2–5.

- [ ] **Step 1: Добавить переменные состояния**

После строки `FILTER_REGEX=""` (строка 36) добавить:

```bash

# Интеграция с API контроллера (--codes-from-controller)
CODES_FROM_CONTROLLER=0
LIST_CONTROLLER_CODES=0
CODES_FROM_DB=0
API_CREDS_FILE=""
UNIFI_API_URL="${UNIFI_API_URL:-}"    # default https://localhost:8443 подставляется в load_api_creds
UNIFI_API_USER="${UNIFI_API_USER:-}"
UNIFI_API_PASS="${UNIFI_API_PASS:-}"
API_COOKIE_JAR=""
API_CSRF_TOKEN=""
API_BASE=""
API_CURL_ARGS=()
```

- [ ] **Step 2: Расширить cleanup()**

Заменить строку 47:

```bash
cleanup() { rm -f "$TEMP_META_FILE" "$DOWNLOAD_LIST"; }
```

на:

```bash
cleanup() { rm -f "$TEMP_META_FILE" "$DOWNLOAD_LIST" ${API_COOKIE_JAR:+"$API_COOKIE_JAR"}; }
```

- [ ] **Step 3: Добавить case-ветки в парсер**

После строки `--fetch-catalog-api) FETCH_CATALOG_API=1; shift ;;` (строка 203) добавить:

```bash
    --codes-from-controller) CODES_FROM_CONTROLLER=1; shift ;;
    --list-controller-codes) LIST_CONTROLLER_CODES=1; shift ;;
    --codes-from-db) CODES_FROM_DB=1; CODES_FROM_CONTROLLER=1; shift ;;
    --api-url) shift; UNIFI_API_URL="${1:-}"; shift || true ;;
    --api-user) shift; UNIFI_API_USER="${1:-}"; shift || true ;;
    --api-pass) shift; UNIFI_API_PASS="${1:-}"; shift || true ;;
    --api-creds-file) shift; API_CREDS_FILE="${1:-}"; shift || true ;;
```

- [ ] **Step 4: Дополнить usage()**

В heredoc `usage()` после блока «📋 Обновление каталога:» (перед «🔧 Дополнительные опции:») добавить:

```
🔌 Интеграция с контроллером (коды adopted-устройств, multi-site):
  --codes-from-controller     Получить коды adopted-устройств через API и кэшировать
                              прошивки для них (включает --from-catalog; коды
                              объединяются с --codes; --filter применяется)
  --list-controller-codes     Только показать найденные коды и выйти (без root).
                              stdout — итоговый список, разбивка по сайтам — stderr
  --api-url URL               Адрес контроллера (default: https://localhost:8443)
  --api-user USER             Логин локального администратора (2FA не поддерживается —
                              создайте локального админа без 2FA)
  --api-pass PASS             Пароль (видно в ps; лучше env или файл кредов)
  --api-creds-file PATH       Файл KEY=VALUE с UNIFI_API_URL/USER/PASS (chmod 600)
  --codes-from-db             Альтернатива без учётки: локальный MongoDB контроллера
                              (localhost:27117, нужен mongosh/mongo); API-креды
                              при этом игнорируются
```

В раздел «📝 Переменные окружения:» добавить строки:

```
  UNIFI_API_URL               Адрес контроллера для --codes-from-controller
  UNIFI_API_USER              Логин администратора API
  UNIFI_API_PASS              Пароль администратора API
```

- [ ] **Step 5: Проверка синтаксиса и smoke**

```bash
bash -n unifi-fw-cache.sh
./unifi-fw-cache.sh --help | grep -- --codes-from-controller
command -v shellcheck >/dev/null && shellcheck unifi-fw-cache.sh || true
```

Expected: `bash -n` молчит; grep находит строку опции.

- [ ] **Step 6: Commit**

```bash
git add unifi-fw-cache.sh
git commit -m "feat(controller-api): CLI-флаги, переменные и usage для кодов с контроллера"
```

---

### Task 2: load_api_creds()

**Files:**
- Modify: `unifi-fw-cache.sh` — вставить функцию после `get_filtered_codes()` (перед `process_from_catalog()`), открыв новый блок `# --- Controller API ---`

**Interfaces:**
- Consumes: `API_CREDS_FILE`, `UNIFI_API_URL/USER/PASS` (Task 1); существующая `normalize_host()` (строка 272 — добавляет `https://` при отсутствии схемы, срезает trailing `/`).
- Produces: `load_api_creds()` — возвращает 0/1; после вызова `UNIFI_API_URL` всегда непустой, со схемой и без trailing slash; файл кредов заполняет только пустые переменные (приоритет флаги > env > файл).

- [ ] **Step 1: Вставить блок и функцию**

```bash
# --- Controller API (получение кодов adopted-устройств) ---

# Свести учётные данные API: флаги > env > файл кредов
load_api_creds() {
  if [[ -n "$API_CREDS_FILE" ]]; then
    [[ -r "$API_CREDS_FILE" ]] || { echo "❌ Файл кредов недоступен: $API_CREDS_FILE" >&2; return 1; }
    local perms; perms=$(stat -c '%a' "$API_CREDS_FILE" 2>/dev/null || echo "")
    if [[ -n "$perms" && "$perms" != "600" && "$perms" != "400" ]]; then
      echo "⚠️ Файл кредов $API_CREDS_FILE имеет права $perms (рекомендуется 600)" >&2
    fi
    local key val
    # `|| [[ -n "$key" ]]` — не потерять последнюю строку файла без завершающего \n
    while IFS='=' read -r key val || [[ -n "$key" ]]; do
      key="${key//[[:space:]]/}"
      [[ -z "$key" || "$key" == \#* ]] && continue
      val="${val%$'\r'}"  # CRLF из файлов, созданных на Windows
      # Снять только ПАРНЫЕ обрамляющие кавычки
      if [[ ${#val} -ge 2 && "$val" == \"*\" ]]; then val="${val:1:${#val}-2}"
      elif [[ ${#val} -ge 2 && "$val" == \'*\' ]]; then val="${val:1:${#val}-2}"; fi
      case "$key" in
        UNIFI_API_URL)  [[ -z "$UNIFI_API_URL"  ]] && UNIFI_API_URL="$val" ;;
        UNIFI_API_USER) [[ -z "$UNIFI_API_USER" ]] && UNIFI_API_USER="$val" ;;
        UNIFI_API_PASS) [[ -z "$UNIFI_API_PASS" ]] && UNIFI_API_PASS="$val" ;;
      esac
    done < "$API_CREDS_FILE"
  fi
  UNIFI_API_URL="${UNIFI_API_URL:-https://localhost:8443}"
  UNIFI_API_URL="$(normalize_host "$UNIFI_API_URL")"
  return 0
}
```

- [ ] **Step 2: Проверка**

```bash
bash -n unifi-fw-cache.sh
```

Expected: без вывода.

- [ ] **Step 3: Commit**

```bash
git add unifi-fw-cache.sh
git commit -m "feat(controller-api): load_api_creds — креды из флагов/env/файла (CRLF-safe)"
```

---

### Task 3: controller_login(), controller_api_get(), controller_logout()

**Files:**
- Modify: `unifi-fw-cache.sh` — добавить после `load_api_creds()`

**Interfaces:**
- Consumes: `load_api_creds()` уже вызван; `UNIFI_API_URL/USER/PASS` заполнены.
- Produces: `controller_login()` — 0/1, заполняет `API_COOKIE_JAR`, `API_CURL_ARGS`, `API_BASE` (с `/proxy/network` для UniFi OS), `API_CSRF_TOKEN`; различает неверный пароль (HTTP 400) и 2FA (HTTP 499 / `Ubic2faTokenRequired`). `controller_api_get <path>` — тело ответа GET `$API_BASE$path` в stdout. `controller_logout()` — best-effort закрытие сессии, всегда 0.

- [ ] **Step 1: Вставить функции**

```bash
# Вход в API: сначала self-hosted (/api/login), затем UniFi OS (/api/auth/login)
controller_login() {
  command -v curl >/dev/null 2>&1 || { echo "❌ Для работы с API контроллера требуется curl" >&2; return 1; }
  if [[ -z "$UNIFI_API_USER" || -z "$UNIFI_API_PASS" ]]; then
    echo "❌ Не заданы учётные данные API (--api-user/--api-pass, env UNIFI_API_USER/UNIFI_API_PASS или --api-creds-file)" >&2
    return 1
  fi

  API_COOKIE_JAR="$(mktemp)"
  # Хост без схемы/порта/пути — для --noproxy (прокси не должен перехватывать API)
  local noproxy_host="${UNIFI_API_URL#*://}"
  if [[ "$noproxy_host" == \[* ]]; then
    noproxy_host="${noproxy_host%%\]*}]"  # IPv6 в квадратных скобках
  else
    noproxy_host="${noproxy_host%%[:/]*}"
  fi
  API_CURL_ARGS=(-k -s --noproxy "$noproxy_host" --connect-timeout 10 --max-time 60 -c "$API_COOKIE_JAR" -b "$API_COOKIE_JAR")

  # Пароль передаётся jq через окружение — не попадает в argv (не виден в ps)
  local payload
  payload=$(UNIFI_API_USER="$UNIFI_API_USER" UNIFI_API_PASS="$UNIFI_API_PASS" \
    jq -n '{username: env.UNIFI_API_USER, password: env.UNIFI_API_PASS}')

  local body headers
  body="$(mktemp)"; headers="$(mktemp)"
  # Темпфайлы удаляются при любом выходе из функции
  trap 'rm -f "$body" "$headers" 2>/dev/null' RETURN

  # 1) self-hosted: успех = HTTP 200 И meta.rc == "ok" (не доверять голому 200)
  local code_self code_uos
  code_self=$(printf '%s' "$payload" | curl "${API_CURL_ARGS[@]}" -o "$body" -w '%{http_code}' \
    -H 'Content-Type: application/json' -d @- "$UNIFI_API_URL/api/login" || true)
  code_self="${code_self:-000}"
  if [[ "$code_self" == "200" ]] && jq -e '.meta.rc == "ok"' "$body" >/dev/null 2>&1; then
    API_BASE="$UNIFI_API_URL"
    echo "🔐 Вход выполнен (self-hosted API): $UNIFI_API_URL" >&2
    return 0
  fi
  if [[ "$code_self" == "400" ]]; then
    if grep -q 'Ubic2faTokenRequired' "$body" 2>/dev/null; then
      echo "❌ У аккаунта включена 2FA — создайте локального администратора без 2FA" >&2
    else
      echo "❌ Контроллер отверг учётные данные (HTTP 400): проверьте логин/пароль" >&2
    fi
    return 1
  fi

  # 2) UniFi OS: /api/auth/login + CSRF-токен из заголовка ответа
  code_uos=$(printf '%s' "$payload" | curl "${API_CURL_ARGS[@]}" -D "$headers" -o "$body" -w '%{http_code}' \
    -H 'Content-Type: application/json' -d @- "$UNIFI_API_URL/api/auth/login" || true)
  code_uos="${code_uos:-000}"
  API_CSRF_TOKEN=$(awk -F': ' 'tolower($1)=="x-csrf-token"{gsub(/\r/,"",$2); print $2}' "$headers" | tail -n1)
  if [[ "$code_uos" == "200" ]]; then
    API_BASE="$UNIFI_API_URL/proxy/network"
    echo "🔐 Вход выполнен (UniFi OS API): $UNIFI_API_URL" >&2
    return 0
  fi
  if [[ "$code_uos" == "499" ]]; then
    echo "❌ У аккаунта включена 2FA (HTTP 499) — создайте локального администратора без 2FA" >&2
    return 1
  fi

  echo "❌ Не удалось войти в API ($UNIFI_API_URL): self-hosted HTTP $code_self, UniFi OS HTTP $code_uos" >&2
  return 1
}

# GET-запрос к API с cookie (+CSRF для UniFi OS); тело ответа в stdout
controller_api_get() {
  local path="$1"
  local -a hdr=()
  [[ -n "$API_CSRF_TOKEN" ]] && hdr=(-H "X-Csrf-Token: $API_CSRF_TOKEN")
  curl "${API_CURL_ARGS[@]}" ${hdr[@]+"${hdr[@]}"} "$API_BASE$path"
}

# Best-effort закрытие сессии (сессии не копятся при cron-запусках)
controller_logout() {
  [[ -z "$API_BASE" ]] && return 0
  local -a hdr=()
  [[ -n "$API_CSRF_TOKEN" ]] && hdr=(-H "X-Csrf-Token: $API_CSRF_TOKEN")
  if [[ "$API_BASE" == *"/proxy/network" ]]; then
    curl "${API_CURL_ARGS[@]}" ${hdr[@]+"${hdr[@]}"} -X POST -o /dev/null "$UNIFI_API_URL/api/auth/logout" 2>/dev/null || true
  else
    curl "${API_CURL_ARGS[@]}" ${hdr[@]+"${hdr[@]}"} -X POST -o /dev/null "$UNIFI_API_URL/api/logout" 2>/dev/null || true
  fi
  return 0
}
```

- [ ] **Step 2: Проверка**

```bash
bash -n unifi-fw-cache.sh
command -v shellcheck >/dev/null && shellcheck unifi-fw-cache.sh || true
```

Expected: `bash -n` молчит; в shellcheck нет новых ошибок уровня error.

- [ ] **Step 3: Commit**

```bash
git add unifi-fw-cache.sh
git commit -m "feat(controller-api): login/get/logout с различением 400 и 2FA"
```

---

### Task 4: controller_fetch_codes() и controller_fetch_codes_mongo()

**Files:**
- Modify: `unifi-fw-cache.sh` — добавить после `controller_logout()`

**Interfaces:**
- Consumes: `controller_api_get(path)` (Task 3).
- Produces: `controller_fetch_codes()` — stdout: коды через пробел, дедуплицированные (напр. `U7PG2 UAP6MP`), может быть пустым при 0 adopted-устройств (это НЕ ошибка функции); прогресс по сайтам — stderr; return 1 если сайты недоступны или ни один не опрошен. `controller_fetch_codes_mongo()` — тот же контракт stdout; return 1 при недоступном mongo/невалидном выводе.

- [ ] **Step 1: Вставить функции**

```bash
# Обойти все сайты и собрать коды моделей ТОЛЬКО adopted-устройств
controller_fetch_codes() {
  local sites_json sites msg
  sites_json=$(controller_api_get "/api/self/sites") || true
  # Ошибки classic API приходят с "data": [] — проверяем meta.rc, а не наличие .data
  if ! echo "$sites_json" | jq -e '.meta.rc == "ok"' >/dev/null 2>&1; then
    msg=$(echo "$sites_json" | jq -r '.meta.msg // empty' 2>/dev/null || true)
    echo "❌ Не удалось получить список сайтов контроллера${msg:+ ($msg)}" >&2
    return 1
  fi
  sites=$(echo "$sites_json" | jq -r '.data[].name' 2>/dev/null || true)
  [[ -z "$sites" ]] && { echo "❌ Список сайтов пуст" >&2; return 1; }

  local all_codes="" site devices_json site_codes desc ok_sites=0
  while IFS= read -r site; do
    devices_json=$(controller_api_get "/api/s/$site/stat/device") || true
    if ! echo "$devices_json" | jq -e '.meta.rc == "ok"' >/dev/null 2>&1; then
      msg=$(echo "$devices_json" | jq -r '.meta.msg // empty' 2>/dev/null || true)
      echo "⚠️ Сайт '$site': не удалось получить устройства${msg:+ ($msg)}, пропускаю" >&2
      continue
    fi
    ok_sites=$((ok_sites + 1))
    # Только реально adopted-устройства (не pending adoption)
    site_codes=$(echo "$devices_json" | jq -r '.data[] | select(.adopted==true) | .model' 2>/dev/null | sort -u | tr '\n' ' ') || true
    desc=$(echo "$sites_json" | jq -r --arg n "$site" '.data[] | select(.name==$n) | .desc' 2>/dev/null || true)
    echo "🏢 Сайт '${desc:-$site}': ${site_codes:-нет adopted-устройств}" >&2
    all_codes+="${site_codes}"$'\n'
  done <<< "$sites"

  if [[ $ok_sites -eq 0 ]]; then echo "❌ Не удалось опросить ни один сайт" >&2; return 1; fi
  # sed вместо grep -v: grep фейлится под pipefail при пустом результате,
  # а пустой список кодов — легитимный исход (обрабатывается в main)
  echo "$all_codes" | tr ' ' '\n' | sed '/^$/d' | sort -u | tr '\n' ' ' | sed 's/ *$//'
  return 0
}

# Альтернатива без учётки: локальный MongoDB контроллера (только на самой машине)
controller_fetch_codes_mongo() {
  local mongo_cmd=""
  command -v mongosh >/dev/null 2>&1 && mongo_cmd="mongosh"
  [[ -z "$mongo_cmd" ]] && command -v mongo >/dev/null 2>&1 && mongo_cmd="mongo"
  [[ -z "$mongo_cmd" ]] && { echo "❌ Для --codes-from-db требуется mongosh или mongo" >&2; return 1; }
  local codes=""
  if ! codes=$("$mongo_cmd" --quiet --port 27117 ace \
      --eval 'db.device.distinct("model", {adopted: true}).join(" ")' 2>/dev/null | tail -n1); then
    codes=""
  fi
  # Валидация: legacy mongo печатает ошибки коннекта в STDOUT — они не должны стать «кодами»
  if [[ -z "$codes" || ! "$codes" =~ ^[A-Za-z0-9._+-]+([[:space:]][A-Za-z0-9._+-]+)*$ ]]; then
    echo "❌ Не удалось получить коды из MongoDB (localhost:27117, db ace) — контроллер запущен?" >&2
    return 1
  fi
  echo "$codes"
}
```

- [ ] **Step 2: Проверка**

```bash
bash -n unifi-fw-cache.sh
```

Expected: без вывода.

- [ ] **Step 3: Commit**

```bash
git add unifi-fw-cache.sh
git commit -m "feat(controller-api): выборка кодов adopted-устройств (API multi-site + MongoDB)"
```

---

### Task 5: Интеграция в main(), предупреждение о кодах вне каталога, README

**Files:**
- Modify: `unifi-fw-cache.sh` — `main()` (начало функции) и `process_from_catalog()` (после подсчёта устройств)
- Modify: `README.md` — раздел про режим контроллера

**Interfaces:**
- Consumes: `load_api_creds`, `controller_login`, `controller_api_get`, `controller_logout`, `controller_fetch_codes`, `controller_fetch_codes_mongo` (Tasks 2–4); флаги Task 1; `is_root()` (строка 168).
- Produces: рабочие режимы `--list-controller-codes` и `--codes-from-controller`.

- [ ] **Step 1: Вставить блок в начало main()**

Сразу после строки `main() {` добавить:

```bash
  # Получение кодов adopted-устройств с контроллера
  if [[ $CODES_FROM_CONTROLLER -eq 1 || $LIST_CONTROLLER_CODES -eq 1 ]]; then
    # Несовместимые комбинации — до обращения к API
    if [[ $UPDATE_CATALOG -eq 1 || $MIRROR_ALL -eq 1 ]]; then
      echo "❌ --codes-from-controller/--list-controller-codes несовместимы с --update-catalog и --mirror-all" >&2
      exit 2
    fi
    # Root нужен только для записи в кэш; list-режим — read-only, без root.
    # Проверка ДО логина: не тратить обход сайтов, чтобы упасть на правах
    if [[ $LIST_CONTROLLER_CODES -eq 0 ]] && ! is_root; then
      echo "Требуются права root для режима контроллера." >&2
      exit 1
    fi
    local controller_codes=""
    if [[ $CODES_FROM_DB -eq 1 ]]; then
      controller_codes=$(controller_fetch_codes_mongo) || exit 1
    else
      load_api_creds || exit 1
      controller_login || exit 1
      controller_codes=$(controller_fetch_codes) || { controller_logout; exit 1; }
      controller_logout
    fi
    [[ -z "$controller_codes" ]] && { echo "❌ На контроллере не найдено adopted-устройств" >&2; exit 1; }
    # --filter применяется и к кодам с контроллера
    if [[ -n "$FILTER_REGEX" ]]; then
      controller_codes=$(echo "$controller_codes" | tr ' ' '\n' | grep -E "$FILTER_REGEX" | tr '\n' ' ' | sed 's/ *$//') || true
      [[ -z "$controller_codes" ]] && { echo "❌ После фильтра '$FILTER_REGEX' кодов не осталось" >&2; exit 1; }
    fi
    if [[ $LIST_CONTROLLER_CODES -eq 1 ]]; then
      echo "📟 Коды adopted-устройств: $controller_codes"
      exit 0
    fi
    # Объединить с кодами из --codes (union, дедупликация)
    local merged
    # shellcheck disable=SC2086
    merged=$(printf '%s\n' ${CODES[@]+"${CODES[@]}"} $controller_codes | sed '/^$/d' | sort -u | tr '\n' ' ')
    read -r -a CODES <<< "$merged"
    FROM_CATALOG=1
    echo "📟 Коды для кэширования: ${CODES[*]}"
  fi
```

- [ ] **Step 2: Предупреждение о кодах, отсутствующих в каталоге**

В `process_from_catalog()` после строки `echo "Найдено устройств для кэша: ${#target_codes[@]}"` добавить:

```bash
  # Предупредить о кодах, которых нет в каталоге прошивок
  local catalog_keys missing=() c
  catalog_keys=$(jq -r --arg v "$APP_VERSION" '.[$v].release | keys[]' "$CATALOG" 2>/dev/null || true)
  for c in "${target_codes[@]}"; do
    grep -Fqx "$c" <<< "$catalog_keys" || missing+=("$c")
  done
  [[ ${#missing[@]} -gt 0 ]] && echo "⚠️ Нет в каталоге прошивок (пропускаются): ${missing[*]}" >&2
```

Внимание (set -e): строка с `[[ ... ]] && echo` не последняя в функции — за ней идёт существующий код; фатальности нет.

- [ ] **Step 3: README**

В `README.md`, в раздел «🎮 Режим контроллера» (список возможностей, после строки про автоопределение совместимых устройств) добавить пункт:

```markdown
- 🔌 **Коды устройств прямо с контроллера**: `--codes-from-controller` берёт модели только adopted-устройств по всем сайтам (multi-site) через API (self-hosted и UniFi OS)
```

В раздел «🔧 Примеры использования» добавить подраздел:

```markdown
### 🔌 Кэширование по данным контроллера (multi-site)

```bash
# Посмотреть, какие коды adopted-устройств видит контроллер (read-only, root не нужен)
./unifi-fw-cache.sh --list-controller-codes --api-creds-file /etc/unifi-fw-cache.creds

# Скачать прошивки для всех adopted-устройств (работает и через прокси: sudo -E)
sudo -E ./unifi-fw-cache.sh --auto-update-catalog --codes-from-controller \
  --api-creds-file /etc/unifi-fw-cache.creds

# Только точки доступа со всех сайтов
sudo -E ./unifi-fw-cache.sh --codes-from-controller --filter '^U' \
  --api-creds-file /etc/unifi-fw-cache.creds

# Файл кредов (chmod 600):
#   UNIFI_API_URL=https://localhost:8443
#   UNIFI_API_USER=admin
#   UNIFI_API_PASS=secret
# Важно: у администратора не должна быть включена 2FA (создайте локального админа)

# Вариант без учётки — напрямую из локального MongoDB контроллера
sudo ./unifi-fw-cache.sh --codes-from-db
```
```

- [ ] **Step 4: Полная проверка**

```bash
bash -n unifi-fw-cache.sh
./unifi-fw-cache.sh --help | grep -c "codes-from"
command -v shellcheck >/dev/null && shellcheck unifi-fw-cache.sh || true
```

Expected: `bash -n` молчит; grep-счётчик ≥ 2; shellcheck без новых error.

- [ ] **Step 5: Commit**

```bash
git add unifi-fw-cache.sh README.md
git commit -m "feat(controller-api): режимы --codes-from-controller/--list-controller-codes + docs"
```

---

## Runtime-чеклист для пользователя (на виртуалке с контроллером)

1. `./unifi-fw-cache.sh --list-controller-codes --api-user <u> --api-pass <p>` — коды только adopted-устройств по всем сайтам (read-only, без root).
2. То же с заведомо неверным паролем — сообщение про HTTP 400 «проверьте логин/пароль» (не HTTP 404).
3. То же с файлом кредов `--api-creds-file` (проверить предупреждение при правах ≠ 600; файл, созданный на Windows с CRLF, тоже должен работать).
4. `sudo -E ./unifi-fw-cache.sh --codes-from-controller --api-creds-file ... --no-restart` — файлы появляются в `/var/lib/unifi/firmware/<код>/<версия>/`, `jq . /var/lib/unifi/firmware/firmware_meta.json` валиден.
5. `./unifi-fw-cache.sh --codes-from-controller ...` БЕЗ root — быстрая ошибка про root ДО логина в API.
6. При наличии UniFi OS консоли — п.1 против неё (`--api-url https://<udm>`).
7. `sudo ./unifi-fw-cache.sh --codes-from-db` — совпадение списка с п.1; при остановленном контроллере (`systemctl stop unifi`) — внятная ошибка, а не мусор в кодах.
8. Регресс: `sudo ./unifi-fw-cache.sh --from-catalog --codes "U7PG2"` работает как раньше (без curl).
